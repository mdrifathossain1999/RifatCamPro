import Foundation
import Combine
import Observation
import UIKit

final class BatteryManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var batteryLevel: Float = 1.0
    private(set) var batteryState: BatteryMonitorState = .unknown
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    @Published private(set) var thermalState: ThermalState = .nominal
    private(set) var isLowPowerMode = false
    private(set) var batteryWarning: BatteryWarning?
    private(set) var thermalWarning: ThermalWarning?
    private(set) var recommendedQuality: StreamQuality = .balanced
    private(set) var recommendedBitrateMultiplier: Double = 1.0

    // MARK: - Thresholds

    var lowBatteryThreshold: Float = 0.20
    var criticalBatteryThreshold: Float = 0.10
    var thermalThrottleThreshold: ThermalState = .serious
    var thermalCriticalThreshold: ThermalState = .critical

    // MARK: - Combine

    let batteryLevelChanged = PassthroughSubject<Float, Never>()
    let batteryStateChanged = PassthroughSubject<BatteryMonitorState, Never>()
    let chargingStateChanged = PassthroughSubject<Bool, Never>()
    let thermalStateChanged = PassthroughSubject<ThermalState, Never>()
    let lowPowerModeChanged = PassthroughSubject<Bool, Never>()
    let batteryWarningPublished = PassthroughSubject<BatteryWarning, Never>()
    let thermalWarningPublished = PassthroughSubject<ThermalWarning, Never>()
    let qualityRecommendationChanged = PassthroughSubject<QualityRecommendation, Never>()
    let shouldReduceQuality = PassthroughSubject<QualityRecommendation, Never>()

    // MARK: - Private

    private let device = UIDevice.current
    private var batteryTimer: Timer?
    private var thermalTimer: Timer?
    private var monitorInterval: TimeInterval = 5.0
    private var cancellables = Set<AnyCancellable>()
    private var lastBatteryWarningLevel: Float = 1.0
    private var lastThermalWarningState: ThermalState = .nominal

    // MARK: - Initialization

    init() {
        setupBatteryMonitoring()
        setupThermalMonitoring()
        setupLowPowerModeObservation()
        updateBatteryState()
        updateThermalState()
    }

    deinit {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Battery Monitoring Setup

    private func setupBatteryMonitoring() {
        device.isBatteryMonitoringEnabled = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryLevelDidChange),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: device
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateDidChange),
            name: UIDevice.batteryStateDidChangeNotification,
            object: device
        )

        batteryTimer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { [weak self] _ in
            self?.updateBatteryState()
        }
        if let timer = batteryTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func setupThermalMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateDidChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )

        thermalTimer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { [weak self] _ in
            self?.updateThermalState()
        }
        if let timer = thermalTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func setupLowPowerModeObservation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowPowerModeDidChange),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )

        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: - Monitoring Control

    func startMonitoring(interval: TimeInterval = 5.0) {
        monitorInterval = interval
        stopMonitoring()

        device.isBatteryMonitoringEnabled = true

        batteryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateBatteryState()
        }
        if let timer = batteryTimer {
            RunLoop.current.add(timer, forMode: .common)
        }

        thermalTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateThermalState()
        }
        if let timer = thermalTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    func stopMonitoring() {
        batteryTimer?.invalidate()
        batteryTimer = nil
        thermalTimer?.invalidate()
        thermalTimer = nil
    }

    // MARK: - Battery State Update

    @objc private func batteryLevelDidChange() {
        updateBatteryState()
    }

    @objc private func batteryStateDidChange() {
        updateBatteryState()
    }

    private func updateBatteryState() {
        let level = device.batteryLevel
        if level >= 0 {
            batteryLevel = max(0, min(level, 1.0))
        }

        let newState: BatteryMonitorState = {
            switch device.batteryState {
            case .unknown: return .unknown
            case .unplugged: return .unplugged
            case .charging: return .charging
            case .full: return .full
            @unknown default: return .unknown
            }
        }()

        batteryState = newState
        isCharging = (newState == .charging)
        isPluggedIn = (newState == .charging || newState == .full)

        batteryLevelChanged.send(batteryLevel)
        batteryStateChanged.send(newState)
        chargingStateChanged.send(isCharging)

        evaluateBatteryWarnings()
        evaluateQualityRecommendation()
    }

    // MARK: - Thermal State Update

    @objc private func thermalStateDidChange() {
        updateThermalState()
    }

    private func updateThermalState() {
        let mapped: ThermalState = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return .nominal
            case .fair: return .fair
            case .serious: return .serious
            case .critical: return .critical
            @unknown default: return .nominal
            }
        }()

        thermalState = mapped
        thermalStateChanged.send(mapped)

        evaluateThermalWarnings()
        evaluateQualityRecommendation()
    }

    // MARK: - Low Power Mode

    @objc private func lowPowerModeDidChange() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        lowPowerModeChanged.send(isLowPowerMode)
        evaluateQualityRecommendation()
    }

    // MARK: - Warning Evaluation

    private func evaluateBatteryWarnings() {
        guard !isCharging else {
            batteryWarning = nil
            return
        }

        if batteryLevel <= criticalBatteryThreshold {
            if lastBatteryWarningLevel > criticalBatteryThreshold {
                let warning = BatteryWarning(
                    level: .critical,
                    batteryLevel: batteryLevel,
                    message: "Battery critically low (\(formattedBatteryLevel)). Streaming quality will be reduced."
                )
                batteryWarning = warning
                batteryWarningPublished.send(warning)
            }
        } else if batteryLevel <= lowBatteryThreshold {
            if lastBatteryWarningLevel > lowBatteryThreshold {
                let warning = BatteryWarning(
                    level: .low,
                    batteryLevel: batteryLevel,
                    message: "Battery low (\(formattedBatteryLevel)). Consider reducing streaming quality."
                )
                batteryWarning = warning
                batteryWarningPublished.send(warning)
            }
        } else {
            batteryWarning = nil
        }

        lastBatteryWarningLevel = batteryLevel
    }

    private func evaluateThermalWarnings() {
        if thermalState == .critical {
            if lastThermalWarningState != .critical {
                let warning = ThermalWarning(
                    level: .critical,
                    thermalState: thermalState,
                    message: "Device is overheating. Streaming quality will be automatically reduced."
                )
                thermalWarning = warning
                thermalWarningPublished.send(warning)
            }
        } else if thermalState == .serious {
            if lastThermalWarningState != .serious && lastThermalWarningState != .critical {
                let warning = ThermalWarning(
                    level: .throttling,
                    thermalState: thermalState,
                    message: "Device is getting warm. Quality may be reduced to prevent overheating."
                )
                thermalWarning = warning
                thermalWarningPublished.send(warning)
            }
        } else {
            thermalWarning = nil
        }

        lastThermalWarningState = thermalState
    }

    // MARK: - Quality Recommendation

    private func evaluateQualityRecommendation() {
        let recommendation = computeQualityRecommendation()
        recommendedQuality = recommendation.quality
        recommendedBitrateMultiplier = recommendation.bitrateMultiplier
        qualityRecommendationChanged.send(recommendation)
        shouldReduceQuality.send(recommendation)
    }

    private func computeQualityRecommendation() -> QualityRecommendation {
        var quality = StreamQuality.balanced
        var bitrateMultiplier = 1.0
        var reductionReasons: [String] = []

        if isLowPowerMode {
            quality = .low
            bitrateMultiplier = min(bitrateMultiplier, 0.5)
            reductionReasons.append("Low Power Mode")
        }

        if !isCharging {
            if batteryLevel <= criticalBatteryThreshold {
                quality = .ultraLow
                bitrateMultiplier = min(bitrateMultiplier, 0.25)
                reductionReasons.append("Critical battery")
            } else if batteryLevel <= lowBatteryThreshold {
                if quality.rawValue > StreamQuality.low.rawValue {
                    quality = .low
                }
                bitrateMultiplier = min(bitrateMultiplier, 0.5)
                reductionReasons.append("Low battery")
            }
        }

        switch thermalState {
        case .critical:
            quality = .ultraLow
            bitrateMultiplier = min(bitrateMultiplier, 0.25)
            reductionReasons.append("Critical thermal state")
        case .serious:
            if quality.rawValue > StreamQuality.low.rawValue {
                quality = .low
            }
            bitrateMultiplier = min(bitrateMultiplier, 0.5)
            reductionReasons.append("High thermal state")
        case .fair:
            if quality.rawValue > StreamQuality.balanced.rawValue {
                quality = .balanced
            }
            bitrateMultiplier = min(bitrateMultiplier, 0.75)
            reductionReasons.append("Warm thermal state")
        case .nominal:
            break
        }

        return QualityRecommendation(
            quality: quality,
            bitrateMultiplier: bitrateMultiplier,
            reason: reductionReasons.joined(separator: "; "),
            batteryLevel: batteryLevel,
            thermalState: thermalState,
            isCharging: isCharging,
            isLowPowerMode: isLowPowerMode
        )
    }

    // MARK: - Quality Application

    func applyRecommendedQuality(to settings: inout CameraConfiguration) {
        let recommendation = computeQualityRecommendation()

        settings.resolution = resolutionForQuality(recommendation.quality)
        settings.bitrate = Int(Double(settings.bitrate) * recommendation.bitrateMultiplier)

        let baseFPS = settings.frameRate
        if recommendation.quality == .ultraLow {
            settings.frameRate = min(baseFPS, 15)
        } else if recommendation.quality == .low {
            settings.frameRate = min(baseFPS, 24)
        }
    }

    func suggestedBitrate(for baseBitrate: Int) -> Int {
        let multiplier = computeQualityRecommendation().bitrateMultiplier
        return Int(Double(baseBitrate) * multiplier)
    }

    func suggestedFrameRate(for baseFrameRate: Int) -> Int {
        let quality = computeQualityRecommendation().quality
        switch quality {
        case .ultraLow: return min(baseFrameRate, 15)
        case .low: return min(baseFrameRate, 24)
        default: return baseFrameRate
        }
    }

    func suggestedResolution(for baseResolution: VideoResolution) -> VideoResolution {
        let quality = computeQualityRecommendation().quality
        return resolutionForQuality(quality, maximum: baseResolution)
    }

    // MARK: - Dismiss Warnings

    func dismissBatteryWarning() {
        batteryWarning = nil
    }

    func dismissThermalWarning() {
        thermalWarning = nil
    }

    func dismissAllWarnings() {
        batteryWarning = nil
        thermalWarning = nil
    }

    // MARK: - Formatted Properties

    var formattedBatteryLevel: String {
        String(format: "%.0f%%", batteryLevel * 100)
    }

    var batteryIconName: String {
        guard batteryLevel >= 0 else { return "battery.0" }

        let percentage = batteryLevel * 100

        if isCharging {
            if percentage >= 80 { return "battery.100.bolt" }
            if percentage >= 60 { return "battery.75.bolt" }
            if percentage >= 40 { return "battery.50.bolt" }
            if percentage >= 20 { return "battery.25.bolt" }
            return "battery.0.bolt"
        }

        if percentage >= 80 { return "battery.100" }
        if percentage >= 60 { return "battery.75" }
        if percentage >= 40 { return "battery.50" }
        if percentage >= 20 { return "battery.25" }
        if percentage > 0 { return "battery.0" }
        return "battery.0"
    }

    var thermalIconName: String {
        switch thermalState {
        case .nominal: return "thermometer.medium"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "thermometer.medium"
        }
    }

    var thermalColorName: String {
        thermalState.colorName
    }

    // MARK: - Helpers

    private func resolutionForQuality(_ quality: StreamQuality, maximum: VideoResolution? = nil) -> VideoResolution {
        let target: VideoResolution = {
            switch quality {
            case .ultraLow: return .qvga480
            case .low: return .hd720
            case .balanced: return .hd1080
            case .high: return .hd1080
            case .ultraHigh: return .uhd4K
            }
        }()

        if let maximum {
            let maxOrder = VideoResolution.allCases.firstIndex(of: maximum) ?? 3
            let targetOrder = VideoResolution.allCases.firstIndex(of: target) ?? 3
            if targetOrder > maxOrder {
                return maximum
            }
        }

        return target
    }

    // MARK: - Device Info

    func currentDeviceInfo() -> BatteryDeviceInfo {
        BatteryDeviceInfo(
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            thermalState: thermalState,
            isLowPowerMode: isLowPowerMode,
            recommendedQuality: recommendedQuality,
            formattedBatteryLevel: formattedBatteryLevel,
            batteryIconName: batteryIconName
        )
    }
}

