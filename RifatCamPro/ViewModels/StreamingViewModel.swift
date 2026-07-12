import Foundation
import Combine

@Observable
@MainActor
final class StreamingViewModel {

    // MARK: - Dependencies

    let cameraService: CameraService
    let networkService: NetworkService
    let streamManager: StreamManager
    let connectionManager: ConnectionManager
    let videoEncoder: VideoEncoder

    // MARK: - Streaming State

    var isStreaming = false
    var duration: TimeInterval = 0
    var formattedDuration: String = "00:00"
    var streamingCodec: StreamingCodec = .h264
    var streamingResolution: VideoResolution = .hd1080
    var streamingFrameRate: Int = 30
    var streamingBitrate: Int = 4_000_000

    // MARK: - Frames

    var framesEncoded: UInt64 = 0
    var framesDropped: UInt64 = 0
    var dropRate: Double = 0
    var formattedDropRate: String = "0.00%"
    var currentFPS: Double = 0

    // MARK: - Bitrate & Adaptive

    var currentBitrate: Int = 4_000_000
    var adaptiveBitrateEnabled: Bool = true
    var formattedCurrentBitrate: String = "4.0 Mbps"
    var bitrateAdjustmentIndicator: String = ""
    var bitrateTrend: BitrateTrend = .stable

    // MARK: - Protocol Display

    var protocolName: String = "H.264"
    var protocolIcon: String = "video"
    var transportProtocol: String = "TCP"

    // MARK: - Connection Info

    var clientAddress: String = "None"
    var connectionUptime: TimeInterval = 0
    var formattedUptime: String = "00:00:00"

    // MARK: - Network Stats

    var uploadSpeed: Double = 0
    var downloadSpeed: Double = 0
    var formattedUploadSpeed: String = "0 B/s"
    var formattedDownloadSpeed: String = "0 B/s"
    var totalBytesSent: UInt64 = 0
    var formattedTotalBytesSent: String = "0 B"
    var latency: TimeInterval = 0
    var formattedLatency: String = "0.0 ms"

    // MARK: - Stream Events

    var streamEvents: [StreamEvent] = []
    var maxEventLogSize: Int = 100

    // MARK: - UI State

    var showErrorAlert = false
    var errorTitle: String = ""
    var errorMessage: String = ""
    var showStopConfirmation = false

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var durationTimer: Timer?
    private var statsTimer: Timer?
    private var streamingStartTime: Date?

    // MARK: - Bitrate Trend

    enum BitrateTrend {
        case increasing
        case decreasing
        case stable

        var indicator: String {
            switch self {
            case .increasing: return "arrow.up.circle.fill"
            case .decreasing: return "arrow.down.circle.fill"
            case .stable: return "minus.circle.fill"
            }
        }

        var displayName: String {
            switch self {
            case .increasing: return "Increasing"
            case .decreasing: return "Decreasing"
            case .stable: return "Stable"
            }
        }
    }

    // MARK: - Init

    init(
        cameraService: CameraService,
        networkService: NetworkService,
        streamManager: StreamManager,
        connectionManager: ConnectionManager,
        videoEncoder: VideoEncoder
    ) {
        self.cameraService = cameraService
        self.networkService = networkService
        self.streamManager = streamManager
        self.connectionManager = connectionManager
        self.videoEncoder = videoEncoder

        bindStreamManager()
        bindNetworkService()
        bindVideoEncoder()
        bindCameraService()
        bindConnectionManager()
    }

    deinit {
    }

    // MARK: - Start Streaming

