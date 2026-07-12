import Foundation
import AVFoundation
import Combine
import Network
import Observation
import UIKit

enum StreamManagerState: Equatable, Sendable {
    case idle
    case preparing
    case streaming
    case paused
    case error(String)
    
    static func == (lhs: StreamManagerState, rhs: StreamManagerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparing, .preparing), (.streaming, .streaming), (.paused, .paused):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

enum StreamManagerError: LocalizedError {
    case cameraNotAvailable
    case encoderNotAvailable
    case protocolNotSupported(StreamingProtocol)
    case alreadyStreaming
    case bitrateAdjustmentFailed
    case backgroundSessionFailed
    
    var errorDescription: String? {
        switch self {
        case .cameraNotAvailable:
            return "Camera is not available"
        case .encoderNotAvailable:
            return "Video encoder is not available"
        case .protocolNotSupported(let proto):
            return "Protocol not supported: \(proto.rawValue)"
        case .alreadyStreaming:
            return "Already streaming"
        case .bitrateAdjustmentFailed:
            return "Failed to adjust bitrate"
        case .backgroundSessionFailed:
            return "Failed to configure background streaming"
        }
    }
}

struct StreamingStatistics: Sendable {
    var framesSent: UInt64 = 0
    var framesDropped: UInt64 = 0
    var currentBitrate: Double = 0
    var peakBitrate: Double = 0
    var duration: TimeInterval = 0
    var averageFrameRate: Double = 0
    var totalBytesSent: UInt64 = 0
    var resolution: CGSize = .zero
    
    var dropRate: Double {
        let total = framesSent + framesDropped
        guard total > 0 else { return 0 }
        return Double(framesDropped) / Double(total) * 100.0
    }
    
    var formattedDuration: String {
        let h = Int(duration) / 3600
        let m = (Int(duration) % 3600) / 60
        let s = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
    
    var formattedBitrate: String {
        if currentBitrate >= 1_000_000 {
            return String(format: "%.2f Mbps", currentBitrate / 1_000_000)
        } else if currentBitrate >= 1_000 {
            return String(format: "%.0f Kbps", currentBitrate / 1_000)
        }
        return String(format: "%.0f bps", currentBitrate)
    }
}

final class StreamManager: ObservableObject {
    private(set) var state: StreamManagerState = .idle
    private(set) var statistics = StreamingStatistics()
    private(set) var activeProtocol: StreamingProtocol = .mjpeg
    private(set) var connectedClientCount: Int = 0
    private(set) var lastError: StreamManagerError?
    
    @Published var streamingState = StreamingState()
    let errorSubject = PassthroughSubject<AppError, Never>()
    @Published var streamEvents: [StreamEvent] = []
    
    let mjpegService = MJPEGStreamingService()
    let h264Service = H264StreamingService()
    let rtspService = RTSPService()
    
    var targetBitrate: Double = 2_000_000
    var maxBitrate: Double = 10_000_000
    var minBitrate: Double = 500_000
    var targetFrameRate: Int = 30
    
    private var statsStartTime: Date?
    private var statsTimer: Timer?
    private var bitrateTimer: Timer?
    private var durationTimer: Timer?
    private var frameTimestamps: [Date] = []
    private var cancellables = Set<AnyCancellable>()
    private var frameCountLastInterval: UInt64 = 0
    private var bytesCountLastInterval: UInt64 = 0
    
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var audioSessionConfigured = false
    
    private let encodingQueue = DispatchQueue(label: "com.rifatcam.streammanager.encode", qos: .userInitiated)
    private var h264SPS: Data?
    private var h264PPS: Data?
    private var hevcVPS: Data?
    
    init() {}
    
    deinit {
        stopStreaming()
    }
    
    // MARK: - Lifecycle
    
