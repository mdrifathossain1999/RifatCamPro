import Foundation
import Network
import Combine
import os

// MARK: - Network Stats

struct NetworkServiceStats: Sendable {
    var bytesSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var uploadSpeed: Double = 0
    var downloadSpeed: Double = 0
    var latency: TimeInterval = 0
    var connectionUptime: TimeInterval = 0
    var peakUploadSpeed: Double = 0
    var peakDownloadSpeed: Double = 0
    var totalPacketsSent: UInt64 = 0
    var totalPacketsReceived: UInt64 = 0
}

// MARK: - Connection State

enum NetworkServiceState: Sendable {
    case disconnected
    case listening
    case connecting
    case authenticating
    case connected
    case waiting(String)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var displayString: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .listening: return "Listening"
        case .connecting: return "Connecting..."
        case .authenticating: return "Authenticating..."
        case .connected: return "Connected"
        case .waiting(let msg): return "Waiting: \(msg)"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    static func fromNWListenerState(_ state: NWListener.State) -> NetworkServiceState {
        switch state {
        case .ready: return .listening
        case .failed(let error): return .failed(error.localizedDescription)
        case .waiting(let error): return .waiting(error.localizedDescription)
        case .cancelled: return .disconnected
        default: return .listening
        }
    }

    static func fromNWConnectionState(_ state: NWConnection.State) -> NetworkServiceState {
        switch state {
        case .ready: return .connected
        case .failed(let error): return .failed(error.localizedDescription)
        case .waiting(let error): return .waiting(error.localizedDescription)
        case .cancelled: return .disconnected
        default: return .connecting
        }
    }
}

// MARK: - NetworkError

enum NetworkError: Error, LocalizedError {
    case noActiveConnection
    case encodingFailed
    case listenerCreationFailed
    case connectionTimeout
    case authenticationFailed
    case tlsConfigurationFailed

    var errorDescription: String? {
        switch self {
        case .noActiveConnection: return "No active connection available"
        case .encodingFailed: return "Failed to encode data"
        case .listenerCreationFailed: return "Failed to create network listener"
        case .connectionTimeout: return "Connection timed out"
        case .authenticationFailed: return "Authentication failed"
        case .tlsConfigurationFailed: return "TLS configuration failed"
        }
    }
}

// MARK: - NetworkService

@Observable
final class NetworkService: Sendable {

    // MARK: - Published State

    private(set) var connectionState: NetworkServiceState = .disconnected
    private(set) var stats = NetworkServiceStats()
    private(set) var connectedClientAddress: String?
    private(set) var localIPAddress: String?

    // MARK: - Combine Subjects

    let connectionStateChange = PassthroughSubject<NetworkServiceState, Never>()
    let dataReceived = PassthroughSubject<(Data, NWConnection), Never>()
    let errorSubject = PassthroughSubject<Error, Never>()

    // MARK: - Configuration

    var port: UInt16
    var useTLS: Bool
    var connectionTimeout: TimeInterval
    var requiredPassword: String?

    // MARK: - Private State

    private let logger: os.Logger
    private let speedMonitor: SpeedMonitor
    private let lock = NSLock()

    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private let listenerQueue = DispatchQueue(label: "com.rifatcam.pro.listener", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "com.rifatcam.pro.connection", qos: .userInitiated)
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.rifatcam.pro.pathmonitor", qos: .utility)

    private var connectionStartTime: Date?
    private var statsTimer: Timer?

    private var _bytesSentThisSession: UInt64 = 0
    private var _bytesReceivedThisSession: UInt64 = 0
    private var _latencyAccumulator: [TimeInterval] = []

    // MARK: - Init

    init(
        port: UInt16 = 5000,
        useTLS: Bool = false,
        connectionTimeout: TimeInterval = 15.0,
        requiredPassword: String? = nil
    ) {
        self.port = port
        self.useTLS = useTLS
        self.connectionTimeout = connectionTimeout
        self.requiredPassword = requiredPassword
        self.logger = Logger(subsystem: "com.rifatcam.pro", category: "NetworkService")
        self.speedMonitor = SpeedMonitor(windowDuration: 5.0, updateInterval: 0.5)
        self.localIPAddress = Self.detectWiFiIPAddress()
    }

    deinit {
        forceStop()
    }

    // MARK: - Public API: Lifecycle

