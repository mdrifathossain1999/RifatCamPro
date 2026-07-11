import Foundation
import Combine
import SwiftUI
import UIKit

@Observable
@MainActor
final class HomeViewModel {

    // MARK: - Dependencies

    let cameraService: CameraService
    let networkService: NetworkService
    let streamManager: StreamManager
    let connectionManager: ConnectionManager
    let settingsManager: SettingsManager
    let bonjourService: BonjourService
    let securityService: SecurityService
    let batteryManager: BatteryManager
    let videoEncoder: VideoEncoder

    // MARK: - Camera State

    var isSessionRunning = false
    var cameraPermissionGranted = false
    var audioPermissionGranted = false
    var availableCameras: [CameraInfo] = []
    var currentPosition: CameraPosition = .back
    var isTorchOn = false
    var currentFPS: Double = 0
    var thermalState: ThermalState = .nominal

    // MARK: - Streaming State

    var isStreaming = false
    var streamingDuration: String = "00:00"

    // MARK: - Network Stats

    var localIP: String = "Detecting..."
    var port: UInt16 = 4747
    var connectionStatus: ConnectionStatus = .disconnected
    var formattedBitrate: String = "0 Kbps"
    var formattedLatency: String = "0.0 ms"
    var formattedBytesSent: String = "0 B"

    // MARK: - Battery & Device

    var batteryLevel: Float = 1.0
    var batteryIconName: String = "battery.100"
    var deviceInfo = DeviceInfo(
        name: UIDevice.current.name,
        model: UIDevice.current.model,
        systemVersion: UIDevice.current.systemVersion,
        batteryLevel: UIDevice.current.batteryLevel,
        thermalState: .nominal,
        availableCameras: []
    )

    // MARK: - UI State

    var showSettings = false
    var showPairing = false
    var showErrorAlert = false
    var errorMessage: String = ""
    var errorTitle: String = ""
    var showQRCode = false
    var qrCodeImage: UIImage?
    var showCameraSwitchConfirmation = false
    var isInitializing = true

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var durationTimer: Timer?

    // MARK: - Init

