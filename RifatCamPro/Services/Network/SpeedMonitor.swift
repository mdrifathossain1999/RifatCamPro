import Foundation
import Combine

@Observable
final class SpeedMonitor: Sendable {

    // MARK: - Public State

    private(set) var currentUploadSpeed: Double = 0
    private(set) var currentDownloadSpeed: Double = 0
    private(set) var totalBytesSent: UInt64 = 0
    private(set) var totalBytesReceived: UInt64 = 0

    // MARK: - Configuration

    private let windowDuration: TimeInterval
    private let updateInterval: TimeInterval

    // MARK: - Private Storage

    private let lock = NSLock()
    private var uploadSamples: [(timestamp: TimeInterval, bytes: UInt64)] = []
    private var downloadSamples: [(timestamp: TimeInterval, bytes: UInt64)] = []
    private var cumulativeUploadBytes: UInt64 = 0
    private var cumulativeDownloadBytes: UInt64 = 0
    private var timer: Timer?

    // MARK: - Init

    init(windowDuration: TimeInterval = 5.0, updateInterval: TimeInterval = 0.5) {
        self.windowDuration = windowDuration
        self.updateInterval = updateInterval
        startTimer()
    }

    deinit {
        stopTimer()
    }

    // MARK: - Public API

    func recordUpload(bytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        cumulativeUploadBytes += bytes
        let now = ProcessInfo.processInfo.systemUptime
        uploadSamples.append((timestamp: now, bytes: bytes))
        pruneSamples(&uploadSamples, now: now)
    }

    func recordDownload(bytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        cumulativeDownloadBytes += bytes
        let now = ProcessInfo.processInfo.systemUptime
        downloadSamples.append((timestamp: now, bytes: bytes))
        pruneSamples(&downloadSamples, now: now)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        uploadSamples.removeAll()
        downloadSamples.removeAll()
        cumulativeUploadBytes = 0
        cumulativeDownloadBytes = 0
        currentUploadSpeed = 0
        currentDownloadSpeed = 0
        totalBytesSent = 0
        totalBytesReceived = 0
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.recalculate()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Recalculation

    private func recalculate() {
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        pruneSamples(&uploadSamples, now: now)
        pruneSamples(&downloadSamples, now: now)

        currentUploadSpeed = computeSpeed(from: uploadSamples, now: now)
        currentDownloadSpeed = computeSpeed(from: downloadSamples, now: now)
        totalBytesSent = cumulativeUploadBytes
        totalBytesReceived = cumulativeDownloadBytes
    }

    // MARK: - Speed Computation

    private func computeSpeed(from samples: [(timestamp: TimeInterval, bytes: UInt64)], now: TimeInterval) -> Double {
        guard !samples.isEmpty else { return 0 }

        let windowStart = now - windowDuration
        let relevantSamples = samples.filter { $0.timestamp >= windowStart }

        guard let first = relevantSamples.first else { return 0 }

        let elapsed = now - first.timestamp
        guard elapsed > 0 else { return 0 }

        let totalBytes = relevantSamples.reduce(0) { $0 + $1.bytes }
        return Double(totalBytes) / elapsed
    }

    // MARK: - Pruning

    private func pruneSamples(_ samples: inout [(timestamp: TimeInterval, bytes: UInt64)], now: TimeInterval) {
        let cutoff = now - windowDuration
        samples.removeAll { $0.timestamp < cutoff }
    }
}
