import Foundation
import Network
import AVFoundation
import Combine
import Observation

enum MJPEGStreamingError: LocalizedError {
    case serverNotRunning
    case failedToStartServer(Error)
    case clientWriteFailed(Error)
    case authenticationRequired
    case invalidRequest
    case encodingFailed
    
    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "MJPEG server is not running"
        case .failedToStartServer(let error):
            return "Failed to start MJPEG server: \(error.localizedDescription)"
        case .clientWriteFailed(let error):
            return "Failed to write to client: \(error.localizedDescription)"
        case .authenticationRequired:
            return "Authentication required"
        case .invalidRequest:
            return "Invalid HTTP request"
        case .encodingFailed:
            return "Failed to encode JPEG frame"
        }
    }
}

@Observable
final class MJPEGStreamingService {
    private(set) var isRunning = false
    private(set) var connectedClientCount = 0
    private(set) var port: UInt16
    private(set) var lastError: MJPEGStreamingError?
    
    var password: String?
    
    private var listener: NWListener?
    private var clients: [MJPEGClient] = []
    private let clientsLock = NSLock()
    private let boundary = "RifatCamBoundary"
    private var frameBuffer: Data?
    private let frameBufferLock = NSLock()
    private let sessionQueue = DispatchQueue(label: "com.rifatcam.mjpeg", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    
    struct MJPEGClient {
        let connection: NWConnection
        let id: UUID
        var isAuthenticated: Bool
        var isSending: Bool
        var pendingData: Data?
    }
    
    init(port: UInt16 = 8080) {
        self.port = port
    }
    
    deinit {
        stop()
    }
    
    func start() throws {
        guard !isRunning else { return }
        
        do {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.internetProtocol = .init(.ipv4)
            
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
            throw MJPEGStreamingError.failedToStartServer(error)
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
    
    func pushFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else { return }
        
        clientsLock.lock()
        let hasClients = !clients.isEmpty
        clientsLock.unlock()
        
        guard hasClients else { return }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(
            ciImage,
            from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
        ) else { return }
        
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, "public.jpeg" as CFString, 1, nil
        ) else { return }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.7
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else { return }
        
        let jpegData = mutableData as Data
        
        let header = "--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else { return }
        
        var frameData = Data()
        frameData.append(headerData)
        frameData.append(jpegData)
        frameData.append("\r\n".data(using: .utf8)!)
        
        clientsLock.lock()
        let currentClients = clients
        clientsLock.unlock()
        
        for client in currentClients {
            guard client.isAuthenticated && !client.isSending else { continue }
            sendFrameData(frameData, to: client)
        }
    }
    
    func pushJPEGData(_ data: Data) {
        guard isRunning else { return }
        
        clientsLock.lock()
        let hasClients = !clients.isEmpty
        clientsLock.unlock()
        
        guard hasClients else { return }
        
        let header = "--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(data.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else { return }
        
        var frameData = Data()
        frameData.append(headerData)
        frameData.append(data)
        frameData.append("\r\n".data(using: .utf8)!)
        
        clientsLock.lock()
        let currentClients = clients
        clientsLock.unlock()
        
        for client in currentClients {
            guard client.isAuthenticated && !client.isSending else { continue }
            sendFrameData(frameData, to: client)
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let client = MJPEGClient(
            connection: connection,
            id: UUID(),
            isAuthenticated: password == nil,
            isSending: false
        )
        
        clientsLock.lock()
        clients.append(client)
        clientsLock.unlock()
        
        Task { @MainActor in
            self.connectedClientCount = self.clients.count
        }
        
        connection.start(queue: sessionQueue)
        receiveRequest(from: connection, clientId: client.id)
    }
    
    private func receiveRequest(from connection: NWConnection, clientId: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if let error {
                self.removeClient(id: clientId)
                return
            }
            
            if isComplete {
                self.removeClient(id: clientId)
                return
            }
            
            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.removeClient(id: clientId)
                return
            }
            
            guard request.hasPrefix("GET") || request.hasPrefix("OPTIONS") else {
                self.removeClient(id: clientId)
                return
            }
            
            if let password = self.password {
                if request.contains("Authorization:") {
                    let authLine = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("authorization:") } ?? ""
                    let token = authLine.components(separatedBy: " ").last ?? ""
                    let expectedAuth = "Basic " + Data("\(self.password ?? ""):".utf8).base64EncodedString()
                    
                    clientsLock.lock()
                    if let idx = clients.firstIndex(where: { $0.id == clientId }) {
                        clients[idx].isAuthenticated = (token == expectedAuth)
                    }
                    clientsLock.unlock()
                }
                
                let authed = clientsLock.withLock { clients.first { $0.id == clientId }?.isAuthenticated ?? false }
                guard authed else {
                    let response = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"RifatCam Pro\"\r\nContent-Length: 0\r\n\r\n"
                    if let respData = response.data(using: .utf8) {
                        connection.send(content: respData, completion: .contentProcessed { _ in
                            self.removeClient(id: clientId)
                        })
                    }
                    return
                }
            }
            
            let response = """
            HTTP/1.1 200 OK\r\n\
            Content-Type: multipart/x-mixed-replace; boundary=\(self.boundary)\r\n\
            Cache-Control: no-cache\r\n\
            Pragma: no-cache\r\n\
            Connection: close\r\n\
            Access-Control-Allow-Origin: *\r\n\
            \r\n
            """
            
            guard let responseData = response.data(using: .utf8) else {
                self.removeClient(id: clientId)
                return
            }
            
            connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.removeClient(id: clientId)
                    return
                }
                
                self.clientsLock.lock()
                if let idx = self.clients.firstIndex(where: { $0.id == clientId }) {
                    self.clients[idx].isSending = true
                }
                self.clientsLock.unlock()
            })
        }
    }
    
    private func sendFrameData(_ data: Data, to client: MJPEGClient) {
        client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.removeClient(id: client.id)
                Task { @MainActor in
                    self.lastError = .clientWriteFailed(error)
                }
            }
        })
    }
    
    private func removeClient(id: UUID) {
        clientsLock.lock()
        if let idx = clients.firstIndex(where: { $0.id == id }) {
            let client = clients[idx]
            client.connection.cancel()
            clients.remove(at: idx)
        }
        let count = clients.count
        clientsLock.unlock()
        
        Task { @MainActor in
            self.connectedClientCount = count
        }
    }
}
