import Foundation
import Network
import Combine
import Observation
import UIKit

final class ConnectionManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var connectionStatus: ConnectionStatus = .disconnected
    private(set) var networkStats = NetworkStats()
    private(set) var discoveredServers: [DiscoveredServer] = []
    private(set) var isInBackground = false
    private(set) var lastError: ConnectionError?
    private(set) var reconnectAttempts = 0
    private(set) var uptime: TimeInterval = 0

    // MARK: - Configuration

    var autoReconnect = true
    var maxReconnectAttempts = 5
    var reconnectDelay: TimeInterval = 2.0
    var connectionTimeout: TimeInterval = 10

    // MARK: - Dependencies

    private let cameraService: CameraService
    private let securityService: SecurityService
    private let settingsManager: SettingsManager
    private let speedMonitor: SpeedMonitor

    // MARK: - Combine

    let stateChanged = PassthroughSubject<ConnectionState, Never>()
    let connectionStatusChanged = PassthroughSubject<ConnectionStatus, Never>()
    let errorOccurred = PassthroughSubject<ConnectionError, Never>()
    let serverDiscovered = PassthroughSubject<DiscoveredServer, Never>()
    let serverLost = PassthroughSubject<String, Never>()
    let willConnect = PassthroughSubject<ConnectionTarget, Never>()
    let didConnect = PassthroughSubject<String, Never>()
    let didDisconnect = PassthroughSubject<ConnectionError?, Never>()
    let willStartStreaming = PassthroughSubject<Void, Never>()
    let didStartStreaming = PassthroughSubject<Void, Never>()
    let willStopStreaming = PassthroughSubject<Void, Never>()
    let didStopStreaming = PassthroughSubject<Void, Never>()
    let authenticationRequired = PassthroughSubject<Void, Never>()

    // MARK: - Private State

    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var connectionQueue = DispatchQueue(label: "com.rifatcam.connection", qos: .userInitiated)
    private var reconnectTimer: DispatchSource?
    private var uptimeTimer: DispatchSource?
    private var connectionStartTime: Date?
    private var currentTarget: ConnectionTarget?
    private var pendingPassword: String?
    private var pairedToken: String?
    private var pairedDeviceID: String?
    private var cancellables = Set<AnyCancellable>()
    private var stateLock = NSLock()
    private var connectionLock = NSLock()
    private var streamSessionID = UUID()

    // MARK: - Initialization

    init(
        cameraService: CameraService = CameraService(),
        securityService: SecurityService = SecurityService(),
        settingsManager: SettingsManager = SettingsManager(),
        speedMonitor: SpeedMonitor = SpeedMonitor()
    ) {
        self.cameraService = cameraService
        self.securityService = securityService
        self.settingsManager = settingsManager
        self.speedMonitor = speedMonitor

        setupBackgroundNotifications()
        setupSettingsObservers()
    }

    deinit {
        disconnect()
        stopBrowser()
        stopUptimeTimer()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Connection Lifecycle

    func connect(to target: ConnectionTarget) {
        guard state == .disconnected || state == .failed else {
            return
        }

        currentTarget = target
        willConnect.send(target)
        transition(to: .connecting)

        connectionTimeout = settingsManager.currentSettings.network.connectionTimeout

        switch target {
        case .bonjour(let server):
            connectToServer(server)
        case .manual(let address, let port):
            connectToAddress(address, port: port)
        case .qrCode(let pairingData):
            connectWithPairing(pairingData)
        }

        startConnectionTimeout()
    }

    func connectToAddress(_ address: String, port: UInt16) {
        let host = NWEndpoint.Host(address)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            transition(to: .failed(ConnectionError.invalidAddress))
            return
        }

        let parameters = NWParameters.tcp

        let conn = NWConnection(host: host, port: nwPort, using: parameters)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            self?.handleConnectionStateUpdate(newState, address: "\(address):\(port)")
        }

        conn.start(queue: connectionQueue)
    }

    func connectToServer(_ server: DiscoveredServer) {
        let address = server.address ?? server.endpoint
        let port = server.port

        let parameters = NWParameters.tcp

        let conn = NWConnection(to: server.endpoint, using: parameters)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            self?.handleConnectionStateUpdate(newState, address: "\(address):\(port)")
        }

        conn.start(queue: connectionQueue)
    }

    func connectWithPairing(_ pairing: PairingData) {
        guard securityService.validatePairingData(pairing) else {
            transition(to: .failed(ConnectionError.invalidPairingData))
            return
        }

        pairedDeviceID = pairing.deviceID
        pairedToken = pairing.token

        connectToAddress("0.0.0.0", port: pairing.port)
    }

    func disconnect() {
        stopReconnectTimer()
        stopUptimeTimer()

        if state == .streaming {
            stopStreaming()
        }

        connectionLock.lock()
        let conn = connection
        connection = nil
        connectionLock.unlock()

        conn?.cancel()

        connectionStartTime = nil
        currentTarget = nil
        pendingPassword = nil
        pairedToken = nil
        pairedDeviceID = nil
        reconnectAttempts = 0

        transition(to: .disconnected)
    }

    func authenticate(password: String) {
        guard state == .authenticating else { return }

        pendingPassword = password

        let result = securityService.authenticateConnection(password: password)

        switch result {
        case .success(let token):
            pairedToken = token
            transition(to: .connected)
            didConnect.send(networkStats.localIP)
            if autoReconnect {
                startUptimeTimer()
            }

        case .failure(let error):
            transition(to: .failed(ConnectionError.authenticationFailed(error)))
        }
    }

    // MARK: - Streaming Control

    func startStreaming() {
        guard state == .connected else { return }

        willStartStreaming.send()
        streamSessionID = UUID()

        Task { @MainActor in
            do {
                try await cameraService.startSession()
            } catch {
                transition(to: .failed(ConnectionError.streamingStartFailed(error.localizedDescription)))
                return
            }

            let config = settingsManager.currentSettings.camera
            let targetResolution = config.resolution
            let targetFrameRate = config.frameRate
            let targetBitrate = Int(Double(config.bitrate) * 1.0)

            do {
                try await cameraService.configureSession(with: config)
            } catch {
                transition(to: .failed(ConnectionError.streamingStartFailed(error.localizedDescription)))
                return
            }

            cameraService.startSession()

            transition(to: .streaming)
            startUptimeTimer()
            didStartStreaming.send()
        }
    }

    func stopStreaming() {
        guard state == .streaming else { return }

        willStopStreaming.send()
        stopUptimeTimer()

        Task { @MainActor in
            cameraService.stopSession()
        }

        transition(to: .connected)
        didStopStreaming.send()
    }

    // MARK: - Background / Foreground

    func handleBackgroundTransition() {
        isInBackground = true

        guard state == .streaming else { return }

        if !settingsManager.currentSettings.backgroundStreaming {
            pauseStreaming()
        }
    }

    func handleForegroundTransition() {
        isInBackground = false

        if state == .streaming {
            resumeStreaming()
        } else if state == .connected && autoReconnect {
            startUptimeTimer()
        }
    }

    func pauseStreaming() {
        guard state == .streaming else { return }

        Task { @MainActor in
            cameraService.stopSession()
        }

        transition(to: .connected)
    }

    func resumeStreaming() {
        guard state == .connected, currentTarget != nil else { return }

        Task { @MainActor in
            do {
                try await cameraService.configureSession(with: settingsManager.currentSettings.camera)
                cameraService.startSession()
                transition(to: .streaming)
                startUptimeTimer()
            } catch {
                transition(to: .failed(ConnectionError.streamingStartFailed(error.localizedDescription)))
            }
        }
    }

    // MARK: - Bonjour Discovery

    func startBrowser(serviceType: String = "_rifatcam._tcp") {
        stopBrowser()

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }

            for result in results {
                let server = DiscoveredServer(
                    name: self.serverName(from: result),
                    endpoint: result.endpoint,
                    address: self.extractAddress(from: result),
                    port: self.extractPort(from: result),
                    isSecure: result.metadata != nil
                )
                self.discoveredServers.append(server)
                self.serverDiscovered.send(server)
            }

            for change in changes {
                if case .removed(let result) = change {
                    let name = self.serverName(from: result)
                    self.discoveredServers.removeAll { $0.name == name }
                    self.serverLost.send(name)
                }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.lastError = .discoveryFailed(error.localizedDescription)
                self?.errorOccurred.send(.discoveryFailed(error.localizedDescription))
            case .cancelled:
                break
            default:
                break
            }
        }

        browser.start(queue: connectionQueue)
    }

    func stopBrowser() {
        browser?.cancel()
        browser = nil
        discoveredServers.removeAll()
    }

    // MARK: - Reconnection

    func handleAutoReconnect() {
        guard autoReconnect,
              state == .failed || state == .disconnected,
              reconnectAttempts < maxReconnectAttempts,
              let target = currentTarget else {
            return
        }

        reconnectAttempts += 1

        let delay = reconnectDelay * Double(reconnectAttempts)
        startReconnectTimer(delay: delay) { [weak self] in
            self?.connect(to: target)
        }
    }

    func resetReconnectState() {
        reconnectAttempts = 0
        stopReconnectTimer()
    }

    // MARK: - Connection State Machine

    private func transition(to newState: ConnectionState) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let previousState = state
        guard previousState != newState else { return }

        state = newState

        let status: ConnectionStatus = {
            switch newState {
            case .disconnected:
                return .disconnected
            case .connecting:
                return .connecting
            case .authenticating:
                return .connecting
            case .connected(let address):
                return .connected(address: address)
            case .streaming:
                return .connected(address: networkStats.localIP)
            case .failed(let error):
                return .error(error.localizedDescription)
            }
        }()

        connectionStatus = status
        stateChanged.send(newState)
        connectionStatusChanged.send(status)

        switch newState {
        case .disconnected:
            reconnectAttempts = 0
            stopUptimeTimer()

        case .connected:
            reconnectAttempts = 0
            stopReconnectTimer()
            startUptimeTimer()

        case .streaming:
            startUptimeTimer()

        case .failed(let error):
            lastError = error
            errorOccurred.send(error)
            stopUptimeTimer()
            handleAutoReconnect()

        default:
            break
        }
    }

    // MARK: - Connection State Handler

    private func handleConnectionStateUpdate(_ nwState: NWConnection.State, address: String) {
        switch nwState {
        case .ready:
            let hasStoredPassword = securityService.hasStoredPassword()
            let hasPairedToken = pairedToken != nil

            if hasStoredPassword && !hasPairedToken {
                transition(to: .authenticating)
                authenticationRequired.send()
            } else {
                if let token = pairedToken, let clientID = pairedDeviceID {
                    let result = securityService.authenticateConnection(token: token, clientID: clientID)
                    if case .failure = result {
                        transition(to: .authenticating)
                        authenticationRequired.send()
                    } else {
                        transition(to: .connected(address: address))
                        networkStats.localIP = address
                        didConnect.send(address)
                        startUptimeTimer()
                    }
                } else {
                    transition(to: .connected(address: address))
                    networkStats.localIP = address
                    didConnect.send(address)
                    startUptimeTimer()
                }
            }

        case .waiting(let error):
            transition(to: .failed(ConnectionError.connectionWaiting(error.localizedDescription)))

        case .failed(let error):
            transition(to: .failed(ConnectionError.connectionLost(error.localizedDescription)))
            didDisconnect.send(ConnectionError.connectionLost(error.localizedDescription))

        case .cancelled:
            if state != .disconnected {
                transition(to: .disconnected)
                didDisconnect.send(nil)
            }

        case .preparing:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Data Send / Receive

    func send(_ data: Data) {
        connectionLock.lock()
        let conn = connection
        connectionLock.unlock()

        guard let conn, state == .connected || state == .streaming else { return }

        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.transition(to: .failed(ConnectionError.sendFailed(error.localizedDescription)))
            }
        })
    }

    func send(_ message: ConnectionMessage) {
        guard let data = message.encoded() else { return }
        send(data)
    }

    func receiveData() {
        connectionLock.lock()
        let conn = connection
        connectionLock.unlock()

        guard let conn else { return }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.transition(to: .failed(ConnectionError.receiveFailed(error.localizedDescription)))
                return
            }

            if isComplete {
                self.transition(to: .disconnected)
                self.didDisconnect.send(nil)
                return
            }

            if let data, !data.isEmpty {
                self.handleIncomingData(data)
            }

            self.receiveData()
        }
    }

    private func handleIncomingData(_ data: Data) {
        if let stats = try? JSONDecoder().decode(NetworkStats.self, from: data) {
            networkStats = stats
        }
    }

    // MARK: - Timeout

    private func startConnectionTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: connectionQueue)
        timer.schedule(deadline: .now() + connectionTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .connecting || self.state == .authenticating else { return }
            self.transition(to: .failed(ConnectionError.timeout))
            self.connection?.cancel()
        }
        timer.resume()

        connectionLock.lock()
        defer { connectionLock.unlock() }
    }

    // MARK: - Reconnect Timer

    private func startReconnectTimer(delay: TimeInterval, completion: @escaping () -> Void) {
        stopReconnectTimer()

        let timer = DispatchSource.makeTimerSource(queue: connectionQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard self != nil else { return }
            completion()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func stopReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - Uptime Timer

    private func startUptimeTimer() {
        guard uptimeTimer == nil else { return }
        if connectionStartTime == nil {
            connectionStartTime = Date()
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let start = self.connectionStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            Task { @MainActor in
                self.uptime = elapsed
            }
        }
        timer.resume()
        uptimeTimer = timer
    }

    private func stopUptimeTimer() {
        uptimeTimer?.cancel()
        uptimeTimer = nil
    }

    // MARK: - Background Notifications

    private func setupBackgroundNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        handleForegroundTransition()
    }

    @objc private func appWillResignActive() {
        handleBackgroundTransition()
    }

    @objc private func appDidEnterBackground() {
        isInBackground = true
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false
    }

    // MARK: - Settings Observers

    private func setupSettingsObservers() {
        settingsManager.cameraConfigurationChanged
            .sink { [weak self] config in
                guard let self, self.state == .streaming else { return }
                Task { @MainActor in
                    try? await self.cameraService.reconfigure(with: config)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Helpers

    private func serverName(from result: NWBrowser.Result) -> String {
        switch result.endpoint {
        case .service(let name, _, _, _):
            return name
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .unix(let path):
            return path
        case .url(let url):
            return url.absoluteString
        @unknown default:
            return "Unknown"
        }
    }

    private func extractAddress(from result: NWBrowser.Result) -> String? {
        switch result.endpoint {
        case .hostPort(let host, _):
            let desc = "\(host)"
            return desc.replacingOccurrences(of: "\"", with: "")
        case .service(_, _, _, _):
            return nil
        default:
            return nil
        }
    }

    private func extractPort(from result: NWBrowser.Result) -> UInt16? {
        switch result.endpoint {
        case .hostPort(_, let port):
            return port.rawValue
        case .service(_, _, _, _):
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Types

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case connected(address: String)
    case streaming
    case failed(ConnectionError)

    static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected): return true
        case (.connecting, .connecting): return true
        case (.authenticating, .authenticating): return true
        case (.connected(let a1), .connected(let a2)): return a1 == a2
        case (.streaming, .streaming): return true
        case (.failed(let e1), .failed(let e2)): return e1.localizedDescription == e2.localizedDescription
        default: return false
        }
    }

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .authenticating: return "Authenticating..."
        case .connected(let addr): return "Connected to \(addr)"
        case .streaming: return "Streaming"
        case .failed(let error): return "Failed: \(error.localizedDescription)"
        }
    }

    var iconName: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .connecting: return "wifi.exclamationmark"
        case .authenticating: return "lock.rotation"
        case .connected: return "wifi"
        case .streaming: return "play.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isConnected: Bool {
        switch self {
        case .connected, .streaming: return true
        default: return false
        }
    }

    var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }
}

