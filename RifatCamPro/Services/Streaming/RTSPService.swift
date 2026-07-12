import Foundation
import Network
import Combine
import Observation

enum RTSPError: LocalizedError {
    case serverNotRunning
    case failedToStartServer(Error)
    case invalidRequest
    case sessionNotFound(String)
    case transportSetupFailed
    case rtpPacketizationFailed
    case unsupportedMethod(String)
    case sendFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "RTSP server is not running"
        case .failedToStartServer(let error):
            return "Failed to start RTSP server: \(error.localizedDescription)"
        case .invalidRequest:
            return "Invalid RTSP request"
        case .sessionNotFound(let id):
            return "Session not found: \(id)"
        case .transportSetupFailed:
            return "Transport setup failed"
        case .rtpPacketizationFailed:
            return "RTP packetization failed"
        case .unsupportedMethod(let method):
            return "Unsupported RTSP method: \(method)"
        case .sendFailed(let error):
            return "Send failed: \(error.localizedDescription)"
        }
    }
}

@Observable
final class RTSPService {
    private(set) var isRunning = false
    private(set) var connectedClientCount = 0
    private(set) var port: UInt16
    private(set) var lastError: RTSPError?
    private(set) var streamURL: String = ""
    
    private var listener: NWListener?
    private var sessions: [String: RTSPSession] = [:]
    private var rtpSessions: [String: RTPSession] = [:]
    private var rtpListeners: [String: NWListener] = [:]
    private var rtcpListeners: [String: NWListener] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.rifatcam.rtsp", qos: .userInitiated)
    
    struct RTSPSession {
        let id: String
        let connection: NWConnection
        var clientRTPPort: UInt16
        var clientRTCPPort: UInt16
        var serverRTPPort: UInt16
        var serverRTCPPort: UInt16
        var isPlaying: Bool
        var cseq: UInt32
        var sessionToken: String
        var isTCPIP: Bool
    }
    
    struct RTPSession {
        let sessionId: String
        var rtpConnection: NWConnection?
        var rtcpConnection: NWConnection?
        var sequenceNumber: UInt16
        var timestamp: UInt32
        var ssrc: UInt32
        var clockRate: UInt32
    }
    
    init(port: UInt16 = 554) {
        self.port = port
    }
    
    deinit { stop() }
    