// MARK: - Types

enum BatteryMonitorState: String, Sendable {
    case unknown
    case unplugged
    case charging
    case full

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .unplugged: return "On Battery"
        case .charging: return "Charging"
        case .full: return "Full"
        }
    }

    var iconName: String {
        switch self {
        case .unknown: return "battery.unknown"
        case .unplugged: return "battery"
        case .charging: return "battery.100.bolt"
        case .full: return "battery.100"
        }
    }
}

struct BatteryWarning: Identifiable, Sendable {
    let id = UUID()
    let level: BatteryWarningLevel
    let batteryLevel: Float
    let message: String
    let timestamp = Date()
}

enum BatteryWarningLevel: Sendable {
    case low
    case critical

    var title: String {
        switch self {
        case .low: return "Low Battery"
        case .critical: return "Critical Battery"
        }
    }

    var iconName: String {
        switch self {
        case .low: return "battery.25"
        case .critical: return "battery.0"
        }
    }
}

struct ThermalWarning: Identifiable, Sendable {
    let id = UUID()
    let level: ThermalWarningLevel
    let thermalState: ThermalState
    let message: String
    let timestamp = Date()
}

enum ThermalWarningLevel: Sendable {
    case throttling
    case critical

    var title: String {
        switch self {
        case .throttling: return "Device Warming Up"
        case .critical: return "Overheating Warning"
        }
    }

    var iconName: String {
        switch self {
        case .throttling: return "thermometer.medium"
        case .critical: return "thermometer.high"
        }
    }
}

struct QualityRecommendation: Sendable {
    let quality: StreamQuality
    let bitrateMultiplier: Double
    let reason: String
    let batteryLevel: Float
    let thermalState: ThermalState
    let isCharging: Bool
    let isLowPowerMode: Bool

    var isReduced: Bool {
        quality != .balanced || bitrateMultiplier < 1.0
    }

    var displayText: String {
        if reason.isEmpty {
            return "Quality: \(quality.displayName)"
        }
        return "\(quality.displayName) â€” \(reason)"
    }
}

struct BatteryDeviceInfo: Sendable {
    let batteryLevel: Float
    let batteryState: BatteryMonitorState
    let isCharging: Bool
    let isPluggedIn: Bool
    let thermalState: ThermalState
    let isLowPowerMode: Bool
    let recommendedQuality: StreamQuality
    let formattedBatteryLevel: String
    let batteryIconName: String
}