enum ConnectionTarget: Sendable {
    case bonjour(DiscoveredServer)
    case manual(address: String, port: UInt16)
    case qrCode(PairingData)
}

enum ConnectionError: Error, Identifiable, Sendable {
    case invalidAddress
    case timeout
    case connectionLost(String)
    case connectionWaiting(String)
    case authenticationFailed(SecurityError)
    case sendFailed(String)
    case receiveFailed(String)
    case streamingStartFailed(String)
    case discoveryFailed(String)
    case invalidPairingData
    case serverUnavailable

    var id: String {
        switch self {
        case .invalidAddress: return "invalid_address"
        case .timeout: return "timeout"
        case .connectionLost: return "connection_lost"
        case .connectionWaiting: return "connection_waiting"
        case .authenticationFailed: return "auth_failed"
        case .sendFailed: return "send_failed"
        case .receiveFailed: return "receive_failed"
        case .streamingStartFailed: return "stream_start_failed"
        case .discoveryFailed: return "discovery_failed"
        case .invalidPairingData: return "invalid_pairing"
        case .serverUnavailable: return "server_unavailable"
        }
    }

    var title: String {
        switch self {
        case .invalidAddress: return "Invalid Address"
        case .timeout: return "Connection Timeout"
        case .connectionLost: return "Connection Lost"
        case .connectionWaiting: return "Waiting"
        case .authenticationFailed: return "Authentication Failed"
        case .sendFailed: return "Send Failed"
        case .receiveFailed: return "Receive Failed"
        case .streamingStartFailed: return "Streaming Error"
        case .discoveryFailed: return "Discovery Error"
        case .invalidPairingData: return "Invalid QR Code"
        case .serverUnavailable: return "Server Unavailable"
        }
    }

