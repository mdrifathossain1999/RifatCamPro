import Foundation
import Combine
import SwiftUI
import Vision
import AVFoundation
import Network

@Observable
@MainActor
final class PairingViewModel {

    // MARK: - Dependencies

    let networkService: NetworkService
    let connectionManager: ConnectionManager
    let bonjourService: BonjourService
    let securityService: SecurityService
    let settingsManager: SettingsManager

    // MARK: - QR Code Display

    var qrCodeImage: UIImage?
    var pairingString: String = ""
    var isGeneratingQR = false

    // MARK: - Manual Entry

    var manualHost: String = ""
    var manualPort: String = "4747"
    var manualPassword: String = ""

    // MARK: - QR Scanner

    var isScanning = false
    var scanRegionFrame: CGRect = .zero
    private var captureSession: AVCaptureSession?
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Discovered Devices

    var discoveredDevices: [DiscoveredDevice] = []
    var isBrowsing = false

    // MARK: - Connection State

    var connectionStatus: ConnectionStatus = .disconnected
    var isConnecting = false
    var connectionProgressMessage: String = ""

    // MARK: - Validation

    var isHostValid: Bool = true
    var isPortValid: Bool = true
    var isFormValid: Bool = false
    var validationMessage: String = ""

    // MARK: - UI State