    func startStreaming(protocol streamingProtocol: StreamingProtocol, port: UInt16) throws {
        guard state == .idle else {
            throw StreamManagerError.alreadyStreaming
        }
        
        state = .preparing
        activeProtocol = streamingProtocol
        updateStreamingState()
        
        do {
            switch streamingProtocol {
            case .mjpeg:
                let svc = MJPEGStreamingService(port: port)
                try svc.start()
                
            case .h264:
                let svc = H264StreamingService(port: port, codec: .h264)
                try svc.start()
                
            case .hevc:
                let svc = H264StreamingService(port: port, codec: .hevc)
                try svc.start()
                
            case .rtsp:
                let svc = RTSPService(port: port)
                try svc.start()
            default:
                throw StreamManagerError.protocolNotSupported(streamingProtocol)
            }
            
            setupBackgroundStreaming()
            startStatisticsTracking()
            
            state = .streaming
            statsStartTime = Date()
            updateStreamingState()
            
        } catch {
            state = .error(error.localizedDescription)
            updateStreamingState()
            throw error
        }
    }
    
    func stopStreaming() {
        stopStatisticsTracking()
        
        switch activeProtocol {
        case .mjpeg:
            mjpegService.stop()
        case .h264, .hevc:
            h264Service.stop()
        case .rtsp:
            rtspService.stop()
        default:
            break
        }
        
        endBackgroundStreaming()
        
        state = .idle
        connectedClientCount = 0
        updateStreamingState()
        statistics = StreamingStatistics()
        h264SPS = nil
        h264PPS = nil
        hevcVPS = nil
    }
    
    func pause() {
        guard state == .streaming else { return }
        state = .paused
        updateStreamingState()
    }
    
    func resume() {
        guard state == .paused else { return }
        state = .streaming
        updateStreamingState()
    }
    
    func switchProtocol(to newProtocol: StreamingProtocol, port: UInt16) throws {
        let wasStreaming = state == .streaming || state == .paused
        
        if wasStreaming {
            stopStreaming()
        }
        
        activeProtocol = newProtocol
        
        if wasStreaming {
            try startStreaming(protocol: newProtocol, port: port)
        }
    }
    
    // MARK: - Frame Push (called from CameraService / VideoEncoder)
    
    func pushVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard state == .streaming else { return }
        
        statistics.framesSent += 1
        recordFrameTimestamp()
        
        switch activeProtocol {
        case .mjpeg:
            mjpegService.pushFrame(sampleBuffer)
            
        case .h264, .hevc, .rtsp:
            break
        default:
            break
        }
    }
    
    func pushEncodedH264Frame(_ data: Data, isKeyframe: Bool) {
        guard state == .streaming else { return }
        
        statistics.framesSent += 1
        statistics.totalBytesSent += UInt64(data.count)
        recordFrameTimestamp()
        
        let timestamp = UInt32(Date().timeIntervalSince1970 * 90000.0)
        
        switch activeProtocol {
        case .h264, .hevc:
            h264Service.pushFrame(data, isKeyframe: isKeyframe)
            
        case .rtsp:
            rtspService.pushH264Frame(data, timestamp: timestamp, isKeyframe: isKeyframe)
            
        case .mjpeg:
            break
        default:
            break
        }
    }
    
    func pushSPS(_ data: Data) {
        guard state == .streaming else { return }
        h264SPS = data
        
        switch activeProtocol {
        case .h264, .hevc:
            h264Service.pushSPS(data)
        case .rtsp:
            rtspService.pushSPS(data)
        case .mjpeg:
            break
        default:
            break
        }
    }
    
    func pushPPS(_ data: Data) {
        guard state == .streaming else { return }
        h264PPS = data
        
        switch activeProtocol {
        case .h264, .hevc:
            h264Service.pushPPS(data)
        case .rtsp:
            rtspService.pushPPS(data)
        case .mjpeg:
            break
        default:
            break
        }
    }
    
    func pushVPS(_ data: Data) {
        guard state == .streaming else { return }
        hevcVPS = data
        
        switch activeProtocol {
        case .h264, .hevc:
            h264Service.pushVPS(data)
        case .rtsp:
            rtspService.pushVPS(data)
        case .mjpeg:
            break
        default:
            break
        }
    }
    
    func pushJPEGData(_ data: Data) {
        guard state == .streaming else { return }
        
        statistics.framesSent += 1
        statistics.totalBytesSent += UInt64(data.count)
        recordFrameTimestamp()
        
        if activeProtocol == .mjpeg {
            mjpegService.pushJPEGData(data)
        }
    }
    