    var localizedDescription: String {
        message
    }

    var message: String {
        switch self {
        case .invalidAddress: return "The IP address or port is invalid."
        case .timeout: return "The connection attempt timed out."
        case .connectionLost(let detail): return "Connection lost: \(detail)"
        case .connectionWaiting(let detail): return "Waiting: \(detail)"
        case .authenticationFailed(let error): return "Authentication failed: \(error.message)"
        case .sendFailed(let detail): return "Failed to send data: \(detail)"
        case .receiveFailed(let detail): return "Failed to receive data: \(detail)"
        case .streamingStartFailed(let detail): return "Failed to start streaming: \(detail)"
        case .discoveryFailed(let detail): return "Service discovery failed: \(detail)"
        case .invalidPairingData: return "The QR code pairing data is invalid."
        case .serverUnavailable: return "The server is unavailable."
        }
    }
}

struct DiscoveredServer: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let endpoint: NWEndpoint
    let address: String?
    let port: UInt16?
    let isSecure: Bool

    var displayName: String {
        name.replacingOccurrences(of: " ", with: "")
    }

    var addressDisplay: String {
        if let address, let port {
            return "\(address):\(port)"
        }
        return name
    }
}

struct ConnectionMessage: Sendable {
    let type: ConnectionMessageType
    let payload: Data?

    func encoded() -> Data? {
        var dict: [String: Any] = ["type": type.rawValue]
        if let payload {
            dict["payload"] = payload.base64EncodedString()
        }
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    static func decode(from data: Data) -> ConnectionMessage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeRaw = json["type"] as? String,
              let type = ConnectionMessageType(rawValue: typeRaw) else {
            return nil
        }

        let payload: Data? = {
            if let base64 = json["payload"] as? String {
                return Data(base64Encoded: base64)
            }
            return nil
        }()

        return ConnectionMessage(type: type, payload: payload)
    }
}

enum ConnectionMessageType: String, Sendable {
    case authenticate
    case authResponse
    case startStream
    case stopStream
    case streamData
    case heartbeat
    case disconnect
    case settings
    case stats
}
