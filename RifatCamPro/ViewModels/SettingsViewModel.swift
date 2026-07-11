import Foundation
import Combine
import SwiftUI

@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - Dependencies

    let cameraService: CameraService
    let networkService: NetworkService
    let settingsManager: SettingsManager
    let securityService: SecurityService

    // MARK: - Camera Settings

    var resolution: VideoResolution = .hd1080
    var frameRate: Int = 30
    var codec: StreamingCodec = .h264
    var bitrate: Int = 4_000_000
    var enableTorch: Bool = false
    var enableHDR: Bool = false
    var enableAutoFocus: Bool = true
    var zoomFactor: CGFloat = 1.0
    var exposureISO: Float = 100
    var whiteBalanceTemperature: CGFloat = 5600

    // MARK: - Mirror & Audio

    var mirrorFrontCamera: Bool = true
    var mirrorBackCamera: Bool = false
    var enableAudio: Bool = true
    var enableNoiseSuppression: Bool = true
    var audioMuted: Bool = false

    // MARK: - Network Settings

    var port: UInt16 = 4747
    var password: String = ""
    var enablePasswordProtection: Bool = false
    var enableBonjour: Bool = true
    var enableTLS: Bool = false
    var connectionTimeout: TimeInterval = 10
    var maxConnections: Int = 1

    // MARK: - App Settings

    var selectedTheme: AppTheme = .dark
    var streamQuality: StreamQuality = .balanced
    var backgroundStreaming: Bool = true
    var autoConnect: Bool = false
    var showNetworkStats: Bool = true
    var enableNotifications: Bool = true
    var watermarkText: String = ""

    // MARK: - Available Options

    var availableResolutions: [VideoResolution] = VideoResolution.allCases
    var availableFrameRates: [Int] = [15, 24, 25, 30, 48, 50, 60]
    var availableCodecs: [StreamingCodec] = [.mjpeg, .h264, .hevc]
    var availableThemes: [AppTheme] = AppTheme.allCases
    var availableQualities: [StreamQuality] = StreamQuality.allCases
    var availablePresets: [SettingsPreset] = SettingsPreset.allCases
    var maxZoomFactor: CGFloat = 10.0
    var isoRange: ClosedRange<Float> = 100...3200

    // MARK: - Validation State

    var isPortValid: Bool = true
    var isPasswordValid: Bool = true
    var validationMessage: String = ""

    // MARK: - UI State

    var showErrorAlert = false
    var errorTitle: String = ""
    var errorMessage: String = ""
    var showResetConfirmation = false
    var showImportSheet = false
    var showExportSheet = false
    var importResultMessage: String = ""
    var showImportResult = false
    var selectedPreset: SettingsPreset?

    // MARK: - Security Warnings

    var securityWarnings: [SecurityWarning] = []

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        cameraService: CameraService,
        networkService: NetworkService,
        settingsManager: SettingsManager,
        securityService: SecurityService
    ) {
        self.cameraService = cameraService
        self.networkService = networkService
        self.settingsManager = settingsManager
        self.securityService = securityService

        loadCurrentSettings()
        bindSettingsManager()
        validateAll()
    }

    // MARK: - Load Current Settings

    func loadCurrentSettings() {
        let config = settingsManager.currentSettings

        resolution = config.camera.resolution
        frameRate = config.camera.frameRate
        codec = config.camera.codec
        bitrate = config.camera.bitrate
        enableTorch = config.camera.enableTorch
        enableHDR = config.camera.enableHDR
        enableAutoFocus = config.camera.enableAutoFocus
        zoomFactor = config.camera.zoomFactor
        exposureISO = config.camera.exposureISO
        whiteBalanceTemperature = config.camera.whiteBalanceTemperature
        mirrorFrontCamera = config.camera.mirrorFrontCamera
        mirrorBackCamera = config.camera.mirrorBackCamera
        enableAudio = config.camera.enableAudio
        enableNoiseSuppression = config.camera.enableNoiseSuppression
        audioMuted = config.camera.audioMuted
        watermarkText = config.camera.watermarkText

        port = config.network.port
        password = config.network.password
        enablePasswordProtection = config.network.enablePasswordProtection
        enableBonjour = config.network.enableBonjour
        enableTLS = config.network.enableTLS
        connectionTimeout = config.network.connectionTimeout
        maxConnections = config.network.maxConnections

        selectedTheme = config.theme
        streamQuality = config.streamQuality
        backgroundStreaming = config.backgroundStreaming
        autoConnect = config.autoConnect
        showNetworkStats = config.showNetworkStats
        enableNotifications = config.enableNotifications

        if let device = cameraService.currentVideoDevice() {
            maxZoomFactor = cameraService.availableZoomRange().upperBound
            isoRange = cameraService.availableISORange()
        }
    }

    // MARK: - Camera Settings Apply

    func applyResolution(_ newResolution: VideoResolution) {
        resolution = newResolution
        var config = settingsManager.cameraConfiguration
        config.resolution = newResolution
        settingsManager.cameraConfiguration = config
        applyToCameraService()
    }

    func applyFrameRate(_ newFrameRate: Int) {
        frameRate = newFrameRate
        var config = settingsManager.cameraConfiguration
        config.frameRate = newFrameRate
        settingsManager.cameraConfiguration = config
        applyToCameraService()
    }

    func applyCodec(_ newCodec: StreamingCodec) {
        codec = newCodec
        var config = settingsManager.cameraConfiguration
        config.codec = newCodec
        settingsManager.cameraConfiguration = config
    }

    func applyBitrate(_ newBitrate: Int) {
        let clamped = max(100_000, min(newBitrate, 50_000_000))
        bitrate = clamped
        var config = settingsManager.cameraConfiguration
        config.bitrate = clamped
        settingsManager.cameraConfiguration = config
    }

    func applyTorch(_ enabled: Bool) {
        enableTorch = enabled
        cameraService.setTorch(on: enabled)
        var config = settingsManager.cameraConfiguration
        config.enableTorch = enabled
        settingsManager.cameraConfiguration = config
    }

    func applyHDR(_ enabled: Bool) {
        enableHDR = enabled
        cameraService.setHDR(enabled)
        var config = settingsManager.cameraConfiguration
        config.enableHDR = enabled
        settingsManager.cameraConfiguration = config
    }

    func applyAutoFocus(_ enabled: Bool) {
        enableAutoFocus = enabled
        var config = settingsManager.cameraConfiguration
        config.enableAutoFocus = enabled
        settingsManager.cameraConfiguration = config
    }

    func applyZoom(_ factor: CGFloat) {
        let clamped = max(1.0, min(factor, maxZoomFactor))
        zoomFactor = clamped
        cameraService.setZoom(clamped)
        var config = settingsManager.cameraConfiguration
        config.zoomFactor = clamped
        settingsManager.cameraConfiguration = config
    }

    func applyExposureISO(_ iso: Float) {
        let clamped = max(isoRange.lowerBound, min(iso, isoRange.upperBound))
        exposureISO = clamped
        cameraService.setExposure(iso: clamped)
        var config = settingsManager.cameraConfiguration
        config.exposureISO = clamped
        settingsManager.cameraConfiguration = config
    }

    func applyWhiteBalance(_ temperature: CGFloat) {
        let clamped = max(2000, min(temperature, 12000))
        whiteBalanceTemperature = clamped
        cameraService.setWhiteBalance(temperature: clamped)
        var config = settingsManager.cameraConfiguration
        config.whiteBalanceTemperature = clamped
        settingsManager.cameraConfiguration = config
    }

    // MARK: - Mirror Settings

    func applyMirrorFront(_ enabled: Bool) {
        mirrorFrontCamera = enabled
        var config = settingsManager.cameraConfiguration
        config.mirrorFrontCamera = enabled
        settingsManager.cameraConfiguration = config
        applyToCameraService()
    }

    func applyMirrorBack(_ enabled: Bool) {
        mirrorBackCamera = enabled
        var config = settingsManager.cameraConfiguration
        config.mirrorBackCamera = enabled
        settingsManager.cameraConfiguration = config
        applyToCameraService()
    }

    // MARK: - Audio Settings

    func applyAudioEnabled(_ enabled: Bool) {
        enableAudio = enabled
        var config = settingsManager.cameraConfiguration
        config.enableAudio = enabled
        settingsManager.cameraConfiguration = config
        applyToCameraService()
    }

    func applyNoiseSuppression(_ enabled: Bool) {
        enableNoiseSuppression = enabled
        var config = settingsManager.cameraConfiguration
        config.enableNoiseSuppression = enabled
        settingsManager.cameraConfiguration = config
    }

    func applyAudioMuted(_ muted: Bool) {
        audioMuted = muted
        var config = settingsManager.cameraConfiguration
        config.audioMuted = muted
        settingsManager.cameraConfiguration = config
    }

    // MARK: - Watermark

    func applyWatermark(_ text: String) {
        watermarkText = text
        var config = settingsManager.cameraConfiguration
        config.watermarkText = text
        settingsManager.cameraConfiguration = config
    }

    // MARK: - Network Settings Apply

    func applyPort(_ newPort: UInt16) {
        guard newPort > 0, newPort <= 65535 else {
            isPortValid = false
            validationMessage = "Port must be between 1 and 65535"
            return
        }
        isPortValid = true
        port = newPort
        var config = settingsManager.currentSettings
        config.network.port = newPort
        settingsManager.networkConfiguration = config.network
    }

    func applyPassword(_ newPassword: String) {
        password = newPassword
        var config = settingsManager.currentSettings
        config.network.password = newPassword
        settingsManager.networkConfiguration = config.network
        updateSecurityWarnings()
    }

    func applyPasswordProtection(_ enabled: Bool) {
        enablePasswordProtection = enabled
        var config = settingsManager.currentSettings
        config.network.enablePasswordProtection = enabled
        settingsManager.networkConfiguration = config.network
        updateSecurityWarnings()
    }

    func applyBonjour(_ enabled: Bool) {
        enableBonjour = enabled
        var config = settingsManager.currentSettings
        config.network.enableBonjour = enabled
        settingsManager.networkConfiguration = config.network
    }

    func applyTLS(_ enabled: Bool) {
        enableTLS = enabled
        var config = settingsManager.currentSettings
        config.network.enableTLS = enabled
        settingsManager.networkConfiguration = config.network
        updateSecurityWarnings()
    }

    func applyConnectionTimeout(_ timeout: TimeInterval) {
        let clamped = max(5, min(timeout, 120))
        connectionTimeout = clamped
        var config = settingsManager.currentSettings
        config.network.connectionTimeout = clamped
        settingsManager.networkConfiguration = config.network
    }

    func applyMaxConnections(_ max: Int) {
        let clamped = max(1, min(max, 10))
        maxConnections = clamped
        var config = settingsManager.currentSettings
        config.network.maxConnections = clamped
        settingsManager.networkConfiguration = config.network
        updateSecurityWarnings()
    }

    // MARK: - Theme

    func applyTheme(_ theme: AppTheme) {
        selectedTheme = theme
        settingsManager.theme = theme
    }

    // MARK: - Stream Quality

    func applyStreamQuality(_ quality: StreamQuality) {
        streamQuality = quality
        settingsManager.streamQuality = quality

        switch quality {
        case .ultraLow:
            applyBitrate(500_000)
        case .low:
            applyBitrate(1_000_000)
        case .balanced:
            applyBitrate(4_000_000)
        case .high:
            applyBitrate(8_000_000)
        case .ultraHigh:
            applyBitrate(15_000_000)
        }
    }

    // MARK: - Background & Auto-Connect

    func applyBackgroundStreaming(_ enabled: Bool) {
        backgroundStreaming = enabled
        settingsManager.backgroundStreaming = enabled
    }

    func applyAutoConnect(_ enabled: Bool) {
        autoConnect = enabled
        settingsManager.autoConnect = enabled
    }

    func applyShowNetworkStats(_ enabled: Bool) {
        showNetworkStats = enabled
        settingsManager.showNetworkStats = enabled
    }

    func applyEnableNotifications(_ enabled: Bool) {
        enableNotifications = enabled
        settingsManager.enableNotifications = enabled
    }

    // MARK: - Presets

    func applyPreset(_ preset: SettingsPreset) {
        selectedPreset = preset
        settingsManager.applyPreset(preset)
        loadCurrentSettings()
    }

    // MARK: - Reset

    func resetToDefaults() {
        settingsManager.resetToDefaults()
        loadCurrentSettings()
        updateSecurityWarnings()
    }

    func resetCameraSettings() {
        settingsManager.resetCameraSettings()
        loadCurrentSettings()
    }

    func resetNetworkSettings() {
        settingsManager.resetNetworkSettings()
        loadCurrentSettings()
        updateSecurityWarnings()
    }

    // MARK: - Import / Export

    func exportSettings() -> Data? {
        let data = settingsManager.exportSettings()
        if data == nil {
            showError(.networkError("Failed to export settings"))
        }
        return data
    }

    func exportSettingsAsJSON() -> String? {
        return settingsManager.exportSettingsAsJSON()
    }

    func importSettings(from data: Data) -> Bool {
        let success = settingsManager.importSettings(from: data)
        if success {
            loadCurrentSettings()
            importResultMessage = "Settings imported successfully"
        } else {
            importResultMessage = "Failed to import settings: \(settingsManager.lastSaveError?.localizedDescription ?? "Unknown error")"
        }
        showImportResult = true
        return success
    }

    func importSettings(from jsonString: String) -> Bool {
        let success = settingsManager.importSettings(from: jsonString)
        if success {
            loadCurrentSettings()
            importResultMessage = "Settings imported successfully"
        } else {
            importResultMessage = "Failed to import settings: \(settingsManager.lastSaveError?.localizedDescription ?? "Unknown error")"
        }
        showImportResult = true
        return success
    }

    func importSettings(from url: URL) -> Bool {
        let success = settingsManager.importSettings(from: url)
        if success {
            loadCurrentSettings()
            importResultMessage = "Settings imported successfully"
        } else {
            importResultMessage = "Failed to import settings from file"
        }
        showImportResult = true
        return success
    }

    func exportSettingsToURL(_ url: URL) -> Bool {
        return settingsManager.exportSettingsToURL(url)
    }

    // MARK: - Validation

    func validateAll() {
        validatePort()
        validatePassword()
        updateSecurityWarnings()
    }

    private func validatePort() {
        isPortValid = port > 0 && port <= 65535
        if !isPortValid {
            validationMessage = "Port must be between 1 and 65535"
        }
    }

    private func validatePassword() {
        if enablePasswordProtection && password.isEmpty {
            isPasswordValid = false
            validationMessage = "Password cannot be empty when protection is enabled"
        } else {
            isPasswordValid = true
        }
    }

    func updateSecurityWarnings() {
        var config = settingsManager.currentSettings.network
        config.port = port
        config.password = password
        config.enablePasswordProtection = enablePasswordProtection
        config.enableTLS = enableTLS
        config.maxConnections = maxConnections
        config.connectionTimeout = connectionTimeout
        securityWarnings = securityService.checkSecurityConfiguration(networkConfig: config)
    }

    var isSettingsValid: Bool {
        isPortValid && isPasswordValid && validationMessage.isEmpty
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

    // MARK: - Private Helpers

    private func applyToCameraService() {
        let config = CameraConfiguration(
            resolution: resolution,
            frameRate: frameRate,
            codec: codec,
            bitrate: bitrate,
            enableHDR: enableHDR,
            enableTorch: enableTorch,
            enableAutoFocus: enableAutoFocus,
            zoomFactor: zoomFactor,
            exposureISO: exposureISO,
            whiteBalanceTemperature: whiteBalanceTemperature,
            mirrorFrontCamera: mirrorFrontCamera,
            mirrorBackCamera: mirrorBackCamera,
            enableAudio: enableAudio,
            enableNoiseSuppression: enableNoiseSuppression,
            audioMuted: audioMuted,
            watermarkText: watermarkText,
            selectedCamera: cameraService.currentConfiguration.selectedCamera
        )

        Task {
            do {
                try await cameraService.reconfigure(with: config)
            } catch {
                showError(.configurationFailed(error.localizedDescription))
            }
        }
    }

    private func bindSettingsManager() {
        settingsManager.cameraConfigurationChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                guard let self else { return }
                self.resolution = config.resolution
                self.frameRate = config.frameRate
                self.codec = config.codec
                self.bitrate = config.bitrate
                self.enableTorch = config.enableTorch
                self.enableHDR = config.enableHDR
                self.mirrorFrontCamera = config.mirrorFrontCamera
                self.mirrorBackCamera = config.mirrorBackCamera
                self.enableAudio = config.enableAudio
                self.enableNoiseSuppression = config.enableNoiseSuppression
                self.audioMuted = config.audioMuted
                self.watermarkText = config.watermarkText
            }
            .store(in: &cancellables)

        settingsManager.networkConfigurationChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                guard let self else { return }
                self.port = config.port
                self.password = config.password
                self.enablePasswordProtection = config.enablePasswordProtection
                self.enableBonjour = config.enableBonjour
                self.enableTLS = config.enableTLS
                self.connectionTimeout = config.connectionTimeout
                self.maxConnections = config.maxConnections
            }
            .store(in: &cancellables)

        settingsManager.settingsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let self else { return }
                self.selectedTheme = settings.theme
                self.streamQuality = settings.streamQuality
                self.backgroundStreaming = settings.backgroundStreaming
                self.autoConnect = settings.autoConnect
                self.showNetworkStats = settings.showNetworkStats
                self.enableNotifications = settings.enableNotifications
            }
            .store(in: &cancellables)

        cameraService.errorSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.showError(error)
            }
            .store(in: &cancellables)
    }
}
