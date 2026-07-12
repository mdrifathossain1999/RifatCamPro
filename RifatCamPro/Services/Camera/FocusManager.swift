import AVFoundation
import Combine

@Observable
final class FocusManager {
    var currentFocusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus
    var currentExposureMode: AVCaptureDevice.ExposureMode = .continuousAutoExposure
    var currentWhiteBalanceMode: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance
    var focusPoint: CGPoint?
    var zoomFactor: CGFloat = 1.0
    var exposureISO: Float = 100
    var exposureDuration: CMTime = CMTime(value: 1, timescale: 30)
    var whiteBalanceTemperature: CGFloat = 5600

    var isFocusLocked: Bool {
        currentFocusMode == .locked
    }

    var isExposureLocked: Bool {
        currentExposureMode == .locked || currentExposureMode == .custom
    }

    var isWhiteBalanceLocked: Bool {
        currentWhiteBalanceMode == .locked
    }

    var focusModeDescription: String {
        switch currentFocusMode {
        case .autoFocus: return "Auto Focus"
        case .continuousAutoFocus: return "Continuous AF"
        case .locked: return "Locked"
        @unknown default: return "Unknown"
        }
    }

    var exposureModeDescription: String {
        switch currentExposureMode {
        case .autoExpose: return "Auto Exposure"
        case .continuousAutoExposure: return "Continuous AE"
        case .locked: return "Locked"
        case .custom: return "Manual"
        @unknown default: return "Unknown"
        }
    }