    func start() {
        guard connectionState != .listening, connectionState != .connected else {
            logger.warning("Already running, ignoring start()")
            return
        }

        localIPAddress = Self.detectWiFiIPAddress()
        setupListener()
        startPathMonitor()
        startStatsTimer()
    }

    func stop() {
        stopPathMonitor()
        stopStatsTimer()
        cancelAllConnections()
        listener?.cancel()
        listener = nil

        lock.lock()
        connectionState = .disconnected
        lock.unlock()

        connectionStateChange.send(.disconnected)
        logger.info("NetworkService stopped")
    }

    private func forceStop() {
        stopPathMonitor()
        stopStatsTimer()
        cancelAllConnections()
        listener?.cancel()
        listener = nil
    }

    // MARK: - Public API: Send Data

    func send(_ data: Data, to connection: NWConnection? = nil) {
        if let target = connection {
            sendData(data, to: target)
        } else {
            lock.lock()
            let allConnections = activeConnections
            lock.unlock()

            for conn in allConnections {
                sendData(data, to: conn)
            }
        }
    }

    func send(_ data: Data, completion: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        lock.lock()
        let allConnections = activeConnections
        lock.unlock()

        guard !allConnections.isEmpty else {
            completion?(.failure(NetworkError.noActiveConnection))
            return
        }

        let totalCount = allConnections.count
        var completedCount = 0
        let errorLock = NSLock()
        var hasError = false

        for conn in allConnections {
            sendData(data, to: conn) { result in
                errorLock.lock()
                if case .failure(let error) = result, !hasError {
                    hasError = true
                    errorLock.unlock()
                    completion?(.failure(error))
                } else {
                    completedCount += 1
                    let done = completedCount == totalCount && !hasError
                    errorLock.unlock()
                    if done {
                        completion?(.success(()))
                    }
                }
            }
        }
    }

    // MARK: - Public API: Metrics