    init(
        cameraService: CameraService,
        networkService: NetworkService,
        streamManager: StreamManager,
        connectionManager: ConnectionManager,
        settingsManager: SettingsManager,
        bonjourService: BonjourService,
        securityService: SecurityService,
        batteryManager: BatteryManager,
        videoEncoder: VideoEncoder
    ) {
        self.cameraService = cameraService
        self.networkService = networkService
        self.streamManager = streamManager
        self.connectionManager = connectionManager
        self.settingsManager = settingsManager
        self.bonjourService = bonjourService
        self.securityService = securityService
        self.batteryManager = batteryManager
        self.videoEncoder = videoEncoder

        bindCameraService()
        bindNetworkService()
        bindStreamManager()
        bindConnectionManager()
        bindBatteryManager()
        bindSettingsManager()

        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    deinit {
        durationTimer?.invalidate()
    }

    // MARK: - Initialization

    func initialize() async {
        isInitializing = true
        defer { isInitializing = false }

        await cameraService.checkPermissions()
        cameraPermissionGranted = cameraService.cameraPermissionGranted
        audioPermissionGranted = cameraService.audioPermissionGranted

        guard cameraPermissionGranted else {
            showError(AppError.cameraAccessDenied)
            return
        }

        do {
            let config = settingsManager.cameraConfiguration
            try await cameraService.configureSession(with: config)
            cameraService.startSession()

            availableCameras = cameraService.availableCameras
            currentPosition = config.selectedCamera
            isTorchOn = config.enableTorch
            currentFPS = cameraService.currentFPS
        } catch {
            if let appError = error as? AppError {
                showError(appError)
            } else {
                showError(.configurationFailed(error.localizedDescription))
            }
        }

        networkService.refreshIPAddress()
        port = settingsManager.port
        localIP = networkService.localIPAddress ?? "Unavailable"
        batteryManager.startMonitoring()
    }

    // MARK: - Streaming Actions

    func startStreaming() async {
        guard !isStreaming else { return }

        do {
            let config = settingsManager.currentSettings.camera
            let netConfig = settingsManager.currentSettings.network

            try await videoEncoder.startSession(
                width: config.resolution.width,
                height: config.resolution.height,
                bitrate: config.bitrate,
                frameRate: config.frameRate,
                codec: config.codec
            )

            networkService.port = netConfig.port
            networkService.useTLS = netConfig.enableTLS
            networkService.connectionTimeout = netConfig.connectionTimeout

            if netConfig.enablePasswordProtection && !netConfig.password.isEmpty {
                networkService.requiredPassword = netConfig.password
            } else {
                networkService.requiredPassword = nil
            }

            networkService.start()

            if netConfig.enableBonjour {
                bonjourService.start()
            }

            isStreaming = true
            startDurationTimer()
        } catch {
            if let appError = error as? AppError {
                showError(appError)
            } else {
                showError(.streamingError(error.localizedDescription))
            }
        }
    }

    func stopStreaming() {
        guard isStreaming else { return }

        streamManager.stopStreaming()
        videoEncoder.stopSession()
        networkService.stop()
        bonjourService.stop()

        isStreaming = false
        stopDurationTimer()
        streamingDuration = "00:00"
    }

    func toggleStreaming() async {
        if isStreaming {
            stopStreaming()
        } else {
            await startStreaming()
        }
    }

    // MARK: - Camera Actions

    func switchCamera() {
        let newPosition: CameraPosition = currentPosition == .back ? .front : .back
        guard availableCameras.contains(where: { $0.position == newPosition }) else { return }

        cameraService.switchCamera()
        currentPosition = newPosition

        var config = settingsManager.cameraConfiguration
        config.selectedCamera = newPosition
        settingsManager.cameraConfiguration = config
    }

    func toggleTorch() {
        let newState = !isTorchOn
        cameraService.setTorch(on: newState)
        isTorchOn = newState

        var config = settingsManager.cameraConfiguration
        config.enableTorch = newState
        settingsManager.cameraConfiguration = config
    }

    func capturePhoto() {
        cameraService.capturePhoto { [weak self] image in
            guard let self else { return }
            if let image {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
        }
    }

    // MARK: - Navigation

    func navigateToSettings() {
        showSettings = true
    }

    func navigateToPairing() {
        showPairing = true
    }

    // MARK: - QR Code

    func generateQRCode() {
        let netConfig = settingsManager.currentSettings.network
        let ip = networkService.localIPAddress ?? ""
        let password = netConfig.enablePasswordProtection ? netConfig.password : ""

        let payload = QRCodeGenerator.PairingPayload(
            ip: ip,
            port: netConfig.port,
            password: password,
            proto: "tcp"
        )

        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            showError(.networkError("Failed to encode QR data"))
            return
        }

        qrCodeImage = QRCodeGenerator.generateQR(from: jsonString)

        guard qrCodeImage != nil else {
            showError(.networkError("Failed to generate QR code"))
            return
        }

        showQRCode = true
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

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let startTime = self.streamManager.streamingState.startTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let total = Int(elapsed)
                    let hours = total / 3600
                    let minutes = (total % 3600) / 60
                    let seconds = total % 60
                    if hours > 0 {
                        self.streamingDuration = String(format: "%d:%02d:%02d", hours, minutes, seconds)
                    } else {
                        self.streamingDuration = String(format: "%02d:%02d", minutes, seconds)
                    }
                } else {
                    self.streamingDuration = "00:00"
                }
            }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - Combine Bindings

    private func bindCameraService() {
        cameraService.errorSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.showError(error)
            }
            .store(in: &cancellables)

