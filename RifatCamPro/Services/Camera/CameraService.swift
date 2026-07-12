import AVFoundation
import Combine
import SwiftUI

final class CameraService: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let sessionQueue = DispatchQueue(label: "com.rifatcam.camera", qos: .userInteractive)
    private let videoOutputQueue = DispatchQueue(label: "com.rifatcam.video.output", qos: .userInteractive)
    private let audioOutputQueue = DispatchQueue(label: "com.rifatcam.audio.output", qos: .userInteractive)

    var previewSession: AVCaptureSession? { captureSession }
    var currentConfiguration = CameraConfiguration()
    @Published var isSessionRunning = false
    @Published var cameraPermissionGranted = false
    @Published var audioPermissionGranted = false
    @Published var availableCameras: [CameraInfo] = []
    @Published var thermalState: ThermalState = .nominal
    @Published var currentFPS: Double = 0

    let videoSampleBuffer = PassthroughSubject<CMSampleBuffer, Never>()
    let audioSampleBuffer = PassthroughSubject<CMSampleBuffer, Never>()
    let errorSubject = PassthroughSubject<AppError, Never>()

    private var fpsCounter = FPSCounter()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let session = captureSession, session.isRunning {
            sessionQueue.async { session.stopRunning() }
        }
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let cameraGranted: Bool = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        cameraPermissionGranted = cameraGranted

        if !cameraGranted {
            errorSubject.send(.cameraAccessDenied)
            return false
        }

        let audioGranted: Bool = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        audioPermissionGranted = audioGranted

        if !audioGranted {
            errorSubject.send(.audioAccessDenied)
        }

        return true
    }

    func checkPermissions() async {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraStatus {
        case .authorized:
            cameraPermissionGranted = true
        case .notDetermined:
            cameraPermissionGranted = await requestPermissions()
        case .denied, .restricted:
            cameraPermissionGranted = false
            errorSubject.send(.cameraAccessDenied)
        @unknown default:
            cameraPermissionGranted = false
        }

        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch audioStatus {
        case .authorized:
            audioPermissionGranted = true
        case .notDetermined:
            let granted: Bool = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            audioPermissionGranted = granted
        case .denied, .restricted:
            audioPermissionGranted = false
        @unknown default:
            audioPermissionGranted = false
        }
    }

    // MARK: - Session Configuration

    func configureSession(with config: CameraConfiguration) async throws {
        currentConfiguration = config

        guard cameraPermissionGranted else {
            throw AppError.cameraAccessDenied
        }

        discoverCameras()

        let session = AVCaptureSession()
        session.sessionPreset = .high

        try sessionQueue.sync {
            if session.isRunning {
                session.beginConfiguration()

                for input in session.inputs {
                    session.removeInput(input)
                }
                for output in session.outputs {
                    session.removeOutput(output)
                }

                try self.addVideoInput(to: session, position: config.selectedCamera.avPosition)
                self.addVideoOutput(to: session)

                if config.enableAudio && audioPermissionGranted {
                    try self.addAudioInput(to: session)
                    self.addAudioOutput(to: session)
                }

                self.configureVideoOutput(with: config)

                session.commitConfiguration()
            }
        }

        captureSession = session
        try await applyConfiguration(config)
    }

    func startSession() {
        guard let session = captureSession, !session.isRunning else { return }
        sessionQueue.async {
            session.startRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = true
            }
        }
    }

    func stopSession() {
        guard let session = captureSession, session.isRunning else { return }
        sessionQueue.async {
            session.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
        }
    }

    func reconfigure(with config: CameraConfiguration) async throws {
        guard let session = captureSession else {
            try await configureSession(with: config)
            return
        }

        currentConfiguration = config

        guard session.isRunning else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                session.beginConfiguration()

                defer {
                    session.commitConfiguration()
                    continuation.resume()
                }

                let needsInputSwitch: Bool = {
                    guard let currentInput = self.videoInput else { return true }
                    let currentPosition = currentInput.device.position
                    return currentPosition != config.selectedCamera.avPosition
                }()

                if needsInputSwitch {
                    for input in session.inputs where input is AVCaptureDeviceInput {
                        session.removeInput(input)
                    }
                    do {
                        try self.addVideoInput(to: session, position: config.selectedCamera.avPosition)
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                }

                if let videoOut = self.videoOutput {
                    self.configureVideoOutput(with: config, output: videoOut)
                }

                if !config.enableAudio {
                    for input in session.inputs where input is AVCaptureDeviceInput {
                        if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.audio) {
                            session.removeInput(input)
                        }
                    }
                    for output in session.outputs where output is AVCaptureAudioDataOutput {
                        session.removeOutput(output)
                    }
                    self.audioInput = nil
                    self.audioOutput = nil
                } else if config.enableAudio && self.audioInput == nil && self.audioPermissionGranted {
                    do {
                        try self.addAudioInput(to: session)
                        self.addAudioOutput(to: session)
                    } catch {
                        self.errorSubject.send(.configurationFailed(error.localizedDescription))
                    }
                }
            }
        }

        try await applyConfiguration(config)
    }

    // MARK: - Camera Switching

    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = videoDevice?.position == .front ? .back : .front
        let newConfig = currentConfiguration
        currentConfiguration.selectedCamera = newPosition == .front ? .front : .back
        Task { try? await reconfigure(with: currentConfiguration) }
    }

    func switchTo(_ position: CameraPosition) {
        guard position.avPosition != videoDevice?.position else { return }
        currentConfiguration.selectedCamera = position
        Task { try? await reconfigure(with: currentConfiguration) }
    }

    // MARK: - Torch

    func setTorch(on: Bool) {
        guard let device = videoDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = on ? .on : .off
            currentConfiguration.enableTorch = on
        } catch {
            errorSubject.send(.configurationFailed("Torch: \(error.localizedDescription)"))
        }
    }

    // MARK: - Focus

    func setFocus(point: CGPoint, in viewFrame: CGRect) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let focusPoint = CGPoint(
                x: point.y / viewFrame.height,
                y: 1.0 - (point.x / viewFrame.width)
            )

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = focusPoint
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            currentConfiguration.enableAutoFocus = true
        } catch {
            errorSubject.send(.configurationFailed("Focus: \(error.localizedDescription)"))
        }
    }

    func lockFocus(at point: CGPoint) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }

            currentConfiguration.enableAutoFocus = false
        } catch {
            errorSubject.send(.configurationFailed("Focus lock: \(error.localizedDescription)"))
        }
    }

    // MARK: - Zoom

    func setZoom(_ factor: CGFloat) {
        guard let device = videoDevice else { return }
        let clampedFactor = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = clampedFactor
            currentConfiguration.zoomFactor = clampedFactor
        } catch {
            errorSubject.send(.configurationFailed("Zoom: \(error.localizedDescription)"))
        }
    }

    func rampZoom(to factor: CGFloat, rate: Float = 1.0) {
        guard let device = videoDevice else { return }
        let clampedFactor = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.ramp(toVideoZoomFactor: clampedFactor, withRate: rate)
            currentConfiguration.zoomFactor = clampedFactor
        } catch {
            errorSubject.send(.configurationFailed("Zoom ramp: \(error.localizedDescription)"))
        }
    }

    // MARK: - Exposure

    func setExposure(iso: Float) {
        guard let device = videoDevice else { return }
        let clampedISO = max(device.activeFormat.minISO, min(iso, device.activeFormat.maxISO))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureModeCustom(
                duration: device.exposureDuration,
                iso: clampedISO,
                completionHandler: nil
            )
            currentConfiguration.exposureISO = clampedISO
        } catch {
            errorSubject.send(.configurationFailed("Exposure: \(error.localizedDescription)"))
        }
    }

    func setExposureMode(_ mode: AVCaptureDevice.ExposureMode) {
        guard let device = videoDevice else { return }
        guard device.isExposureModeSupported(mode) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.exposureMode = mode
        } catch {
            errorSubject.send(.configurationFailed("Exposure mode: \(error.localizedDescription)"))
        }
    }

    // MARK: - White Balance

    func setWhiteBalance(temperature: CGFloat) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.whiteBalanceMode = .locked
            currentConfiguration.whiteBalanceTemperature = temperature
        } catch {
            errorSubject.send(.configurationFailed("White balance: \(error.localizedDescription)"))
        }
    }

    func setWhiteBalanceMode(_ mode: AVCaptureDevice.WhiteBalanceMode) {
        guard let device = videoDevice else { return }
        guard device.isWhiteBalanceModeSupported(mode) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.whiteBalanceMode = mode
        } catch {
            errorSubject.send(.configurationFailed("WB mode: \(error.localizedDescription)"))
        }
    }

    // MARK: - HDR

    func setHDR(_ enabled: Bool) {
        guard let device = videoDevice else { return }
        if enabled && !device.activeFormat.isVideoHDRSupported {
            errorSubject.send(.configurationFailed("HDR not supported on current format"))
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = !enabled
                device.isVideoHDREnabled = enabled
            }
            currentConfiguration.enableHDR = enabled
        } catch {
            errorSubject.send(.configurationFailed("HDR: \(error.localizedDescription)"))
        }
    }

    // MARK: - Photo Capture

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        guard let session = captureSession else {
            completion(nil)
            return
        }

        let photoOutput = AVCapturePhotoOutput()
        guard session.canAddOutput(photoOutput) else {
            completion(nil)
            return
        }
        session.addOutput(photoOutput)

        var settings = AVCapturePhotoSettings()
        settings.flashMode = currentConfiguration.enableTorch ? .on : .off
        if let format = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: format])
            settings.flashMode = currentConfiguration.enableTorch ? .on : .off
        }

        let delegate = PhotoCaptureDelegate { [weak self] image in
            DispatchQueue.main.async {
                completion(image)
            }
            if let session = self?.captureSession, let queue = self?.sessionQueue {
                queue.async {
                    session.removeOutput(photoOutput)
                }
            }
        }

        let delegateKey = Unmanaged.passRetained(delegate).toOpaque()
        objc_setAssociatedObject(photoOutput, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    // MARK: - Configuration Application

    private func applyConfiguration(_ config: CameraConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                guard let device = self.videoDevice else {
                    continuation.resume(throwing: AppError.cameraNotFound)
                    return
                }
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }

                    let preferredFPS: Float64 = Float64(config.frameRate)
                    let targetDuration = CMTimeMake(value: 1, timescale: CMTimeScale(preferredFPS))

                    var bestFormat: AVCaptureDevice.Format?
                    var bestDimensions = CMVideoDimensions(width: 0, height: 0)

                    for format in device.formats {
                        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let maxFPS = format.videoSupportedFrameRateRanges.max { $0.maxFrameRate < $1.maxFrameRate }

                        let resolutionMatch = dimensions.width <= Int32(config.resolution.width)
                            && dimensions.height <= Int32(config.resolution.height)
                        let fpsSupported = maxFPS.map { $0.maxFrameRate >= preferredFPS } ?? false

                        if resolutionMatch && fpsSupported {
                            if dimensions.width > bestDimensions.width
                                || (dimensions.width == bestDimensions.width && dimensions.height >= bestDimensions.height) {
                                bestFormat = format
                                bestDimensions = dimensions
                            }
                        }
                    }

                    if let format = bestFormat {
                        device.activeFormat = format
                        device.activeVideoMinFrameDuration = targetDuration
                        device.activeVideoMaxFrameDuration = targetDuration
                    } else {
                        let targetWidth = config.resolution.width
                        let targetHeight = config.resolution.height

                        for format in device.formats {
                            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                            if Int(dimensions.width) >= targetWidth && Int(dimensions.height) >= targetHeight {
                                device.activeFormat = format
                                device.activeVideoMinFrameDuration = targetDuration
                                device.activeVideoMaxFrameDuration = targetDuration
                                break
                            }
                        }
                    }

                    if config.zoomFactor > 1.0 && device.activeFormat.videoMaxZoomFactor >= config.zoomFactor {
                        device.videoZoomFactor = config.zoomFactor
                    }

                    if device.hasTorch && device.isTorchAvailable {
                        device.torchMode = config.enableTorch ? .on : .off
                    }

                    if device.activeFormat.isVideoHDRSupported {
                        device.automaticallyAdjustsVideoHDREnabled = !config.enableHDR
                        device.isVideoHDREnabled = config.enableHDR
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: AppError.configurationFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Camera Discovery

    private func discoverCameras() {
        var cameras: [CameraInfo] = []

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInUltraWideCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        for device in discoverySession.devices {
            let position: CameraPosition = device.position == .front ? .front : .back
            let maxResolution = bestResolution(for: device)
            let maxFPS = bestFrameRate(for: device)
            let supportsHDR = device.activeFormat.isVideoHDRSupported

            let info = CameraInfo(
                id: device.uniqueID,
                position: position,
                deviceType: device.deviceType,
                supportsHDR: supportsHDR,
                maxResolution: maxResolution,
                maxFrameRate: maxFPS
            )
            cameras.append(info)
        }

        availableCameras = cameras
    }

    private func bestResolution(for device: AVCaptureDevice) -> VideoResolution {
        var maxWidth: Int32 = 0
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if dims.width > maxWidth {
                maxWidth = dims.width
            }
        }
        if maxWidth >= 3840 { return .uhd4K }
        if maxWidth >= 1920 { return .hd1080 }
        if maxWidth >= 1280 { return .hd720 }
        return .qvga480
    }

    private func bestFrameRate(for device: AVCaptureDevice) -> Int {
        var maxRate: Float64 = 0
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate > maxRate {
                    maxRate = range.maxFrameRate
                }
            }
        }
        return Int(maxRate)
    }

    // MARK: - Input/Output Setup

    private func addVideoInput(to session: AVCaptureSession, position: AVCaptureDevice.Position) throws {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
            .builtInUltraWideCamera
        ]

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        )

        guard let device = discoverySession.devices.first else {
            throw AppError.cameraNotFound
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AppError.configurationFailed("Cannot add video input")
        }

        session.addInput(input)
        videoInput = input
        videoDevice = device
    }

    private func addVideoOutput(to session: AVCaptureSession) {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: videoOutputQueue)

        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        videoOutput = output
    }

    private func addAudioInput(to session: AVCaptureSession) throws {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AppError.audioAccessDenied
        }

        let device = AVCaptureDevice.default(for: .audio)!
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AppError.configurationFailed("Cannot add audio input")
        }

        session.addInput(input)
        audioInput = input
    }

    private func addAudioOutput(to session: AVCaptureSession) {
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioOutputQueue)

        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        audioOutput = output
    }

    private func configureVideoOutput(with config: CameraConfiguration, output: AVCaptureVideoDataOutput? = nil) {
        let out = output ?? videoOutput
        guard let out else { return }

        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        if let connection = out.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                let shouldMirror: Bool = {
                    if self.videoDevice?.position == .front {
                        return config.mirrorFrontCamera
                    }
                    return config.mirrorBackCamera
                }()
                connection.isVideoMirrored = shouldMirror
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }

    // MARK: - AVCaptureOutput Delegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            let fps = fpsCounter.tick()
            if fps > 0 {
                DispatchQueue.main.async {
                    self.currentFPS = fps
                }
            }
            videoSampleBuffer.send(sampleBuffer)
        } else if output === audioOutput {
            audioSampleBuffer.send(sampleBuffer)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Frame dropped due to late arrival â€” no action needed
    }

    // MARK: - Thermal State

    @objc private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        let mapped: ThermalState = {
            switch state {
            case .nominal: return .nominal
            case .fair: return .fair
            case .serious: return .serious
            case .critical: return .critical
            @unknown default: return .nominal
            }
        }()
        thermalState = mapped

        if mapped == .serious || mapped == .critical {
            reduceQualityForThermal()
        }
    }

    private func reduceQualityForThermal() {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let maxFPS: Float64 = thermalState == .critical ? 24 : 24
            device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: CMTimeScale(maxFPS))

            if device.activeFormat.videoMaxZoomFactor > 1.0 {
                let currentZoom = device.videoZoomFactor
                let reducedZoom = max(1.0, currentZoom * 0.9)
                device.videoZoomFactor = reducedZoom
            }
        } catch {
            errorSubject.send(.configurationFailed("Thermal reduction: \(error.localizedDescription)"))
        }
    }

    // MARK: - Utility

    func currentVideoDevice() -> AVCaptureDevice? {
        videoDevice
    }

    func availableZoomRange() -> ClosedRange<CGFloat> {
        guard let device = videoDevice else { return 1.0...1.0 }
        return 1.0...device.activeFormat.videoMaxZoomFactor
    }

    func availableISORange() -> ClosedRange<Float> {
        guard let device = videoDevice else { return 100...100 }
        return device.activeFormat.minISO...device.activeFormat.maxISO
    }
}

// MARK: - Photo Capture Delegate

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(nil)
            return
        }
        completion(image)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if error != nil {
            completion(nil)
        }
    }
}

// MARK: - FPS Counter

struct FPSCounter {
    private var frameCount = 0
    private var lastTimestamp: CFAbsoluteTime = 0

    mutating func tick() -> Double {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastTimestamp
        if elapsed >= 1.0 {
            let fps = Double(frameCount) / elapsed
            frameCount = 0
            lastTimestamp = now
            return fps
        }
        return lastTimestamp > 0 ? Double(frameCount) / elapsed : 0
    }
}