    var whiteBalanceModeDescription: String {
        switch currentWhiteBalanceMode {
        case .autoWhiteBalance: return "Auto WB"
        case .continuousAutoWhiteBalance: return "Continuous AWB"
        case .locked: return "Locked"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Focus

    func lockFocus(device: AVCaptureDevice, at point: CGPoint) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
        }

        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
            currentFocusMode = .locked
        } else if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
            currentFocusMode = .autoFocus
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
            currentFocusMode = .continuousAutoFocus
        }

        focusPoint = point

        if device.isLockingFocusWithCustomLensPositionSupported {
            let normalizedPoint = device.lensPosition
            device.setFocusModeLocked(lensPosition: normalizedPoint, completionHandler: nil)
        }
    }

    func unlockFocus(device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
            currentFocusMode = .continuousAutoFocus
        }
        focusPoint = nil
    }

    func focusWithTap(device: AVCaptureDevice, at point: CGPoint, in viewSize: CGSize) throws {
        let normalizedPoint = CGPoint(
            x: point.y / viewSize.height,
            y: 1.0 - (point.x / viewSize.width)
        )

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = normalizedPoint
        }

        if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
            currentFocusMode = .autoFocus
        }

        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = normalizedPoint
        }

        if device.isExposureModeSupported(.autoExpose) {
            device.exposureMode = .autoExpose
            currentExposureMode = .autoExpose
        }

        focusPoint = point
    }

    func setContinuousAutoFocus(device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
            currentFocusMode = .continuousAutoFocus
        }
        focusPoint = nil
    }

    // MARK: - Exposure

    func lockExposure(device: AVCaptureDevice, iso: Float, duration: CMTime) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let clampedISO = max(device.activeFormat.minISO, min(iso, device.activeFormat.maxISO))
        let supportedDurations = device.activeFormat.minExposureDuration...device.activeFormat.maxExposureDuration
        let clampedDuration = clampDuration(duration, to: supportedDurations)

        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO, completionHandler: nil)
            currentExposureMode = .custom
        } else if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
            currentExposureMode = .locked
        }

        exposureISO = clampedISO
        exposureDuration = clampedDuration
    }

    func lockExposure(device: AVCaptureDevice, iso: Float) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let clampedISO = max(device.activeFormat.minISO, min(iso, device.activeFormat.maxISO))

        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(
                duration: device.exposureDuration,
                iso: clampedISO,
                completionHandler: nil
            )
            currentExposureMode = .custom
        }

        exposureISO = clampedISO
        exposureDuration = device.exposureDuration
    }

    func unlockExposure(device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
            currentExposureMode = .continuousAutoExposure
        }
    }

    func setExposureTargetBias(device: AVCaptureDevice, bias: Float) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let clampedBias = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
        device.setExposureTargetBias(clampedBias, completionHandler: nil)
    }

    // MARK: - White Balance

    func lockWhiteBalance(device: AVCaptureDevice, temperature: CGFloat) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let tint = Self.temperatureToTint(temperature)
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: Float(temperature),
            tint: Float(tint)
        )

        if device.isWhiteBalanceModeSupported(.locked) {
            device.setWhiteBalanceModeLocked(with: values, completionHandler: nil)
            currentWhiteBalanceMode = .locked
        }

        whiteBalanceTemperature = temperature
    }

    func lockWhiteBalance(device: AVCaptureDevice, gains: AVCaptureDevice.WhiteBalanceGains) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let maxGains = AVCaptureDevice.WhiteBalanceGains(redGain: 4.0, greenGain: 4.0, blueGain: 4.0)
        let clampedGains = AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(gains.redGain, 1.0), maxGains.redGain),
            greenGain: min(max(gains.greenGain, 1.0), maxGains.greenGain),
            blueGain: min(max(gains.blueGain, 1.0), maxGains.blueGain)
        )

        if device.isWhiteBalanceModeSupported(.locked) {
            device.setWhiteBalanceModeLocked(with: clampedGains, completionHandler: nil)
            currentWhiteBalanceMode = .locked
        }
    }

    func unlockWhiteBalance(device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            currentWhiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    func temperatureForWhiteBalanceGains(_ gains: AVCaptureDevice.WhiteBalanceGains) -> CGFloat {
        let temperature = 5600.0
        return temperature
    }

    // MARK: - Zoom

    func setZoom(device: AVCaptureDevice, factor: CGFloat) throws {
        let maxZoom = device.activeFormat.videoMaxZoomFactor
        let clampedFactor = max(1.0, min(factor, maxZoom))

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.videoZoomFactor = clampedFactor
        zoomFactor = clampedFactor
    }

    func rampZoom(device: AVCaptureDevice, to factor: CGFloat, rate: Float) throws {
        let maxZoom = device.activeFormat.videoMaxZoomFactor
        let clampedFactor = max(1.0, min(factor, maxZoom))

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.ramp(toVideoZoomFactor: clampedFactor, withRate: rate)
        zoomFactor = clampedFactor
    }

    func smoothZoom(device: AVCaptureDevice, to factor: CGFloat, duration: TimeInterval = 0.5) throws {
        let maxZoom = device.activeFormat.videoMaxZoomFactor
        let clampedFactor = max(1.0, min(factor, maxZoom))
        let currentZoom = device.videoZoomFactor

        let totalFrames = Int(duration * 30)
        guard totalFrames > 0 else {
            try setZoom(device: device, factor: clampedFactor)
            return
        }

        let zoomStep = (clampedFactor - currentZoom) / CGFloat(totalFrames)
        var frame = 0

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: duration / Double(totalFrames))
        timer.setEventHandler { [weak device] in
            guard let device, frame < totalFrames else {
                timer.cancel()
                return
            }
            frame += 1
            let targetZoom = currentZoom + zoomStep * CGFloat(frame)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = targetZoom
                device.unlockForConfiguration()
            } catch {}
        }
        timer.resume()
    }

    // MARK: - Reset All

    func resetToAuto(device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
            currentFocusMode = .continuousAutoFocus
        }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
            currentExposureMode = .continuousAutoExposure
        }

        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            currentWhiteBalanceMode = .continuousAutoWhiteBalance
        }

        device.videoZoomFactor = 1.0
        zoomFactor = 1.0
        focusPoint = nil
        exposureISO = 100
        exposureDuration = CMTime(value: 1, timescale: 30)
        whiteBalanceTemperature = 5600
    }

    // MARK: - Capabilities Query

    func availableFocusModes(for device: AVCaptureDevice) -> [AVCaptureDevice.FocusMode] {
        var modes: [AVCaptureDevice.FocusMode] = []
        if device.isFocusModeSupported(.autoFocus) { modes.append(.autoFocus) }
        if device.isFocusModeSupported(.continuousAutoFocus) { modes.append(.continuousAutoFocus) }
        if device.isFocusModeSupported(.locked) { modes.append(.locked) }
        return modes
    }

    func availableExposureModes(for device: AVCaptureDevice) -> [AVCaptureDevice.ExposureMode] {
        var modes: [AVCaptureDevice.ExposureMode] = []
        if device.isExposureModeSupported(.autoExpose) { modes.append(.autoExpose) }
        if device.isExposureModeSupported(.continuousAutoExposure) { modes.append(.continuousAutoExposure) }
        if device.isExposureModeSupported(.custom) { modes.append(.custom) }
        if device.isExposureModeSupported(.locked) { modes.append(.locked) }
        return modes
    }

    func availableWhiteBalanceModes(for device: AVCaptureDevice) -> [AVCaptureDevice.WhiteBalanceMode] {
        var modes: [AVCaptureDevice.WhiteBalanceMode] = []
        if device.isWhiteBalanceModeSupported(.autoWhiteBalance) { modes.append(.autoWhiteBalance) }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { modes.append(.continuousAutoWhiteBalance) }
        if device.isWhiteBalanceModeSupported(.locked) { modes.append(.locked) }
        return modes
    }

    func maxZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        device.activeFormat.videoMaxZoomFactor
    }

    func isoRange(for device: AVCaptureDevice) -> ClosedRange<Float> {
        device.activeFormat.minISO...device.activeFormat.maxISO
    }

    func exposureDurationRange(for device: AVCaptureDevice) -> ClosedRange<CMTime> {
        device.activeFormat.minExposureDuration...device.activeFormat.maxExposureDuration
    }

    // MARK: - Helpers

    static func temperatureToTint(_ temperature: CGFloat) -> CGFloat {
        if temperature < 5000 {
            let normalized = (temperature - 2856) / (5000 - 2856)
            return CGFloat(lerp(-150, to: 0, by: CGFloat(max(0, min(1, normalized)))))
        } else if temperature > 7000 {
            let normalized = (temperature - 7000) / (12000 - 7000)
            return CGFloat(lerp(0, to: 150, by: CGFloat(max(0, min(1, normalized)))))
        }
        return 0
    }

    private func clampDuration(_ duration: CMTime, to range: ClosedRange<CMTime>) -> CMTime {
        let minValue = range.lowerBound.value
        let maxValue = range.upperBound.value
        let clamped = Swift.max(minValue, Swift.min(duration.value, maxValue))
        return CMTime(value: clamped, timescale: duration.timescale)
    }

    private static func lerp(_ from: CGFloat, to: CGFloat, by t: CGFloat) -> CGFloat {
        from + (to - from) * t
    }
}
