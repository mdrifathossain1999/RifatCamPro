import Foundation
import Network
import Combine
import CryptoKit

// MARK: - WebSocket Opcodes

fileprivate enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

// MARK: - WebSocket Frame

fileprivate struct WebSocketFrame {
    var fin: Bool
    var opcode: WebSocketOpcode
    var masked: Bool
    var payloadLength: UInt64
    var maskKey: Data?
    var payload: Data
}

// MARK: - WebSocket Client

final class WebSocketClient: @unchecked Sendable {
    let id: UUID
    let connection: NWConnection
    let connectedAt: Date
    var isAlive: Bool = true
    var lastPongReceived: Date
    var subscribedChannels: Set<String>

    init(connection: NWConnection) {
        self.id = UUID()
        self.connection = connection
        self.connectedAt = Date()
        self.lastPongReceived = Date()
        self.subscribedChannels = ["stats", "status", "frame"]
    }

    var connectionDuration: TimeInterval {
        Date().timeIntervalSince(connectedAt)
    }
}

// MARK: - WebSocket Message

struct WebSocketMessage: Sendable {
    let type: String
    let payload: [String: Any]

    func toJSONData() -> Data? {
        var dict = payload
        dict["type"] = type
        dict["timestamp"] = ISO8601DateFormatter().string(from: Date())
        return try? JSONSerialization.data(withJSONObject: dict)
    }
}

// MARK: - WebSocket Server Configuration

struct WebSocketServerConfig: Sendable {
    var port: UInt16
    var pingInterval: TimeInterval
    var pongTimeout: TimeInterval
    var maxPayloadSize: Int

    static let `default` = WebSocketServerConfig(
        port: 4749,
        pingInterval: 30,
        pongTimeout: 10,
        maxPayloadSize: 1024 * 1024
    )
}

// MARK: - WebSocket Server

@Observable
final class WebSocketServer {

    var isRunning: Bool = false
    var port: UInt16 = 4749
    var connectedClients: Int = 0
    var lastError: String?
    var totalMessagesSent: Int = 0
    var totalMessagesReceived: Int = 0

    var streamingStatsProvider: @MainActor @Sendable () -> StreamingStats = { .empty }
    var frameProvider: @MainActor @Sendable () -> Data?

    private var listener: NWListener?
    private var clients: [UUID: WebSocketClient] = [:]
    private let clientsLock = NSLock()
    private let config: WebSocketServerConfig
    private var pingTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var receiveBuffers: [UUID: Data] = [:]
    private let bufferLock = NSLock()

    init(config: WebSocketServerConfig = .default) {
        self.config = config
        self.port = config.port
        self.frameProvider = { nil }
    }

