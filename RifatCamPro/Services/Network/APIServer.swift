import Foundation
import Network
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - API Configuration

struct APIConfiguration: Sendable {
    var port: UInt16
    var enableAuthentication: Bool
    var apiToken: String
    var enableCORS: Bool

    static let `default` = APIConfiguration(
        port: 4748,
        enableAuthentication: false,
        apiToken: "rifatcam-pro-secret",
        enableCORS: true
    )
}

// MARK: - Streaming Stats

struct StreamingStats: Codable, Sendable {
    var bitrate: Double
    var fps: Double
    var framesDropped: Int
    var totalFrames: Int
    var duration: TimeInterval
    var codec: String
    var resolution: String
    var isStreaming: Bool
    var connectionCount: Int

    static let empty = StreamingStats(
        bitrate: 0, fps: 0, framesDropped: 0, totalFrames: 0,
        duration: 0, codec: "h264", resolution: "1080p",
        isStreaming: false, connectionCount: 0
    )
}

// MARK: - Streaming Controller Protocol

@MainActor
protocol StreamingControlling: AnyObject {
    func startStreaming(params: [String: Any]) async -> Bool
    func stopStreaming() async -> Bool
}

// MARK: - Camera Controller Protocol

@MainActor
protocol CameraControlling: AnyObject {
    func switchCamera(to position: String) async -> Bool
    func setTorch(enabled: Bool) async -> Bool
    func setZoom(factor: Double) async -> Bool
}

// MARK: - API Server

@Observable
final class APIServer {

    var isRunning: Bool = false
    var port: UInt16 = 4748
    var connectedClients: Int = 0
    var lastError: String?
    var requestCount: Int = 0

    var streamingStatsProvider: @MainActor @Sendable () -> StreamingStats = { .empty }
    weak var streamingController: (any StreamingControlling)?
    weak var cameraController: (any CameraControlling)?
    var settingsProvider: @MainActor @Sendable () -> [String: Any] = { [:] }
    var settingsUpdater: @MainActor @Sendable ([String: Any]) -> Void = { _ in }
    var devicesProvider: @MainActor @Sendable () -> [[String: Any]] = { [] }

    private var listener: NWListener?
    private let router = HTTPRouter()
    private let config: APIConfiguration
    private let startTime = Date()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let connectionsQueue = DispatchQueue(label: "com.rifatcam.api.connections", attributes: .concurrent)
    private var accessTokens: Set<String> = []

    init(config: APIConfiguration = .default) {
        self.config = config
        self.port = config.port
        registerRoutes()
    }