    func loadStreamingConfiguration() {
        let state = streamManager.streamingState
        isStreaming = state.isStreaming
        streamingCodec = state.codec
        streamingResolution = state.resolution
        streamingFrameRate = state.frameRate
        streamingBitrate = state.bitrate
        framesEncoded = state.framesEncoded
        framesDropped = state.framesDropped
        dropRate = state.dropRate
        adaptiveBitrateEnabled = state.adaptiveBitrateEnabled
        currentBitrate = videoEncoder.currentBitrate

        protocolName = state.codec.displayName
        transportProtocol = "TCP"

        switch state.codec {
        case .h264: protocolIcon = "video"
        case .hevc: protocolIcon = "video.badge.ellipsis"
        case .mjpeg: protocolIcon = "photo"
        case .webRTC: protocolIcon = "antenna.radiowaves.left.and.right"
        case .rtsp: protocolIcon = "network"
        case .rtmp: protocolIcon = "arrow.up.arrow.down"
        }
    }

    func beginStreamingSession() {
        streamingStartTime = Date()
        startDurationTimer()
        startStatsTimer()
    }

    // MARK: - Stop Streaming

    func stopStreaming() {
        streamManager.stopStreaming()
        videoEncoder.stopSession()
        networkService.stop()
        isStreaming = false
        stopTimers()
        addEvent(type: .stopped, message: "Streaming stopped by user")
    }

    func confirmStop() {
        showStopConfirmation = true
    }

    func cancelStopConfirmation() {
        showStopConfirmation = false
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let startTime = self.streamingStartTime {
                    self.duration = Date().timeIntervalSince(startTime)
                    self.formattedDuration = Self.formatDuration(self.duration)
                }
            }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func stopTimers() {
        durationTimer?.invalidate()
        durationTimer = nil
        statsTimer?.invalidate()
        statsTimer = nil
    }

