import Foundation
import Network
import Combine
import Observation

enum H264StreamingError: LocalizedError {
    case serverNotRunning
    case failedToStartServer(Error)
    case sendFailed(Error)
    case invalidNALUnit
    case encoderNotConfigured
    
    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "H264 streaming server is not running"
        case .failedToStartServer(let error):
            return "Failed to start H264 server: \(error.localizedDescription)"
        case .sendFailed(let error):
            return "Failed to send NAL data: \(error.localizedDescription)"
        case .invalidNALUnit:
            return "Invalid NAL unit data"
        case .encoderNotConfigured:
            return "Video encoder not configured"
        }
    }
}

@Observable
final class H264StreamingService {
    enum CodecType {
        case h264
        case hevc
    }
    
    private(set) var isRunning = false
    private(set) var connectedClientCount = 0
    private(set) var port: UInt16
    private(set) var lastError: H264StreamingError?
    private(set) var codec: CodecType = .h264
    
    private var listener: NWListener?
    private var clients: [H264Client] = []
    private let clientsLock = NSLock()
    private let sessionQueue = DispatchQueue(label: "com.rifatcam.h264stream", qos: .userInitiated)
    
    struct H264Client {
        let connection: NWConnection
        let id: UUID
        var hasReceivedSPS: Bool
        var hasReceivedPPS: Bool
        var hasReceivedVPS: Bool
    }
    
    init(port: UInt16 = 8081, codec: CodecType = .h264) {
        self.port = port
        self.codec = codec
    }
    
    deinit {
        stop()
    }
    
    func start() throws {
        guard !isRunning else { return }
        
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.internetProtocol = .init(.ipv4)
        
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    Task { @MainActor in
                        self.isRunning = true
                        self.lastError = nil
                    }
                case .failed(let error):
                    Task { @MainActor in
                        self.isRunning = false
                        self.lastError = .failedToStartServer(error)
                    }
                    self?.stop()
                case .cancelled:
                    Task { @MainActor in
                        self.isRunning = false
                    }
                default:
                    break
                }
            }
            
            self.listener = listener
            listener.start(queue: sessionQueue)
        } catch {
            throw H264StreamingError.failedToStartServer(error)
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        
        clientsLock.lock()
        for client in clients {
            client.connection.cancel()
        }
        clients.removeAll()
        clientsLock.unlock()
        
        Task { @MainActor in
            self.isRunning = false
            self.connectedClientCount = 0
        }
    }
    
    func setCodec(_ newCodec: CodecType) {
        self.codec = newCodec
    }
    
    func pushSPS(_ data: Data) {
        guard isRunning else { return }
        pushNAL(data, type: .sps)
    }
    
    func pushPPS(_ data: Data) {
        guard isRunning else { return }
        pushNAL(data, type: .pps)
    }
    
    func pushVPS(_ data: Data) {
        guard isRunning else { return }
        guard codec == .hevc else { return }
        pushNAL(data, type: .vps)
    }
    
    func pushFrame(_ data: Data, isKeyframe: Bool) {
        guard isRunning else { return }
        pushNAL(data, type: isKeyframe ? .keyframe : .nonKeyframe)
    }
    
    private enum NALUnitType {
        case sps, pps, vps, keyframe, nonKeyframe
    }
    
    private func pushNAL(_ data: Data, type: NALUnitType) {
        guard !data.isEmpty else { return }
        
        clientsLock.lock()
        let snapshot = clients
        clientsLock.unlock()
        
        guard !snapshot.isEmpty else { return }
        
        for client in snapshot {
            guard client.isAuthenticated() else { continue }
            sendNALUnit(data, type: type, to: client)
        }
    }
    
    private func sendNALUnit(_ data: Data, type: NALUnitType, to client: H264Client) {
        var framePayload = Data()
        
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        framePayload.append(startCode)
        framePayload.append(data)
        
        var length = UInt32(framePayload.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(framePayload)
        
        client.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.lastError = .sendFailed(error)
                }
                self?.removeClient(id: client.id)
            }
        })
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let client = H264Client(
            connection: connection,
            id: UUID(),
            hasReceivedSPS: false,
            hasReceivedPPS: false,
            hasReceivedVPS: false
        )
        
        clientsLock.lock()
        clients.append(client)
        let count = clients.count
        clientsLock.unlock()
        
        Task { @MainActor in
            self.connectedClientCount = count
        }
        
        connection.start(queue: sessionQueue)
        listenForClientRequests(from: connection, clientId: client.id)
    }
    
    private func listenForClientRequests(from connection: NWConnection, clientId: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if isComplete || error != nil {
                self.removeClient(id: clientId)
                return
            }
            
            if let data = data, !data.isEmpty {
                if data.count >= 4 {
                    let requestCode = data[0]
                    if requestCode == 0x01 {
                        self.clientsLock.lock()
                        if let idx = self.clients.firstIndex(where: { $0.id == clientId }) {
                            self.clients[idx].hasReceivedSPS = false
                            self.clients[idx].hasReceivedPPS = false
                            self.clients[idx].hasReceivedVPS = false
                        }
                        self.clientsLock.unlock()
                    }
                }
            }
            
            self.listenForClientRequests(from: connection, clientId: clientId)
        }
    }
    
    private func removeClient(id: UUID) {
        clientsLock.lock()
        if let idx = clients.firstIndex(where: { $0.id == id }) {
            clients[idx].connection.cancel()
            clients.remove(at: idx)
        }
        let count = clients.count
        clientsLock.unlock()
        
        Task { @MainActor in
            self.connectedClientCount = count
        }
    }
}

extension H264StreamingService.H264Client {
    func isAuthenticated() -> Bool {
        return true
    }
}