    deinit {
        let listener = self.listener
        listener?.cancel()
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
                    self.port = self.config.port
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
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        connectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            for (_, conn) in self.connections {
                conn.cancel()
            }
            self.connections.removeAll()
        }
        Task { @MainActor in
            self.connectedClients = 0
        }
    }

    func generateAccessToken() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        accessTokens.insert(token)
        return token
    }

    func revokeAccessToken(_ token: String) {
        accessTokens.remove(token)
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connectionsQueue.async(flags: .barrier) { [weak self] in
            self?.connections[id] = connection
        }
        Task { @MainActor [weak self] in
            self?.connectedClients = self?.connections.count ?? 0
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                break
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        receiveData(on: connection)
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error = error {
                print("[APIServer] Receive error: \(error)")
                self.removeConnection(connection)
                return
            }

            if isComplete && (data == nil || data?.isEmpty == true) {
                self.removeConnection(connection)
                return
            }

            guard let data = data, !data.isEmpty else {
                self.receiveData(on: connection)
                return
            }

            Task {
                await self.processRawRequest(data, on: connection)
                self.receiveData(on: connection)
            }
        }
    }

    private func processRawRequest(_ data: Data, on connection: NWConnection) async {
        guard let parsed = URLParser.parseHTTP(from: data) else {
            let response = HTTPResponse(error: "Malformed HTTP request", statusCode: .badRequest)
            await sendHTTPResponse(response, on: connection)
            return
        }

        let queryParams = URLParser.parseQueryParameters(from: parsed.path)

        var request = HTTPRequest(
            method: parsed.method,
            path: URLParser.parsePath(from: parsed.path),
            headers: parsed.headers,
            body: parsed.body,
            queryParameters: queryParams
        )

        await MainActor.run { self.requestCount += 1 }

        if config.enableAuthentication {
            let authorized = await checkAuthorization(request)
            if !authorized {
                await sendHTTPResponse(HTTPResponse(error: "Unauthorized", statusCode: .unauthorized), on: connection)
                return
            }
        }

        let response = await router.route(request)
        await sendHTTPResponse(response, on: connection)
    }

    @MainActor
    private func checkAuthorization(_ request: HTTPRequest) -> Bool {
        guard let authHeader = request.headers["authorization"] else { return false }
        if authHeader.hasPrefix("Bearer ") {
            let token = String(authHeader.dropFirst(7))
            return accessTokens.contains(token) || token == config.apiToken
        }
        if authHeader.hasPrefix("Basic ") {
            let encoded = String(authHeader.dropFirst(6))
            guard let decodedData = Data(base64Encoded: encoded),
                  let decoded = String(data: decodedData, encoding: .utf8) else { return false }
            let parts = decoded.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                return String(parts[1]) == config.apiToken
            }
        }
        return false
    }

    private func sendHTTPResponse(_ response: HTTPResponse, on connection: NWConnection) {
        var headerString = "HTTP/1.1 \(response.statusCode.rawValue) \(response.statusCode.description)\r\n"

        var allHeaders = response.headers
        if config.enableCORS {
            allHeaders["Access-Control-Allow-Origin"] = "*"
            allHeaders["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS, PATCH"
            allHeaders["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-Requested-With"
            allHeaders["Access-Control-Max-Age"] = "86400"
            allHeaders["Access-Control-Expose-Headers"] = "X-Request-Id"
        }

        if let body = response.body, !body.isEmpty {
            allHeaders["Content-Length"] = "\(body.count)"
        } else {
            allHeaders["Content-Length"] = "0"
        }

        if allHeaders["Content-Type"] == nil {
            allHeaders["Content-Type"] = "application/json; charset=utf-8"
        }

        allHeaders["Connection"] = "close"
        allHeaders["X-Request-Id"] = UUID().uuidString

        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            headerString += "\(key): \(value)\r\n"
        }
        headerString += "\r\n"

        var fullResponse = Data(headerString.utf8)
        if let body = response.body, !body.isEmpty {
            fullResponse.append(body)
        }

        connection.send(content: fullResponse, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("[APIServer] Send error: \(error)")
            }
            self?.removeConnection(connection)
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connectionsQueue.async(flags: .barrier) { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        connection.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectionsQueue.sync {
                self.connectedClients = self.connections.count
            }
        }
    }

    // MARK: - Route Registration

    private func registerRoutes() {
        router.get("/api/health") { [weak self] _ in
            await self?.handleHealth() ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.get("/api/status") { [weak self] _ in
            await self?.handleStatus() ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.get("/api/streaming") { [weak self] _ in
            await self?.handleStreamingStats() ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.post("/api/camera/switch") { [weak self] request in
            await self?.handleCameraSwitch(request) ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.post("/api/camera/torch") { [weak self] request in
            await self?.handleTorchToggle(request) ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.post("/api/camera/zoom") { [weak self] request in
            await self?.handleZoom(request) ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.post("/api/streaming/start") { [weak self] request in
            await self?.handleStreamingStart(request) ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.post("/api/streaming/stop") { [weak self] _ in
            await self?.handleStreamingStop() ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.get("/api/settings") { [weak self] _ in
            await self?.handleGetSettings() ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.post("/api/settings") { [weak self] request in
            await self?.handleUpdateSettings(request) ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.get("/api/devices") { [weak self] _ in
            await self?.handleDevices() ?? HTTPResponse(error: "Server unavailable", statusCode: .serviceUnavailable)
        }

        router.options("/api/*") { [weak self] _ in
            self?.handleCORS() ?? HTTPResponse(statusCode: .noContent)
        }
    }

    // MARK: - GET /api/health

    private func handleHealth() async -> HTTPResponse {
        let uptime = Date().timeIntervalSince(startTime)
        let json: [String: Any] = [
            "status": "ok",
            "uptime": String(format: "%.1f", uptime),
            "uptimeSeconds": uptime,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "serverRunning": isRunning,
            "requestCount": requestCount
        ]
        return HTTPResponse(json: json, statusCode: .ok)
    }

    // MARK: - GET /api/status

    private func handleStatus() async -> HTTPResponse {
        let stats = await MainActor.run { self.streamingStatsProvider() }
        let uptime = Date().timeIntervalSince(startTime)
        let batteryInfo = getBatteryInfo()

        let json: [String: Any] = [
            "device": [
                "name": getDeviceName(),
                "model": getDeviceModel(),
                "systemVersion": getSystemVersion(),
                "deviceId": getDeviceId()
            ],
            "battery": batteryInfo,
            "streaming": [
                "active": stats.isStreaming,
                "codec": stats.codec,
                "resolution": stats.resolution,
                "bitrate": stats.bitrate,
                "fps": stats.fps
            ],
            "server": [
                "apiPort": port,
                "uptime": String(format: "%.1f", uptime),
                "totalRequests": requestCount,
                "connectedClients": connectedClients
            ]
        ]
        return HTTPResponse(json: json, statusCode: .ok)
    }

    // MARK: - GET /api/streaming

    private func handleStreamingStats() async -> HTTPResponse {
        let stats = await MainActor.run { self.streamingStatsProvider() }

        let json: [String: Any] = [
            "isStreaming": stats.isStreaming,
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
            "connectionCount": stats.connectionCount
        ]
        return HTTPResponse(json: json, statusCode: .ok)
    }

    // MARK: - POST /api/camera/switch

    private func handleCameraSwitch(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.jsonBodyDictionary() else {
            return HTTPResponse(error: "Request body must be valid JSON", statusCode: .badRequest)
        }

        let position = (body["position"] as? String ?? "back").lowercased()
        guard ["front", "back", "ultra_wide", "telephoto"].contains(position) else {
            return HTTPResponse(error: "Invalid camera position. Valid: front, back, ultra_wide, telephoto", statusCode: .badRequest)
        }

        let controller = await MainActor.run { self.cameraController }
        if let controller {
            let success = await controller.switchCamera(to: position)
            if success {
                return HTTPResponse(json: [
                    "success": true,
                    "camera": position,
                    "message": "Camera switched to \(position)"
                ] as [String: Any], statusCode: .ok)
            } else {
                return HTTPResponse(error: "Failed to switch camera to \(position)", statusCode: .internalServerError)
            }
        }

        return HTTPResponse(json: [
            "success": true,
            "camera": position,
            "message": "Camera switch request accepted (no controller bound)"
        ] as [String: Any], statusCode: .ok)
    }

    // MARK: - POST /api/camera/torch

    private func handleTorchToggle(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.jsonBodyDictionary() else {
            return HTTPResponse(error: "Request body must be valid JSON", statusCode: .badRequest)
        }

        guard let enabled = body["enabled"] as? Bool else {
            return HTTPResponse(error: "Missing boolean field 'enabled'", statusCode: .badRequest)
        }

        let controller = await MainActor.run { self.cameraController }
        if let controller {
            let success = await controller.setTorch(enabled: enabled)
            return HTTPResponse(json: [
                "success": success,
                "torch": enabled
            ] as [String: Any], statusCode: .ok)
        }

        return HTTPResponse(json: [
            "success": true,
            "torch": enabled,
            "message": "Torch request accepted (no controller bound)"
        ] as [String: Any], statusCode: .ok)
    }

    // MARK: - POST /api/camera/zoom

    private func handleZoom(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.jsonBodyDictionary() else {
            return HTTPResponse(error: "Request body must be valid JSON", statusCode: .badRequest)
        }

        guard let factor = body["factor"] as? Double else {
            return HTTPResponse(error: "Missing numeric field 'factor'", statusCode: .badRequest)
        }

        let clamped = max(1.0, min(factor, 10.0))

        let controller = await MainActor.run { self.cameraController }
        if let controller {
            let success = await controller.setZoom(factor: clamped)
            return HTTPResponse(json: [
                "success": success,
                "factor": clamped
            ] as [String: Any], statusCode: .ok)
        }

        return HTTPResponse(json: [
            "success": true,
            "factor": clamped,
            "message": "Zoom request accepted (no controller bound)"
        ] as [String: Any], statusCode: .ok)
    }

    // MARK: - POST /api/streaming/start

    private func handleStreamingStart(_ request: HTTPRequest) async -> HTTPResponse {
        var params: [String: Any] = [:]
        if let body = request.jsonBodyDictionary() {
            params = body
        }

        let codec = (params["codec"] as? String ?? "h264").lowercased()
        let resolution = (params["resolution"] as? String ?? "1080p").lowercased()
        let streamPort = params["port"] as? UInt16 ?? 4747

        guard ["h264", "h265", "hevc", "vp8", "vp9", "av1"].contains(codec) else {
            return HTTPResponse(error: "Unsupported codec '\(codec)'. Valid: h264, h265, vp8, vp9, av1", statusCode: .badRequest)
        }

        let controller = await MainActor.run { self.streamingController }
        if let controller {
            let params: [String: Any] = [
                "codec": codec,
                "resolution": resolution,
                "port": streamPort
            ]
            let success = await controller.startStreaming(params: params)
            if success {
                return HTTPResponse(json: [
                    "success": true,
                    "streaming": true,
                    "codec": codec,
                    "resolution": resolution,
                    "port": streamPort
                ] as [String: Any], statusCode: .ok)
            } else {
                return HTTPResponse(error: "Failed to start streaming", statusCode: .internalServerError)
            }
        }

        return HTTPResponse(json: [
            "success": true,
            "streaming": true,
            "codec": codec,
            "resolution": resolution,
            "port": streamPort,
            "message": "Streaming start request accepted (no controller bound)"
        ] as [String: Any], statusCode: .ok)
    }

    // MARK: - POST /api/streaming/stop

    private func handleStreamingStop() async -> HTTPResponse {
        let controller = await MainActor.run { self.streamingController }
        if let controller {
            let success = await controller.stopStreaming()
            return HTTPResponse(json: [
                "success": success,
                "streaming": false
            ] as [String: Any], statusCode: .ok)
        }

        return HTTPResponse(json: [
            "success": true,
            "streaming": false,
            "message": "Streaming stop request accepted (no controller bound)"
        ] as [String: Any], statusCode: .ok)
    }

    // MARK: - GET /api/settings

    private func handleGetSettings() async -> HTTPResponse {
        let settings = await MainActor.run { self.settingsProvider() }

        let merged: [String: Any] = [
            "resolution": settings["resolution"] as? String ?? "1080p",
            "codec": settings["codec"] as? String ?? "h264",
            "bitrate": settings["bitrate"] as? Int ?? 8000,
            "fps": settings["fps"] as? Int ?? 30,
            "autoExposure": settings["autoExposure"] as? Bool ?? true,
            "autoWhiteBalance": settings["autoWhiteBalance"] as? Bool ?? true,
            "audioEnabled": settings["audioEnabled"] as? Bool ?? true,
            "videoStabilization": settings["videoStabilization"] as? Bool ?? true,
            " mirroring": settings[" mirroring"] as? Bool ?? false,
            "overlay": settings["overlay"] as? Bool ?? false,
            "overlayText": settings["overlayText"] as? String ?? "",
            "orientation": settings["orientation"] as? String ?? "auto",
            "zoom": settings["zoom"] as? Double ?? 1.0,
            "sessionPreset": settings["sessionPreset"] as? String ?? "high"
        ]

        return HTTPResponse(json: merged, statusCode: .ok)
    }

    // MARK: - POST /api/settings

    private func handleUpdateSettings(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.jsonBodyDictionary() else {
            return HTTPResponse(error: "Request body must be valid JSON", statusCode: .badRequest)
        }

        guard !body.isEmpty else {
            return HTTPResponse(error: "Request body is empty", statusCode: .badRequest)
        }

        let allowedKeys: Set<String> = [
            "resolution", "codec", "bitrate", "fps", "autoExposure",
            "autoWhiteBalance", "audioEnabled", "videoStabilization",
            " mirroring", "overlay", "overlayText", "orientation",
            "zoom", "sessionPreset"
        ]

        var sanitized: [String: Any] = [:]
        for (key, value) in body {
            if allowedKeys.contains(key) {
                sanitized[key] = value
            }
        }

        guard !sanitized.isEmpty else {
            return HTTPResponse(error: "No valid settings provided", statusCode: .badRequest)
        }

        await MainActor.run { self.settingsUpdater(sanitized) }

        return HTTPResponse(json: [
            "success": true,
            "updated": Array(sanitized.keys).sorted()
        ] as [String: Any], statusCode: .ok)
    }

    // MARK: - GET /api/devices

    private func handleDevices() async -> HTTPResponse {
        let devices = await MainActor.run { self.devicesProvider() }
        return HTTPResponse(json: ["devices": devices], statusCode: .ok)
    }

    // MARK: - OPTIONS (CORS)

    private func handleCORS() -> HTTPResponse {
        var response = HTTPResponse(statusCode: .noContent)
        response.headers["Access-Control-Allow-Origin"] = "*"
        response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS, PATCH"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-Requested-With"
        response.headers["Access-Control-Max-Age"] = "86400"
        return response
    }

    // MARK: - Device Helpers

    private func getDeviceName() -> String {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    private func getDeviceModel() -> String {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.model
        #else
        return "Simulator"
        #endif
    }

    private func getSystemVersion() -> String {
        #if canImport(UIKit) && !os(watchOS)
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private func getDeviceId() -> String {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }

    private func getBatteryInfo() -> [String: Any] {
        #if canImport(UIKit) && !os(watchOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let state: String
        switch UIDevice.current.batteryState {
        case .unknown: state = "unknown"
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        @unknown default: state = "unknown"
        }
        return [
            "level": level >= 0 ? Double(level) : -1.0,
            "state": state,
            "isCharging": UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        ]
        #else
        return ["level": -1.0, "state": "unknown", "isCharging": false]
        #endif
    }
}