    func measureLatency(to connection: NWConnection) async throws -> TimeInterval {
        let startTime = Date()

        let payload = "{\"type\":\"ping\",\"ts\":\(Int(startTime.timeIntervalSince1970 * 1000))}"
        guard let data = payload.data(using: .utf8) else {
            throw NetworkError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { content, _, _, error in
                    let elapsed = Date().timeIntervalSince(startTime)
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        self.lock.lock()
                        self._latencyAccumulator.append(elapsed)
                        if self._latencyAccumulator.count > 100 {
                            self._latencyAccumulator.removeFirst(self._latencyAccumulator.count - 100)
                        }
                        self.lock.unlock()
                        continuation.resume(returning: elapsed)
                    }
                }
            })
        }
    }

    func refreshIPAddress() {
        localIPAddress = Self.detectWiFiIPAddress()
    }

    func getWiFiIPAddress() -> String? {
        return Self.detectWiFiIPAddress()
    }

    // MARK: - WiFi IP Detection

    static func detectWiFiIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var result: String?
        var ptr = firstAddr

        while true {
            let interface = ptr.pointee
            guard let addrPtr = interface.ifa_addr else {
                guard let next = interface.ifa_next else { break }
                ptr = next
                continue
            }

            let addrFamily = addrPtr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)

                if name.hasPrefix("en0") || name.hasPrefix("en1") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let sockAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let getErr = getnameinfo(
                        addrPtr,
                        sockLen_t(sockAddrLen),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if getErr == 0 {
                        let address = String(cString: hostname)
                        if !address.isEmpty {
                            result = address
                            break
                        }
                    }
                }
            }

            guard let next = interface.ifa_next else { break }
            ptr = next
        }

        return result
    }

    // MARK: - Listener Setup

    private func setupListener() {
        let params: NWParameters
        if useTLS {
            let tcpParams = NWParameters.tcp
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(
                tlsOptions.securityProtocolOptions,
                .TLSv12
            )
            params = NWParameters(tls: tlsOptions, tcp: tcpParams)
        } else {
            params = NWParameters.tcp
        }

        params.allowLocalEndpointReuse = true
        params.explicitPeerIdentity = true

        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw NetworkError.listenerCreationFailed
            }

            let nwListener = try NWListener(using: params, on: nwPort)

            nwListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            self.listener = nwListener
            nwListener.start(queue: listenerQueue)

            lock.lock()
            connectionState = .listening
            lock.unlock()

            connectionStateChange.send(.listening)
            logger.info("TCP listener started on port \(self.port)")
        } catch {
            logger.error("Failed to create listener: \(error.localizedDescription)")
            lock.lock()
            connectionState = .failed(error.localizedDescription)
            lock.unlock()
            connectionStateChange.send(.failed(error.localizedDescription))
            errorSubject.send(error)
        }
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        let newState = NetworkServiceState.fromNWListenerState(state)

        lock.lock()
        connectionState = newState
        lock.unlock()

        connectionStateChange.send(newState)

        switch state {
        case .ready:
            logger.info("Listener is ready")
        case .failed(let error):
            logger.error("Listener failed: \(error.localizedDescription)")
            errorSubject.send(error)
        case .cancelled:
            logger.info("Listener cancelled")
        case .waiting(let error):
            logger.warning("Listener waiting: \(error.localizedDescription)")
            errorSubject.send(error)
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        logger.info("New incoming connection")

        extractClientAddress(from: connection)

        lock.lock()
        connectionState = .authenticating
        lock.unlock()
        connectionStateChange.send(.authenticating)

        if requiredPassword != nil {
            performAuthHandshake(connection)
        } else {
            completeConnection(connection)
        }
    }

    private func extractClientAddress(from connection: NWConnection) {
        if let endpoint = connection.currentPath?.remoteEndpoint {
            var address: String?

            switch endpoint {
            case .hostPort(let host, _):
                switch host {
                case .ipv4(let addr): address = "\(addr)"
                case .ipv6(let addr): address = "\(addr)"
                case .name(let name, _): address = name
                @unknown default: break
                }
            default:
                break
            }

            if let addr = address {
                lock.lock()
                connectedClientAddress = addr
                lock.unlock()
            }
        }
    }

    // MARK: - Authentication Handshake

    private func performAuthHandshake(_ connection: NWConnection) {
        connection.start(queue: connectionQueue)
        authReceiveLoop(connection)
    }

    private func authReceiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.error("Auth receive error: \(error.localizedDescription)")
                self.sendAuthFailure(connection, reason: "communication_error")
                connection.cancel()
                return
            }

            guard let data = data, !data.isEmpty else {
                if isComplete {
                    self.logger.warning("Client disconnected during auth")
                    connection.cancel()
                    return
                }
                self.authReceiveLoop(connection)
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "auth",
                  let password = json["password"] as? String else {
                self.sendAuthFailure(connection, reason: "invalid_message")
                connection.cancel()
                return
            }

            if password == self.requiredPassword {
                self.sendAuthSuccess(connection)
                self.completeConnection(connection)
            } else {
                self.sendAuthFailure(connection, reason: "invalid_password")
                connection.cancel()
            }
        }
    }

    private func sendAuthSuccess(_ connection: NWConnection) {
        let response = "{\"type\":\"auth_result\",\"success\":true}"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.logger.error("Failed to send auth success: \(error.localizedDescription)")
                }
            })
        }
    }

    private func sendAuthFailure(_ connection: NWConnection, reason: String) {
        let safeReason = reason.replacingOccurrences(of: "\"", with: "\\\"")
        let response = "{\"type\":\"auth_result\",\"success\":false,\"reason\":\"\(safeReason)\"}"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func completeConnection(_ connection: NWConnection) {
        lock.lock()
        activeConnections.append(connection)
        lock.unlock()

        setupConnectionStateHandler(connection)
        setupDataReceiving(connection)

        connectionStartTime = Date()

        lock.lock()
        connectionState = .connected
        lock.unlock()

        connectionStateChange.send(.connected)
        logger.info("Connection established successfully")

        startConnectionTimeout(for: connection)
    }

    // MARK: - Connection State Monitoring

    private func setupConnectionStateHandler(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:
                self.logger.info("Connection ready")
                self.extractClientAddress(from: connection)

            case .failed(let error):
                self.logger.error("Connection failed: \(error.localizedDescription)")
                self.handleConnectionLost(connection, error: error)

            case .cancelled:
                self.logger.info("Connection cancelled")
                self.handleConnectionLost(connection, error: nil)

            case .waiting(let error):
                self.logger.warning("Connection waiting: \(error.localizedDescription)")

            default:
                break
            }
        }
    }

    private func handleConnectionLost(_ connection: NWConnection, error: Error?) {
        lock.lock()
        activeConnections.removeAll { $0 === connection }
        let remainingCount = activeConnections.count
        lock.unlock()

        if remainingCount == 0 {
            let newState: NetworkServiceState
            if let error = error {
                newState = .failed(error.localizedDescription)
            } else {
                newState = .disconnected
            }

            lock.lock()
            connectionState = newState
            lock.unlock()

            connectionStateChange.send(newState)
        }

        if let error = error {
            errorSubject.send(error)
        }
    }

    // MARK: - Data Receiving

    private func setupDataReceiving(_ connection: NWConnection) {
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.error("Receive error: \(error.localizedDescription)")
                self.errorSubject.send(error)
                self.handleConnectionLost(connection, error: error)
                return
            }

            if isComplete {
                self.logger.info("Connection complete (remote closed)")
                self.handleConnectionLost(connection, error: nil)
                return
            }

            if let data = data, !data.isEmpty {
                self.lock.lock()
                self._bytesReceivedThisSession += UInt64(data.count)
                self.lock.unlock()

                self.speedMonitor.recordDownload(bytes: UInt64(data.count))

                self.dataReceived.send((data, connection))
                self.receiveLoop(connection)
            } else {
                self.receiveLoop(connection)
            }
        }
    }

    // MARK: - Send Data

    private func sendData(_ data: Data, to connection: NWConnection, completion: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        lock.lock()
        _bytesSentThisSession += UInt64(data.count)
        lock.unlock()

        speedMonitor.recordUpload(bytes: UInt64(data.count))

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Send error: \(error.localizedDescription)")
                self?.errorSubject.send(error)
                completion?(.failure(error))
            } else {
                completion?(.success(()))
            }
        })
    }

    // MARK: - Connection Timeout

    private func startConnectionTimeout(for connection: NWConnection) {
        let deadline = DispatchTime.now() + connectionTimeout
        connectionQueue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self = self else { return }

            self.lock.lock()
            let stillActive = self.activeConnections.contains { $0 === connection }
            self.lock.unlock()

            guard stillActive else { return }

            let state = connection.state
            if case .ready = state {
                return
            }

            self.logger.warning("Connection timed out after \(self.connectionTimeout)s")
            connection.cancel()
            self.errorSubject.send(NetworkError.connectionTimeout)
        }
    }

    // MARK: - Path Monitor

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            if path.status == .satisfied {
                self.logger.info("Network path available")
                let newIP = Self.detectWiFiIPAddress()
                self.localIPAddress = newIP
            } else {
                self.logger.warning("Network path unsatisfied")
            }

            for interface in path.availableInterfaces {
                let desc = "\(interface.type): \(interface.name)"
                self.logger.debug("Available interface: \(desc)")
            }
        }

        monitor.start(queue: monitorQueue)
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Stats Timer

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        if let timer = statsTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func updateStats() {
        lock.lock()
        let startTime = connectionStartTime
        let rawSent = _bytesSentThisSession
        let rawReceived = _bytesReceivedThisSession
        let latencies = _latencyAccumulator
        lock.unlock()

        let uptime: TimeInterval
        if let startTime = startTime {
            uptime = -startTime.timeIntervalSinceNow
        } else {
            uptime = 0
        }

        let dlSpeed = speedMonitor.currentDownloadSpeed
        let ulSpeed = speedMonitor.currentUploadSpeed

        var newStats = NetworkServiceStats()
        newStats.bytesSent = rawSent
        newStats.bytesReceived = rawReceived
        newStats.uploadSpeed = ulSpeed
        newStats.downloadSpeed = dlSpeed
        newStats.connectionUptime = uptime
        newStats.peakUploadSpeed = max(stats.peakUploadSpeed, ulSpeed)
        newStats.peakDownloadSpeed = max(stats.peakDownloadSpeed, dlSpeed)

        if !latencies.isEmpty {
            let sorted = latencies.sorted()
            let medianIndex = sorted.count / 2
            newStats.latency = sorted[medianIndex]
        }

        stats = newStats
    }

    // MARK: - Cleanup

    private func cancelAllConnections() {
        lock.lock()
        let connections = activeConnections
        activeConnections.removeAll()
        lock.unlock()

        for conn in connections {
            conn.cancel()
        }

        connectedClientAddress = nil
        speedMonitor.reset()

        lock.lock()
        _bytesSentThisSession = 0
        _bytesReceivedThisSession = 0
        _latencyAccumulator.removeAll()
        lock.unlock()
    }
}