        cameraService.$isSessionRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.isSessionRunning = running
            }
            .store(in: &cancellables)

        cameraService.$cameraPermissionGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                self?.cameraPermissionGranted = granted
            }
            .store(in: &cancellables)

        cameraService.$audioPermissionGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                self?.audioPermissionGranted = granted
            }
            .store(in: &cancellables)

        cameraService.$availableCameras
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cameras in
                self?.availableCameras = cameras
            }
            .store(in: &cancellables)

        cameraService.$currentFPS
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fps in
                self?.currentFPS = fps
            }
            .store(in: &cancellables)

        cameraService.$thermalState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.thermalState = state
                self?.deviceInfo = DeviceInfo(
                    name: UIDevice.current.name,
                    model: UIDevice.current.model,
                    systemVersion: UIDevice.current.systemVersion,
                    batteryLevel: UIDevice.current.batteryLevel,
                    thermalState: state,
                    availableCameras: self?.availableCameras ?? []
                )
            }
            .store(in: &cancellables)
    }

    private func bindNetworkService() {
        networkService.connectionStateChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .disconnected:
                    self.connectionStatus = .disconnected
                case .listening:
                    self.connectionStatus = .connecting
                case .connecting:
                    self.connectionStatus = .connecting
                case .authenticating:
                    self.connectionStatus = .connecting
                case .connected:
                    let addr = self.networkService.connectedClientAddress ?? "Unknown"
                    self.connectionStatus = .connected(address: addr)
                case .waiting:
                    self.connectionStatus = .connecting
                case .failed(let error):
                    self.connectionStatus = .error(error.localizedDescription)
                }
            }
            .store(in: &cancellables)

        networkService.errorSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.showError(.networkError(error.localizedDescription))
            }
            .store(in: &cancellables)

        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.localIP = self.networkService.localIPAddress ?? "Unavailable"
                self.port = self.networkService.port
                self.formattedBitrate = String(format: "%.1f Mbps", self.networkService.stats.uploadSpeed / 1_000_000)
                self.formattedLatency = String(format: "%.1f ms", self.networkService.stats.latency * 1000)
                self.formattedBytesSent = ByteCountFormatter.string(
                    fromByteCount: Int64(self.networkService.stats.bytesSent),
                    countStyle: .file
                )
            }
            .store(in: &cancellables)
    }

    private func bindStreamManager() {
        streamManager.$streamingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isStreaming = state.isStreaming
                if state.isStreaming && self?.durationTimer == nil {
                    self?.startDurationTimer()
                } else if !state.isStreaming {
                    self?.stopDurationTimer()
                }
            }
            .store(in: &cancellables)

        streamManager.errorSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.showError(error)
            }
            .store(in: &cancellables)
    }

    private func bindConnectionManager() {
        connectionManager.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.connectionStatus = status
            }
            .store(in: &cancellables)

        connectionManager.errorSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.showError(error)
            }
            .store(in: &cancellables)
    }

    private func bindBatteryManager() {
        batteryManager.$batteryLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.batteryLevel = level
                self?.batteryIconName = Self.batteryIcon(for: level)
            }
            .store(in: &cancellables)

        batteryManager.$thermalState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.thermalState = state
            }
            .store(in: &cancellables)
    }

    private func bindSettingsManager() {
        settingsManager.cameraConfigurationChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                guard let self else { return }
                if self.isSessionRunning {
                    Task {
                        try? await self.cameraService.reconfigure(with: config)
                    }
                }
                self.currentPosition = config.selectedCamera
                self.isTorchOn = config.enableTorch
            }
            .store(in: &cancellables)

        settingsManager.networkConfigurationChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.port = config.port
            }
            .store(in: &cancellables)
    }

    // MARK: - Helpers

    private static func batteryIcon(for level: Float) -> String {
        let clamped = max(0, min(level, 1))
        switch clamped {
        case 0..<0.1:
            return "battery.0"
        case 0.1..<0.25:
            return "battery.25"
        case 0.25..<0.5:
            return "battery.50"
        case 0.5..<0.75:
            return "battery.75"
        default:
            return "battery.100"
        }
    }
}