    var showErrorAlert = false
    var errorTitle: String = ""
    var errorMessage: String = ""
    var showPairingCode = false
    var pairingSuccess = false
    var selectedDevice: DiscoveredDevice?

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        networkService: NetworkService,
        connectionManager: ConnectionManager,
        bonjourService: BonjourService,
        securityService: SecurityService,
        settingsManager: SettingsManager
    ) {
        self.networkService = networkService
        self.connectionManager = connectionManager
        self.bonjourService = bonjourService
        self.securityService = securityService
        self.settingsManager = settingsManager

        let netConfig = settingsManager.currentSettings.network
        manualPort = "\(netConfig.port)"

        bindBonjourService()
        bindConnectionManager()
    }

    deinit {
        stopScanning()
        bonjourService.stop()
    }

    // MARK: - QR Code Generation

    func generatePairingQR() {
        isGeneratingQR = true
        defer { isGeneratingQR = false }

        let netConfig = settingsManager.currentSettings.network
        let ip = networkService.localIPAddress ?? ""
        let password = netConfig.enablePasswordProtection ? netConfig.password : ""

        guard !ip.isEmpty else {
            showError(.networkError("No WiFi IP address detected. Connect to a WiFi network first."))
            return
        }

        let payload = QRCodeGenerator.PairingPayload(
            ip: ip,
            port: netConfig.port,
            password: password,
            proto: "tcp"
        )

        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            showError(.networkError("Failed to encode pairing data"))
            return
        }

        pairingString = jsonString
        qrCodeImage = QRCodeGenerator.generateQR(from: jsonString)

        guard qrCodeImage != nil else {
            showError(.networkError("Failed to generate QR code image"))
            return
        }

        showPairingCode = true
    }

    func generatePairingString() -> String? {
        let netConfig = settingsManager.currentSettings.network
        let ip = networkService.localIPAddress ?? ""
        let password = netConfig.enablePasswordProtection ? netConfig.password : ""

        return QRCodeGenerator.generatePairingString(
            ip: ip,
            port: netConfig.port,
            password: password,
            proto: "tcp"
        )
    }

    // MARK: - Manual Connection

    func validateForm() {
        validateHost()
        validatePort()
        isFormValid = isHostValid && isPortValid && !manualHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func validateHost() {
        let trimmed = manualHost.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            isHostValid = false
            validationMessage = "Host cannot be empty"
            return
        }

        if let _ = IPv4Address(trimmed) {
            isHostValid = true
        } else if let _ = IPv6Address(trimmed) {
            isHostValid = true
        } else {
            let hostPattern = #"^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$"#
            if trimmed.range(of: hostPattern, options: .regularExpression) != nil {
                isHostValid = true
            } else {
                isHostValid = false
                validationMessage = "Invalid host address"
            }
        }
    }

    private func validatePort() {
        guard let portValue = UInt16(manualPort), portValue > 0, portValue <= 65535 else {
            isPortValid = false
            validationMessage = "Port must be between 1 and 65535"
            return
        }
        isPortValid = true
    }

    func manualConnect() async {
        validateForm()
        guard isFormValid else { return }

        let host = manualHost.trimmingCharacters(in: .whitespaces)
        guard let portValue = UInt16(manualPort) else {
            showError(.networkError("Invalid port number"))
            return
        }

        await connectToHost(host: host, port: portValue, password: manualPassword)
    }

    // MARK: - Connection

    func connectToHost(host: String, port: UInt16, password: String) async {
        isConnecting = true
        connectionProgressMessage = "Connecting to \(host):\(port)..."
        connectionStatus = .connecting

        var config = settingsManager.currentSettings.network
        config.port = port
        if !password.isEmpty {
            config.password = password
            config.enablePasswordProtection = true
        }
        settingsManager.networkConfiguration = config

        let target = ConnectionTarget.manual(address: host, port: port)
        connectionManager.connect(to: target)

        // Connection result is observed via bindConnectionManager()
    }
    func connectToDevice(_ device: DiscoveredDevice) async {
        selectedDevice = device

        if device.isPasswordProtected {
            connectionStatus = .passwordRequired
            await connectToHost(host: device.host, port: device.port, password: manualPassword)
        } else {
            await connectToHost(host: device.host, port: device.port, password: "")
        }
    }

    func disconnect() {
        connectionManager.disconnect()
        connectionStatus = .disconnected
        pairingSuccess = false
    }

    // MARK: - QR Code Scanning

    func startScanning() async {
        let hasPermission = await checkCameraPermission()
        guard hasPermission else {
            showError(.cameraAccessDenied)
            return
        }

        let session = AVCaptureSession()
        self.captureSession = session

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showError(.cameraNotFound)
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(nil, queue: DispatchQueue(label: "com.rifatcam.qrscanner"))

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        isScanning = true
        session.startRunning()

        processVideoFrames(from: output)
    }

    func stopScanning() {
        isScanning = false
        captureSession?.stopRunning()
        captureSession = nil
    }

    private func checkCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func processVideoFrames(from output: AVCaptureVideoDataOutput) {
        let sampleBufferQueue = DispatchQueue(label: "com.rifatcam.qrscanner.buffer")

        let delegate = QRScannerDelegate { [weak self] scannedString in
            Task { @MainActor [weak self] in
                self?.handleScannedQRCode(scannedString)
            }
        }

        let wrapper = QRScannerDelegateWrapper(delegate: delegate)
        output.setSampleBufferDelegate(wrapper, queue: sampleBufferQueue)
        objc_setAssociatedObject(output, "qrDelegate", wrapper, .OBJC_ASSOCIATION_RETAIN)
    }

    func handleScannedQRCode(_ jsonString: String) {
        guard isScanning else { return }
        stopScanning()

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = json["ip"] as? String,
              let port = json["port"] as? UInt16 else {
            showError(.networkError("Invalid QR code format"))
            return
        }

        let password = json["password"] as? String ?? ""

        manualHost = host
        manualPort = "\(port)"
        manualPassword = password
        validateForm()

        Task {
            await connectToHost(host: host, port: port, password: password)
        }
    }

    // MARK: - Bonjour Browsing

    func startBrowsing() {
        guard !bonjourService.isBrowsing else { return }
        bonjourService.start()
        isBrowsing = true
    }

    func stopBrowsing() {
        bonjourService.stop()
        isBrowsing = false
    }

    func toggleBrowsing() {
        if isBrowsing {
            stopBrowsing()
        } else {
            startBrowsing()
        }
    }

    // MARK: - Error Handling

    func showError(_ error: AppError) {
        errorTitle = error.title
        errorMessage = error.message
        showErrorAlert = true
    }

    func showError(_ error: SecurityError) {
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

    private func bindBonjourService() {
        bonjourService.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.discoveredDevices = devices
            }
            .store(in: &cancellables)

        bonjourService.$isBrowsing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] browsing in
                self?.isBrowsing = browsing
            }
            .store(in: &cancellables)

        bonjourService.deviceFoundSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                if let index = self?.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                    self?.discoveredDevices[index] = device
                } else {
                    self?.discoveredDevices.append(device)
                }
            }
            .store(in: &cancellables)

        bonjourService.deviceLostSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceId in
                self?.discoveredDevices.removeAll { $0.id == deviceId }
            }
            .store(in: &cancellables)

        bonjourService.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.showError(.networkError(error.localizedDescription))
            }
            .store(in: &cancellables)
    }

    private func bindConnectionManager() {
        connectionManager.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.connectionStatus = status
                if status.isConnected {
                    self?.isConnecting = false
                    self?.pairingSuccess = true
                }
            }
            .store(in: &cancellables)

        connectionManager.errorOccurred
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.isConnecting = false
                self?.showError(.networkError(error.message))
            }
            .store(in: &cancellables)
    }
}

// MARK: - QR Scanner Delegate

private final class QRScannerDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let onCodeScanned: (String) -> Void
    private var hasDetected = false

    init(onCodeScanned: @escaping (String) -> Void) {
        self.onCodeScanned = onCodeScanned
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !hasDetected else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest { [weak self] request, error in
            guard let self else { return }
            guard error == nil else { return }

            if let results = request.results as? [VNBarcodeObservation] {
                for observation in results {
                    guard let payload = observation.payloadStringValue else { continue }
                    self.hasDetected = true
                    self.onCodeScanned(payload)
                    return
                }
            }
        }

        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }
}

// MARK: - Wrapper for Retention

private final class QRScannerDelegateWrapper: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let delegate: QRScannerDelegate

    init(delegate: QRScannerDelegate) {
        self.delegate = delegate
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        delegate.captureOutput(output, didOutput: sampleBuffer, from: connection)
    }
}