    // MARK: - Adaptive Bitrate
    
    func adjustBitrate(for dropRate: Double) {
        let adjustment: Double
        
        if dropRate > 5.0 {
            adjustment = 0.85
        } else if dropRate > 2.0 {
            adjustment = 0.95
        } else if dropRate < 0.5 && statistics.currentBitrate < targetBitrate {
            adjustment = 1.10
        } else {
            return
        }
        
        let newBitrate = statistics.currentBitrate * adjustment
        statistics.currentBitrate = min(max(newBitrate, minBitrate), maxBitrate)
        
        if statistics.currentBitrate > statistics.peakBitrate {
            statistics.peakBitrate = statistics.currentBitrate
        }
    }
    
    func setTargetBitrate(_ bitrate: Double) {
        targetBitrate = min(max(bitrate, minBitrate), maxBitrate)
    }
    
    // MARK: - Statistics Tracking
    
    private func startStatisticsTracking() {
        frameTimestamps.removeAll()
        frameCountLastInterval = 0
        bytesCountLastInterval = 0
        
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatistics()
        }
        
        bitrateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.computeBitrate()
        }
        
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateDuration()
        }
    }
    
    private func stopStatisticsTracking() {
        statsTimer?.invalidate()
        statsTimer = nil
        bitrateTimer?.invalidate()
        bitrateTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil
        frameTimestamps.removeAll()
    }
    
    private func updateStatistics() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-1.0)
        frameTimestamps = frameTimestamps.filter { $0 > cutoff }
        
        statistics.averageFrameRate = Double(frameTimestamps.count)
        
        updateClientCount()
    }
    
    private func computeBitrate() {
        let intervalBytes = statistics.totalBytesSent - bytesCountLastInterval
        
        statistics.currentBitrate = Double(intervalBytes) * 8.0 / 2.0
        
        if statistics.currentBitrate > statistics.peakBitrate {
            statistics.peakBitrate = statistics.currentBitrate
        }
        
        if statistics.framesDropped + statistics.framesSent > 0 {
            adjustBitrate(for: statistics.dropRate)
        }
        
        frameCountLastInterval = statistics.framesSent
        bytesCountLastInterval = statistics.totalBytesSent
    }
    
    private func updateDuration() {
        guard let start = statsStartTime else { return }
        statistics.duration = Date().timeIntervalSince(start)
    }
    
    private func recordFrameTimestamp() {
        frameTimestamps.append(Date())
    }
    
    private func updateClientCount() {
        switch activeProtocol {
        case .mjpeg:
            connectedClientCount = mjpegService.connectedClientCount
        case .h264, .hevc:
            connectedClientCount = h264Service.connectedClientCount
        case .rtsp:
            connectedClientCount = rtspService.connectedClientCount
        default:
            break
        }
    }
    
    // MARK: - Background Streaming
    
    private func setupBackgroundStreaming() {
        #if os(iOS)
        configureAudioSession()
        beginBackgroundTask()
        #endif
    }
    
    private func endBackgroundStreaming() {
        #if os(iOS)
        endBackgroundTask()
        deconfigureAudioSession()
        #endif
    }
    
    #if os(iOS)
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            lastError = .backgroundSessionFailed
        }
    }
    
    private func deconfigureAudioSession() {
        guard audioSessionConfigured else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionConfigured = false
        } catch {
            // Best effort cleanup
        }
    }
    
    private func beginBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            self.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
    #endif
    
    // MARK: - Public Helpers
    
    func setMJPEPassword(_ password: String?) {
        mjpegService.password = password
    }
    
    func requestKeyframe() {
        // Signal encoder to produce a keyframe on next opportunity
    }

    private func updateStreamingState() {
        var s = StreamingState()
        s.isStreaming = (state == .streaming || state == .paused)
        s.codec = activeProtocol == .hevc ? .hevc : .h264
        s.frameRate = targetFrameRate
        s.bitrate = Int(statistics.currentBitrate)
        s.framesEncoded = statistics.framesSent
        s.framesDropped = statistics.framesDropped
        s.startTime = statsStartTime
        streamingState = s
    }
}