    deinit {
        let listener = self.listener
        listener?.cancel()
        pingTimer?.cancel()
        statsTimer?.cancel()
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: config.port)!)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.lastError = nil
                case .failed(let error):
                    self.isRunning = false
                    self.lastError = error.debugDescription
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        startPingTimer()
        startStatsTimer()
    }

    func stop() {
        pingTimer?.cancel()
        pingTimer = nil
        statsTimer?.cancel()
        statsTimer = nil

        broadcastClose()
        clientsLock.withLock {
            for (_, client) in clients {
                client.connection.cancel()
            }
            clients.removeAll()
        }
        bufferLock.withLock { receiveBuffers.removeAll() }

        listener?.cancel()
        listener = nil
        isRunning = false
        Task { @MainActor in
            self.connectedClients = 0
        }
    }

    // MARK: - Client Management

    private func handleNewConnection(_ connection: NWConnection) {
        let client = WebSocketClient(connection: connection)

        clientsLock.withLock {
            clients[client.id] = client
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectedClients = self.clients.count
        }

        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let client else { return }
            switch state {
            case .ready:
                break
            case .failed, .cancelled:
                self?.removeClient(client)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        performWebSocketHandshake(client: client)
    }

    private func removeClient(_ client: WebSocketClient) {
        client.isAlive = false
        clientsLock.withLock {
            clients.removeValue(forKey: client.id)
        }
        bufferLock.withLock {
            receiveBuffers.removeValue(forKey: client.id)
        }
        client.connection.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectedClients = self.clients.count
        }
    }

    private func broadcastClose() {
        let closeFrame = encodeCloseFrame(code: 1001, reason: "Server shutting down")
        clientsLock.withLock {
            for (_, client) in clients {
                sendRawData(closeFrame, to: client)
            }
        }
    }

    // MARK: - WebSocket Handshake

    private func performWebSocketHandshake(client: WebSocketClient) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: config.maxPayloadSize) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }

            if let error = error {
                print("[WSServer] Handshake receive error: \(error)")
                self.removeClient(client)
                return
            }

            if isComplete && (data == nil || data?.isEmpty == true) {
                self.removeClient(client)
                return
            }

            guard let data = data, !data.isEmpty else {
                self.removeClient(client)
                return
            }

            guard let request = String(data: data, encoding: .utf8) else {
                self.removeClient(client)
                return
            }

            let lowered = request.lowercased()
            if !lowered.contains("upgrade: websocket") {
                self.sendHTTPReject(to: client)
                return
            }

            guard let key = self.extractWebSocketKey(from: request) else {
                self.sendHTTPReject(to: client)
                return
            }

            let acceptKey = self.computeAcceptKey(key)
            let response = """
            HTTP/1.1 101 Switching Protocols\r\n\
            Upgrade: websocket\r\n\
            Connection: Upgrade\r\n\
            Sec-WebSocket-Accept: \(acceptKey)\r\n\
            \r\n
            """

            client.connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
                if let error = error {
                    print("[WSServer] Handshake send error: \(error)")
                    self?.removeClient(client)
                    return
                }
                self?.receiveWebSocketFrame(from: client)
            })
        }
    }

    private func extractWebSocketKey(from request: String) -> String? {
        let lines = request.components(separatedBy: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("sec-websocket-key:") {
                let value = String(line.dropFirst("sec-websocket-key:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func computeAcceptKey(_ key: String) -> String {
        let magicGUID = "258EAFA5-E914-47DA-95CA-5AB9C1F93B11"
        let combined = key + magicGUID
        guard let data = combined.data(using: .utf8) else { return "" }
        let hash = Insecure.SHA1.hash(data: data)
        return Data(hash).base64EncodedString()
    }

    private func sendHTTPReject(to client: WebSocketClient) {
        let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
        client.connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.removeClient(client)
        })
    }

    // MARK: - Frame Encoding

    func encodeFrame(opcode: WebSocketOpcode, payload: Data, mask: Bool = false) -> Data {
        var frame = Data()

        let firstByte: UInt8 = 0x80 | opcode.rawValue
        frame.append(firstByte)

        let payloadLength = UInt64(payload.count)
        let maskBit: UInt8 = mask ? 0x80 : 0x00

        if payloadLength <= 125 {
            frame.append(maskBit | UInt8(payloadLength))
        } else if payloadLength <= 65535 {
            frame.append(maskBit | 126)
            var length16 = UInt16(payloadLength).bigEndian
            frame.append(Data(bytes: &length16, count: 2))
        } else {
            frame.append(maskBit | 127)
            var length64 = payloadLength.bigEndian
            frame.append(Data(bytes: &length64, count: 8))
        }

        if mask {
            var maskKey = Data(count: 4)
            _ = maskKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            frame.append(maskKey)

            for i in 0..<payload.count {
                let maskByte = maskKey[maskKey.startIndex + (i % 4)]
                let payloadByte = payload[payload.startIndex + i]
                frame.append(payloadByte ^ maskByte)
            }
        } else {
            frame.append(payload)
        }

        return frame
    }

    func encodeCloseFrame(code: UInt16?, reason: String = "") -> Data {
        var payload = Data()
        if let code {
            var bigCode = code.bigEndian
            payload.append(Data(bytes: &bigCode, count: 2))
        }
        if let reasonData = reason.data(using: .utf8) {
            payload.append(reasonData)
        }
        return encodeFrame(opcode: .close, payload: payload)
    }

    // MARK: - Frame Decoding

    private func decodeFrame(from data: Data) -> WebSocketFrame? {
        guard data.count >= 2 else { return nil }

        let bytes = [UInt8](data)
        let firstByte = bytes[0]
        let secondByte = bytes[1]

        let fin = (firstByte & 0x80) != 0
        let opcodeRaw = firstByte & 0x0F
        let masked = (secondByte & 0x80) != 0

        guard let opcode = WebSocketOpcode(rawValue: opcodeRaw) else { return nil }

        var payloadLength: UInt64 = 0
        var offset = 2

        let lengthField = secondByte & 0x7F
        if lengthField <= 125 {
            payloadLength = UInt64(lengthField)
        } else if lengthField == 126 {
            guard data.count >= 4 else { return nil }
            let l16 = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            payloadLength = UInt64(l16)
            offset = 4
        } else if lengthField == 127 {
            guard data.count >= 10 else { return nil }
            var l64: UInt64 = 0
            for i in 0..<8 {
                l64 = (l64 << 8) | UInt64(bytes[2 + i])
            }
            payloadLength = l64
            offset = 10
        }

        var maskKeyData: Data?
        if masked {
            guard data.count >= offset + 4 else { return nil }
            maskKeyData = data.subdata(in: offset..<(offset + 4))
            offset += 4
        }

        guard data.count >= offset + Int(payloadLength) else { return nil }

        var payload = data.subdata(in: offset..<(offset + Int(payloadLength)))

        if let maskKeyData, masked {
            for i in 0..<payload.count {
                payload[payload.startIndex + i] ^= maskKeyData[maskKeyData.startIndex + (i % 4)]
            }
        }

        return WebSocketFrame(
            fin: fin,
            opcode: opcode,
            masked: masked,
            payloadLength: payloadLength,
            maskKey: maskKeyData,
            payload: payload
        )
    }

    // MARK: - Receiving

    private func receiveWebSocketFrame(from client: WebSocketClient) {
        client.connection.receive(minimumIncompleteLength: 2, maximumLength: config.maxPayloadSize) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }

            if let error = error {
                print("[WSServer] Receive error from \(client.id): \(error)")
                self.removeClient(client)
                return
            }

            if isComplete && (data == nil || data?.isEmpty == true) {
                self.removeClient(client)
                return
            }

            guard let data = data, !data.isEmpty else {
                self.receiveWebSocketFrame(from: client)
                return
            }

            bufferLock.withLock {
                var buffer = self.receiveBuffers[client.id] ?? Data()
                buffer.append(data)
                self.receiveBuffers[client.id] = buffer
            }

            self.processBuffer(for: client)
            self.receiveWebSocketFrame(from: client)
        }
    }

    private func processBuffer(for client: WebSocketClient) {
        while true {
            let frameData: Data? = bufferLock.withLock {
                guard let buffer = receiveBuffers[client.id], buffer.count >= 2 else { return nil }
                return buffer
            }

            guard let frameData, let frame = decodeFrame(from: frameData) else {
                break
            }

            let consumed = 2 + (frame.masked ? 4 : 0) + Int(frame.payloadLength)
            guard consumed <= frameData.count else { break }

            bufferLock.withLock {
                receiveBuffers[client.id]?.removeFirst(consumed)
            }

            handleFrame(frame, from: client)
        }
    }

    private func handleFrame(_ frame: WebSocketFrame, from client: WebSocketClient) {
        switch frame.opcode {
        case .text:
            handleTextMessage(frame.payload, from: client)
        case .binary:
            break
        case .ping:
            let pong = encodeFrame(opcode: .pong, payload: frame.payload)
            sendRawData(pong, to: client)
        case .pong:
            client.lastPongReceived = Date()
            client.isAlive = true
        case .close:
            let closeResponse = encodeCloseFrame(code: 1000, reason: "Goodbye")
            sendRawData(closeResponse, to: client)
            removeClient(client)
        case .continuation:
            break
        }
    }

    private func handleTextMessage(_ data: Data, from client: WebSocketClient) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendError("Invalid JSON", to: client)
            return
        }

        guard let type = json["type"] as? String else {
            sendError("Missing 'type' field", to: client)
            return
        }

        totalMessagesReceived += 1

        switch type {
        case "subscribe":
            if let channels = json["channels"] as? [String] {
                client.subscribedChannels = Set(channels)
                let response: [String: Any] = [
                    "type": "subscribed",
                    "channels": Array(client.subscribedChannels)
                ]
                sendMessage(WebSocketMessage(type: "subscribed", payload: response), to: client)
            }

        case "unsubscribe":
            if let channels = json["channels"] as? [String] {
                for channel in channels {
                    client.subscribedChannels.remove(channel)
                }
                let response: [String: Any] = [
                    "type": "unsubscribed",
                    "channels": Array(client.subscribedChannels)
                ]
                sendMessage(WebSocketMessage(type: "unsubscribed", payload: response), to: client)
            }

        case "ping":
            let response: [String: Any] = [
                "type": "pong",
                "serverTime": ISO8601DateFormatter().string(from: Date())
            ]
            sendMessage(WebSocketMessage(type: "pong", payload: response), to: client)

        case "request_frame":
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let jpegData = self.frameProvider() {
                    let base64 = jpegData.base64EncodedString()
                    let msg = WebSocketMessage(type: "frame", payload: ["data": base64])
                    self.sendMessage(msg, to: client)
                }
            }

        case "get_stats":
            Task { @MainActor [weak self] in
                guard let self else { return }
                let stats = self.streamingStatsProvider()
                let msg = WebSocketMessage(type: "stats", payload: [
                    "bitrate": stats.bitrate,
                    "fps": stats.fps,
                    "framesDropped": stats.framesDropped,
                    "totalFrames": stats.totalFrames,
                    "duration": stats.duration,
                    "codec": stats.codec,
                    "resolution": stats.resolution,
                    "isStreaming": stats.isStreaming
                ] as [String: Any])
                self.sendMessage(msg, to: client)
            }

        case "get_status":
            Task { @MainActor [weak self] in
                guard let self else { return }
                let stats = self.streamingStatsProvider()
                let msg = WebSocketMessage(type: "status", payload: [
                    "streaming": stats.isStreaming,
                    "camera": "back",
                    "connectedClients": self.connectedClients,
                    "codec": stats.codec,
                    "resolution": stats.resolution
                ] as [String: Any])
                self.sendMessage(msg, to: client)
            }

        default:
            sendError("Unknown message type: \(type)", to: client)
        }
    }

    // MARK: - Sending

    func sendMessage(_ message: WebSocketMessage, to client: WebSocketClient) {
        guard client.isAlive else { return }
        guard let data = message.toJSONData() else { return }
        let frame = encodeFrame(opcode: .text, payload: data)
        sendRawData(frame, to: client)
        totalMessagesSent += 1
    }

    func broadcast(_ message: WebSocketMessage) {
        guard let data = message.toJSONData() else { return }
        let frame = encodeFrame(opcode: .text, payload: data)
        var count = 0

        clientsLock.withLock {
            for (_, client) in clients {
                if client.isAlive {
                    sendRawData(frame, to: client)
                    count += 1
                }
            }
        }
        totalMessagesSent += count
    }

    func broadcastToSubscribers(_ message: WebSocketMessage, channel: String) {
        guard let data = message.toJSONData() else { return }
        let frame = encodeFrame(opcode: .text, payload: data)
        var count = 0

        clientsLock.withLock {
            for (_, client) in clients {
                if client.isAlive && client.subscribedChannels.contains(channel) {
                    sendRawData(frame, to: client)
                    count += 1
                }
            }
        }
        totalMessagesSent += count
    }

    func sendError(_ errorMessage: String, to client: WebSocketClient) {
        let msg = WebSocketMessage(type: "error", payload: ["message": errorMessage])
        sendMessage(msg, to: client)
    }

    private func sendRawData(_ data: Data, to client: WebSocketClient) {
        client.connection.send(content: data, completion: .contentProcessed { [weak client] error in
            if let error = error {
                print("[WSServer] Send error to \(client?.id.uuidString ?? "?"): \(error)")
            }
        })
    }

    // MARK: - Keepalive (Ping/Pong)

    private func startPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + config.pingInterval, repeating: config.pingInterval)
        timer.setEventHandler { [weak self] in
            self?.performPingCycle()
        }
        timer.resume()
        pingTimer = timer
    }

    private func performPingCycle() {
        let pingPayload = Data("keepalive".utf8)
        let pingFrame = encodeFrame(opcode: .ping, payload: pingPayload)
        let now = Date()

        var deadClients: [WebSocketClient] = []

        clientsLock.withLock {
            for (_, client) in clients {
                let elapsed = now.timeIntervalSince(client.lastPongReceived)
                if elapsed > config.pingInterval + config.pongTimeout {
                    deadClients.append(client)
                } else {
                    sendRawData(pingFrame, to: client)
                }
            }
        }

        for client in deadClients {
            print("[WSServer] Client \(client.id) timed out, removing")
            removeClient(client)
        }
    }

    // MARK: - Stats Broadcasting

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.broadcastCurrentStats()
        }
        timer.resume()
        statsTimer = timer
    }

    private func broadcastCurrentStats() {
        let hasSubscribers = clientsLock.withLock {
            clients.values.contains { $0.isAlive && $0.subscribedChannels.contains("stats") }
        }
        guard hasSubscribers else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let stats = self.streamingStatsProvider()
            let message = WebSocketMessage(type: "stats", payload: [
                "bitrate": String(format: "%.1f", stats.bitrate),
                "bitrateNumeric": stats.bitrate,
                "fps": String(format: "%.1f", stats.fps),
                "fpsNumeric": stats.fps,
                "framesDropped": stats.framesDropped,
                "totalFrames": stats.totalFrames,
                "duration": String(format: "%.1f", stats.duration),
                "durationSeconds": stats.duration,
                "codec": stats.codec,
                "resolution": stats.resolution,
                "isStreaming": stats.isStreaming,
                "latency": 0,
                "connectionCount": stats.connectionCount
            ] as [String: Any])
            self.broadcastToSubscribers(message, channel: "stats")
        }
    }

    // MARK: - Public Frame Push

    func pushFrame(_ jpegData: Data) {
        let hasSubscribers = clientsLock.withLock {
            clients.values.contains { $0.isAlive && $0.subscribedChannels.contains("frame") }
        }
        guard hasSubscribers else { return }

        let base64 = jpegData.base64EncodedString()
        let message = WebSocketMessage(type: "frame", payload: ["data": base64])
        broadcastToSubscribers(message, channel: "frame")
    }

    // MARK: - Broadcast Helpers

    func broadcastStatusUpdate(_ status: [String: Any]) {
        let message = WebSocketMessage(type: "status", payload: status)
        broadcastToSubscribers(message, channel: "status")
    }

    func broadcastError(_ error: String) {
        let message = WebSocketMessage(type: "error", payload: ["message": error])
        broadcast(message)
    }

    func getClientInfo() -> [[String: Any]] {
        clientsLock.withLock {
            clients.values.map { client in
                [
                    "id": client.id.uuidString,
                    "connectedAt": ISO8601DateFormatter().string(from: client.connectedAt),
                    "duration": client.connectionDuration,
                    "channels": Array(client.subscribedChannels),
                    "isAlive": client.isAlive
                ] as [String: Any]
            }
        }
    }
}