    // MARK: - Stats Timer

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshStats()
            }
        }
        RunLoop.main.add(statsTimer!, forMode: .common)
    }

    private func refreshStats() {
        let state = streamManager.streamingState
        framesEncoded = state.framesEncoded
        framesDropped = state.framesDropped
        dropRate = state.dropRate
        formattedDropRate = String(format: "%.2f%%", dropRate)

        let stats = networkService.stats
        uploadSpeed = stats.uploadSpeed
        downloadSpeed = stats.downloadSpeed
        formattedUploadSpeed = Self.formatSpeed(stats.uploadSpeed)
        formattedDownloadSpeed = Self.formatSpeed(stats.downloadSpeed)
        totalBytesSent = stats.bytesSent
        formattedTotalBytesSent = ByteCountFormatter.string(fromByteCount: Int64(stats.bytesSent), countStyle: .file)
        latency = stats.latency
        formattedLatency = String(format: "%.1f ms", stats.latency * 1000)
        connectionUptime = stats.connectionUptime
        formattedUptime = Self.formatDuration(stats.connectionUptime)

        let encoderBitrate = videoEncoder.currentBitrate
        currentBitrate = encoderBitrate
        formattedCurrentBitrate = Self.formatBitrate(Double(encoderBitrate))

        updateBitrateTrend()

        clientAddress = networkService.connectedClientAddress ?? "None"
        currentFPS = cameraService.currentFPS
    }

    private func updateBitrateTrend() {
        let previousTrend = bitrateTrend
        let targetBitrate = Double(streamingBitrate)
        let actual = Double(currentBitrate)

        if actual > targetBitrate * 1.1 {
            bitrateTrend = .increasing
            bitrateAdjustmentIndicator = "↑ \(Self.formatBitrate(actual))"
        } else if actual < targetBitrate * 0.9 {
            bitrateTrend = .decreasing
            bitrateAdjustmentIndicator = "↓ \(Self.formatBitrate(actual))"
        } else {
            bitrateTrend = .stable
            bitrateAdjustmentIndicator = "— \(Self.formatBitrate(actual))"
        }

        if previousTrend != bitrateTrend {
            let message: String
            switch bitrateTrend {
            case .increasing:
                message = "Bitrate increased to \(Self.formatBitrate(actual))"
            case .decreasing:
                message = "Bitrate decreased to \(Self.formatBitrate(actual))"
            case .stable:
                message = "Bitrate stabilized at \(Self.formatBitrate(actual))"
            }
            addEvent(type: .bitrateAdjusted, message: message)
        }
    }

    // MARK: - Event Log

    func addEvent(type: StreamEventType, message: String) {
        let event = StreamEvent(type: type, message: message)
        streamEvents.insert(event, at: 0)
        if streamEvents.count > maxEventLogSize {
            streamEvents = Array(streamEvents.prefix(maxEventLogSize))
        }
    }

    func clearEvents() {
        streamEvents.removeAll()
    }

    // MARK: - Error Handling

    func showError(_ error: AppError) {
        errorTitle = error.title
        errorMessage = error.message
        showErrorAlert = true
    }

    func dismissError() {
        showErrorAlert = false
        errorTitle = ""
        errorMessage = ""
    }

    // MARK: - Combine Bindings

    private func bindStreamManager() {
        streamManager.$streamingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }

                let wasStreaming = self.isStreaming
                self.isStreaming = state.isStreaming
                self.streamingCodec = state.codec
                self.streamingResolution = state.resolution
                self.streamingFrameRate = state.frameRate
                self.streamingBitrate = state.bitrate
                self.framesEncoded = state.framesEncoded
                self.framesDropped = state.framesDropped
                self.dropRate = state.dropRate
                self.adaptiveBitrateEnabled = state.adaptiveBitrateEnabled

                self.protocolName = state.codec.displayName

                if state.isStreaming && !wasStreaming {
                    self.beginStreamingSession()
                    self.addEvent(type: .started, message: "Streaming started - \(state.codec.displayName) \(state.resolution.rawValue)")
                } else if !state.isStreaming && wasStreaming {
                    self.stopTimers()
                    self.streamingStartTime = nil
                    self.duration = 0
                    self.formattedDuration = "00:00"
                }
            }
            .store(in: &cancellables)

        streamManager.errorSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.showError(error)
                self?.addEvent(type: .error, message: error.message)
            }
            .store(in: &cancellables)

        streamManager.$streamEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events in
                guard let self else { return }
                if events.count > self.streamEvents.count {
                    let newEvents = Array(events.suffix(from: self.streamEvents.count))
                    for event in newEvents {
                        self.streamEvents.insert(event, at: 0)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func bindNetworkService() {
        networkService.connectionStateChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .connected:
                    let addr = self.networkService.connectedClientAddress ?? "Unknown"
                    self.clientAddress = addr
                    self.addEvent(type: .clientConnected, message: "Client connected: \(addr)")
                case .disconnected:
                    if self.isStreaming {
                        self.addEvent(type: .clientDisconnected, message: "Client disconnected")
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        networkService.errorSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.addEvent(type: .error, message: error.localizedDescription)
            }
            .store(in: &cancellables)
    }

    private func bindVideoEncoder() {
        videoEncoder.$currentBitrate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bitrate in
                self?.currentBitrate = bitrate
                self?.formattedCurrentBitrate = Self.formatBitrate(Double(bitrate))
            }
            .store(in: &cancellables)

        videoEncoder.$isEncoding
            .receive(on: DispatchQueue.main)
            .sink { [weak self] encoding in
                if encoding {
                    self?.addEvent(type: .started, message: "Video encoder active")
                }
            }
            .store(in: &cancellables)
    }

    private func bindCameraService() {
        cameraService.$currentFPS
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fps in
                self?.currentFPS = fps
            }
            .store(in: &cancellables)

        cameraService.errorSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.addEvent(type: .error, message: error.message)
            }
            .store(in: &cancellables)
    }

    private func bindConnectionManager() {
        connectionManager.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .connected(let addr):
                    self.clientAddress = addr
                case .disconnected:
                    self.clientAddress = "None"
                default:
                    break
                }
            }
            .store(in: &cancellables)

        connectionManager.errorOccurred
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.showError(.networkError(error.message))
            }
            .store(in: &cancellables)
    }

    // MARK: - Formatting Helpers

    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1_000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    static func formatBitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
        } else if bitsPerSecond >= 1_000 {
            return String(format: "%.0f Kbps", bitsPerSecond / 1_000)
        }
        return String(format: "%.0f bps", bitsPerSecond)
    }
}