    func start() throws {
        guard !isRunning else { return }
        
        let params = NWParameters.tcp
        
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleNewConnection(conn)
            }
            
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    Task { @MainActor in
                        self.isRunning = true
                        self.streamURL = "rtsp://\(self.localIPAddress()):\(self.port)/live"
                    }
                case .failed(let error):
                    Task { @MainActor in
                        self.isRunning = false
                        self.lastError = .failedToStartServer(error)
                    }
                    self.stop()
                case .cancelled:
                    Task { @MainActor in
                        self.isRunning = false
                    }
                default:
                    break
                }
            }
            
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            throw RTSPError.failedToStartServer(error)
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        
        lock.lock()
        for (_, s) in sessions { s.connection.cancel() }
        for (_, r) in rtpSessions {
            r.rtpConnection?.cancel()
            r.rtcpConnection?.cancel()
        }
        for (_, l) in rtpListeners { l.cancel() }
        for (_, l) in rtcpListeners { l.cancel() }
        sessions.removeAll()
        rtpSessions.removeAll()
        rtpListeners.removeAll()
        rtcpListeners.removeAll()
        lock.unlock()
        
        Task { @MainActor in
            self.isRunning = false
            self.connectedClientCount = 0
        }
    }
    
    func pushH264Frame(_ data: Data, timestamp: UInt32, isKeyframe: Bool) {
        guard isRunning else { return }
        deliverFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
    }
    
    func pushHEVCFrame(_ data: Data, timestamp: UInt32, isKeyframe: Bool) {
        guard isRunning else { return }
        deliverFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
    }
    
    func pushSPS(_ data: Data) {
        guard isRunning else { return }
        var nal = Data([0x67])
        nal.append(data)
        deliverParameterSet(nal)
    }
    
    func pushPPS(_ data: Data) {
        guard isRunning else { return }
        var nal = Data([0x68])
        nal.append(data)
        deliverParameterSet(nal)
    }
    
    func pushVPS(_ data: Data) {
        guard isRunning else { return }
        var nal = Data([0x40])
        nal.append(data)
        deliverParameterSet(nal)
    }
    
    private func deliverParameterSet(_ data: Data) {
        lock.lock()
        let snapshot = rtpSessions
        lock.unlock()
        for (_, s) in snapshot {
            packetizeAndSend(data, session: s, isKeyframe: true)
        }
    }
    
    private func deliverFrame(_ data: Data, timestamp: UInt32, isKeyframe: Bool) {
        lock.lock()
        let snapshot = rtpSessions
        lock.unlock()
        for (_, s) in snapshot {
            packetizeAndSend(data, session: s, isKeyframe: isKeyframe, timestamp: timestamp)
        }
    }
    
    // MARK: - RTP Packetization (RFC 6184 single NAL / FU-A fragmentation)
    
    private func packetizeAndSend(_ nalData: Data, session: RTPSession, isKeyframe: Bool, timestamp: UInt32? = nil) {
        let maxPacketSize = 1400
        let nalByte = nalData[0]
        let nalType = nalByte & 0x1F
        
        if nalData.count <= maxPacketSize {
            sendSingleNALPacket(nalData, session: session, isKeyframe: isKeyframe, timestamp: timestamp)
        } else {
            sendFUAPackets(nalData, session: session, isKeyframe: isKeyframe, timestamp: timestamp)
        }
    }
    
    private func sendSingleNALPacket(_ nalData: Data, session: RTPSession, isKeyframe: Bool, timestamp: UInt32? = nil) {
        var packet = buildRTPHeader(session: session, marker: true, timestamp: timestamp)
        packet.append(nalData)
        sendToRTPConnection(packet, session: session)
        
        advanceSession(session: session, isKeyframe: isKeyframe)
    }
    
    private func sendFUAPackets(_ nalData: Data, session: RTPSession, isKeyframe: Bool, timestamp: UInt32? = nil) {
        let nalByte = nalData[0]
        let nalType = nalByte & 0x1F
        let nri = nalByte & 0x60
        
        let payload = nalData.dropFirst()
        let maxFragment = 1400 - 2
        var offset = 0
        var isFirst = true
        
        while offset < payload.count {
            let end = min(offset + maxFragment, payload.count)
            let fragment = payload.subdata(in: offset..<end)
            let isLast = end >= payload.count
            
            let fuIndicator = nri | 28
            var fuHeader: UInt8 = nalType
            if isFirst { fuHeader |= 0x80 }
            if isLast { fuHeader |= 0x40 }
            
            var packet = buildRTPHeader(session: session, marker: isLast, timestamp: timestamp)
            packet.append(fuIndicator)
            packet.append(fuHeader)
            packet.append(fragment)
            sendToRTPConnection(packet, session: session)
            
            isFirst = false
            offset = end
        }
        
        advanceSession(session: session, isKeyframe: isKeyframe)
    }
    
    private func buildRTPHeader(session: RTPSession, marker: Bool, timestamp: UInt32? = nil) -> Data {
        var header = Data()
        
        let v: UInt8 = 2
        let p: UInt8 = 0
        let x: UInt8 = 0
        let cc: UInt8 = 0
        let pt: UInt8 = 96
        
        let byte0 = (v << 6) | (p << 5) | (x << 4) | cc
        header.append(byte0)
        
        let mBit: UInt8 = marker ? 0x80 : 0
        header.append(mBit | pt)
        
        var seq = session.sequenceNumber.bigEndian
        header.append(Data(bytes: &seq, count: 2))
        
        var ts = (timestamp ?? session.timestamp).bigEndian
        header.append(Data(bytes: &ts, count: 4))
        
        var ssrc = session.ssrc.bigEndian
        header.append(Data(bytes: &ssrc, count: 4))
        
        return header
    }
    
    private func advanceSession(session: RTPSession, isKeyframe: Bool) {
        lock.lock()
        if var s = rtpSessions[session.sessionId] {
            s.sequenceNumber = s.sequenceNumber &+ 1
            s.timestamp = s.timestamp &+ (s.clockRate / 30)
            rtpSessions[session.sessionId] = s
        }
        lock.unlock()
    }
    
    private func sendToRTPConnection(_ data: Data, session: RTPSession) {
        if let conn = session.rtpConnection {
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { @MainActor in
                        self?.lastError = .sendFailed(error)
                    }
                }
            })
        }
    }
    
    // MARK: - RTSP Connection Handling
    
    private func handleNewConnection(_ connection: NWConnection) {
        let sid = UUID().uuidString
        let token = UUID().uuidString.prefix(8).description
        
        let session = RTSPSession(
            id: sid,
            connection: connection,
            clientRTPPort: 0,
            clientRTCPPort: 0,
            serverRTPPort: UInt16.random(in: 30000...40000),
            serverRTCPPort: UInt16.random(in: 30000...40000),
            isPlaying: false,
            cseq: 0,
            sessionToken: token,
            isTCPIP: false
        )
        
        lock.lock()
        sessions[sid] = session
        let count = sessions.count
        lock.unlock()
        
        Task { @MainActor in
            self.connectedClientCount = count
        }
        
        connection.start(queue: queue)
        readRTSPRequest(from: connection, sessionId: sid)
    }
    
    private func readRTSPRequest(from connection: NWConnection, sessionId: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if isComplete || error != nil {
                self.teardown(id: sessionId)
                return
            }
            
            guard let data, let raw = String(data: data, encoding: .utf8) else {
                self.teardown(id: sessionId)
                return
            }
            
            let blocks = raw.components(separatedBy: "\r\n\r\n")
            for block in blocks {
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                
                self.lock.lock()
                if var s = self.sessions[sessionId] {
                    if let m = trimmed.range(of: #"(?<=CSeq:\s)\d+"#, options: .regularExpression) {
                        s.cseq = UInt32(trimmed[m]) ?? 0
                    }
                    self.sessions[sessionId] = s
                }
                let sess = self.sessions[sessionId]
                self.lock.unlock()
                
                guard let sess else { return }
                
                let lines = trimmed.components(separatedBy: "\r\n")
                guard let first = lines.first else { continue }
                let tokens = first.split(separator: " ")
                guard tokens.count >= 2 else { continue }
                
                let method = String(tokens[0])
                let uri = String(tokens[1])
                
                switch method {
                case "OPTIONS":
                    self.respondOptions(conn: connection, cseq: sess.cseq)
                case "DESCRIBE":
                    self.respondDescribe(conn: connection, cseq: sess.cseq, uri: uri)
                case "SETUP":
                    self.respondSetup(conn: connection, cseq: sess.cseq, headers: lines, sessionId: sessionId)
                case "PLAY":
                    self.respondPlay(conn: connection, cseq: sess.cseq, sessionId: sessionId)
                case "TEARDOWN":
                    self.respondTeardown(conn: connection, cseq: sess.cseq, sessionId: sessionId)
                default:
                    self.respondError(conn: connection, cseq: sess.cseq, code: 405, msg: "Method Not Allowed")
                }
            }
            
            self.readRTSPRequest(from: connection, sessionId: sessionId)
        }
    }
    
    // MARK: - RTSP Response Handlers
    
    private func respondOptions(conn: NWConnection, cseq: UInt32) {
        let resp = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nPublic: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n\r\n"
        sendResp(conn: conn, text: resp)
    }
    
    private func respondDescribe(conn: NWConnection, cseq: UInt32, uri: String) {
        let sdp = makeSDP()
        let resp = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nContent-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n\(sdp)"
        sendResp(conn: conn, text: resp)
    }
    
    private func respondSetup(conn: NWConnection, cseq: UInt32, headers: [String], sessionId: String) {
        var clientRTP: UInt16 = 0
        var clientRTCP: UInt16 = 0
        var useTCP = false
        
        for h in headers {
            let lower = h.lowercased()
            if lower.hasPrefix("transport:") {
                if let r = h.range(of: #"(?<=client_port=)\d+-\d+"#, options: .regularExpression) {
                    let ports = String(h[r]).split(separator: "-")
                    if ports.count >= 2 {
                        clientRTP = UInt16(ports[0]) ?? 0
                        clientRTCP = UInt16(ports[1]) ?? 0
                    }
                }
                if lower.contains("tcp") { useTCP = true }
            }
        }
        
        lock.lock()
        sessions[sessionId]?.clientRTPPort = clientRTP
        sessions[sessionId]?.clientRTCPPort = clientRTCP
        sessions[sessionId]?.isTCPIP = useTCP
        let srvRTP = sessions[sessionId]?.serverRTPPort ?? UInt16.random(in: 30000...40000)
        let srvRTCP = sessions[sessionId]?.serverRTCPPort ?? UInt16.random(in: 30000...40000)
        lock.unlock()
        
        var rtpConn: NWConnection?
        var rtcpConn: NWConnection?
        
        if useTCP {
            // TCP interleaved: reuse the RTSP connection
            rtpConn = conn
            rtcpConn = conn
        } else if clientRTP > 0 {
            let rtpEP = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: clientRTP)!)
            rtpConn = NWConnection(to: rtpEP, using: .udp)
            rtpConn?.start(queue: queue)
            
            let rtcpEP = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: clientRTCP)!)
            rtcpConn = NWConnection(to: rtcpEP, using: .udp)
            rtcpConn?.start(queue: queue)
        }
        
        let ssrc = UInt32.random(in: 1...UInt32.max)
        let rtpSession = RTPSession(
            sessionId: sessionId,
            rtpConnection: rtpConn,
            rtcpConnection: rtcpConn,
            sequenceNumber: 0,
            timestamp: 0,
            ssrc: ssrc,
            clockRate: 90000
        )
        
        lock.lock()
        rtpSessions[sessionId] = rtpSession
        lock.unlock()
        
        let transport: String
        if useTCP {
            transport = "RTP/AVP/TCP;unicast;interleaved=0-1"
        } else {
            transport = "RTP/AVP;unicast;client_port=\(clientRTP)-\(clientRTCP);server_port=\(srvRTP)-\(srvRTCP);ssrc=\(String(ssrc, radix: 16))"
        }
        
        let resp = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: \(sessionId);timeout=60\r\nTransport: \(transport)\r\n\r\n"
        sendResp(conn: conn, text: resp)
    }
    
    private func respondPlay(conn: NWConnection, cseq: UInt32, sessionId: String) {
        lock.lock()
        sessions[sessionId]?.isPlaying = true
        lock.unlock()
        
        let resp = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: \(sessionId)\r\nRange: npt=0.000-\r\n\r\n"
        sendResp(conn: conn, text: resp)
    }
    
    private func respondTeardown(conn: NWConnection, cseq: UInt32, sessionId: String) {
        let resp = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nSession: \(sessionId)\r\n\r\n"
        sendResp(conn: conn, text: resp)
        teardown(id: sessionId)
    }
    
    private func respondError(conn: NWConnection, cseq: UInt32, code: Int, msg: String) {
        let resp = "RTSP/1.0 \(code) \(msg)\r\nCSeq: \(cseq)\r\n\r\n"
        sendResp(conn: conn, text: resp)
    }
    
    private func sendResp(conn: NWConnection, text: String) {
        guard let data = text.data(using: .utf8) else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.lastError = .sendFailed(error)
                }
            }
        })
    }
    
    private func teardown(id: String) {
        lock.lock()
        sessions[id]?.connection.cancel()
        sessions.removeValue(forKey: id)
        if let r = rtpSessions.removeValue(forKey: id) {
            r.rtpConnection?.cancel()
            r.rtcpConnection?.cancel()
        }
        rtpListeners[id]?.cancel()
        rtpListeners.removeValue(forKey: id)
        rtcpListeners[id]?.cancel()
        rtcpListeners.removeValue(forKey: id)
        let count = sessions.count
        lock.unlock()
        
        Task { @MainActor in
            self.connectedClientCount = count
        }
    }
    
    // MARK: - SDP Generation
    
    private func makeSDP() -> String {
        let ssrc = UInt32.random(in: 1...UInt32.max)
        return """
        v=0\r
        o=- 0 0 IN IP4 127.0.0.1\r
        s=RifatCam Pro\r
        c=IN IP4 0.0.0.0\r
        t=0 0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H264/90000\r
        a=fmtp:96 profile-level-id=42001E;packetization-mode=1\r
        a=control:trackID=0\r
        a=ssrc:\(ssrc) cname:RifatCamPro\r
        a=sendonly\r
        """
    }
    
    // MARK: - Utilities
    
    private func localIPAddress() -> String {
        var addr = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addr }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                if name == "en0" || name == "pdp_ip0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    addr = String(cString: hostname)
                    break
                }
            }
        }
        return addr
    }
}
