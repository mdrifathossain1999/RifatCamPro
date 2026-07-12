import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {

    let onCodeScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCodeScanned = { code in
            HapticManager.lightTap()
            onCodeScanned(code)
            dismiss()
        }
        controller.onCancel = {
            dismiss()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

// MARK: - QR Scanner ViewController

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var onCodeScanned: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isScanning = false
    private var hasDetected = false

    // MARK: - UI Elements

    private let torchButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = 24
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        button.tintColor = .white
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let instructionLabel: UILabel = {
        let label = UILabel()
        label.text = "Align QR code within the frame"
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 4
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        return label
    }()

    private let scanningCornerView = ScanningCornerView()

    private var torchOn = false {
        didSet { updateTorchIcon() }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCaptureSession()
        setupUI()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds

        let scanSize: CGFloat = min(view.bounds.width * 0.65, 280)
        let scanRect = CGRect(
            x: (view.bounds.width - scanSize) / 2,
            y: (view.bounds.height - scanSize) / 2.5,
            width: scanSize,
            height: scanSize
        )
        scanningCornerView.frame = scanRect
        if let metadataOutput = captureSession?.outputs.first(where: { $0 is AVCaptureMetadataOutput }) as? AVCaptureMetadataOutput {
            metadataOutput.rectOfInterest = previewLayer?.metadataOutputRectConverted(fromLayerRect: scanRect) ?? .zero
        }
        if let connection = captureSession?.outputs.first?.connections.first,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = UIDevice.current.orientation.videoOrientation ?? .portrait
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
        scanningCornerView.startAnimation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
        scanningCornerView.stopAnimation()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - Capture Session

    private func setupCaptureSession() {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        self.captureSession = session

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showCameraError()
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
    }

    private func startSession() {
        guard !isScanning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
            self?.isScanning = true
        }
    }

    private func stopSession() {
        guard isScanning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.isScanning = false
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDetected,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let stringValue = object.stringValue else { return }

        hasDetected = true

        var transformedObject = previewLayer?.transformedMetadataObject(for: object)
        if let videoPreviewLayer = previewLayer {
            let convertedRect = videoPreviewLayer.metadataOutputRectConverted(fromLayerRect: object.bounds)
            _ = convertedRect
        }

        onCodeScanned?(stringValue)
    }

    // MARK: - UI Setup

    private func setupUI() {
        let dimOverlay = UIView()
        dimOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        dimOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimOverlay)
        view.addSubview(scanningCornerView)
        view.addSubview(instructionLabel)
        view.addSubview(torchButton)
        view.addSubview(cancelButton)

        torchButton.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            dimOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            dimOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            instructionLabel.bottomAnchor.constraint(equalTo: scanningCornerView.topAnchor, constant: -24),
            instructionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            instructionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            torchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            torchButton.bottomAnchor.constraint(equalTo: scanningCornerView.topAnchor, constant: -48),
            torchButton.widthAnchor.constraint(equalToConstant: 48),
            torchButton.heightAnchor.constraint(equalToConstant: 48),

            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancelButton.widthAnchor.constraint(equalToConstant: 48),
            cancelButton.heightAnchor.constraint(equalToConstant: 48),
        ])

        view.bringSubviewToFront(torchButton)
        view.bringSubviewToFront(cancelButton)
        view.bringSubviewToFront(instructionLabel)
        view.bringSubviewToFront(scanningCornerView)
    }

    // MARK: - Actions

    @objc private func torchTapped() {
        torchOn.toggle()
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }

        try? device.lockForConfiguration()
        device.torchMode = torchOn ? .on : .off
        device.unlockForConfiguration()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    private func updateTorchIcon() {
        let iconName = torchOn ? "bolt.fill" : "bolt.slash.fill"
        torchButton.setImage(UIImage(systemName: iconName), for: .normal)
    }

    private func showCameraError() {
        let label = UILabel()
        label.text = "Camera not available"
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}

// MARK: - Scanning Corner Animation View

final class ScanningCornerView: UIView {

    private let cornerLength: CGFloat = 28
    private let cornerWidth: CGFloat = 3
    private let cornerColor = UIColor.systemBlue

    private var topLeftLayer = CAShapeLayer()
    private var topRightLayer = CAShapeLayer()
    private var bottomLeftLayer = CAShapeLayer()
    private var bottomRightLayer = CAShapeLayer()
    private var scanLineLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePaths()
    }

    private func setupLayers() {
        backgroundColor = .clear

        let cornerLayers = [topLeftLayer, topRightLayer, bottomLeftLayer, bottomRightLayer]
        for layer in cornerLayers {
            layer.strokeColor = cornerColor.cgColor
            layer.lineWidth = cornerWidth
            layer.lineCap = .round
            layer.fillColor = UIColor.clear.cgColor
            self.layer.addSublayer(layer)
        }

        scanLineLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
        scanLineLayer.lineWidth = 2
        scanLineLayer.fillColor = UIColor.clear.cgColor
        self.layer.addSublayer(scanLineLayer)
    }

    private func updatePaths() {
        let w = bounds.width
        let h = bounds.height
        let cl = cornerLength

        let topLeft = UIBezierPath()
        topLeft.move(to: CGPoint(x: 0, y: cl))
        topLeft.addLine(to: CGPoint(x: 0, y: 0))
        topLeft.addLine(to: CGPoint(x: cl, y: 0))
        topLeftLayer.path = topLeft.cgPath

        let topRight = UIBezierPath()
        topRight.move(to: CGPoint(x: w - cl, y: 0))
        topRight.addLine(to: CGPoint(x: w, y: 0))
        topRight.addLine(to: CGPoint(x: w, y: cl))
        topRightLayer.path = topRight.cgPath

        let bottomLeft = UIBezierPath()
        bottomLeft.move(to: CGPoint(x: 0, y: h - cl))
        bottomLeft.addLine(to: CGPoint(x: 0, y: h))
        bottomLeft.addLine(to: CGPoint(x: cl, y: h))
        bottomLeftLayer.path = bottomLeft.cgPath

        let bottomRight = UIBezierPath()
        bottomRight.move(to: CGPoint(x: w - cl, y: h))
        bottomRight.addLine(to: CGPoint(x: w, y: h))
        bottomRight.addLine(to: CGPoint(x: w, y: h - cl))
        bottomRightLayer.path = bottomRight.cgPath

        let linePath = UIBezierPath()
        linePath.move(to: CGPoint(x: 8, y: 2))
        linePath.addLine(to: CGPoint(x: w - 8, y: 2))
        scanLineLayer.path = linePath.cgPath
        scanLineLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)
    }

    func startAnimation() {
        let animation = CABasicAnimation(keyPath: "position.y")
        animation.fromValue = cornerWidth
        animation.toValue = bounds.height - cornerWidth
        animation.duration = 2.0
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scanLineLayer.add(animation, forKey: "scanLine")

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 1.0
        opacityAnimation.toValue = 0.4
        opacityAnimation.duration = 1.2
        opacityAnimation.autoreverses = true
        opacityAnimation.repeatCount = .infinity
        for cornerLayer in [topLeftLayer, topRightLayer, bottomLeftLayer, bottomRightLayer] {
            cornerLayer.add(opacityAnimation, forKey: "pulse")
        }
    }

    func stopAnimation() {
        scanLineLayer.removeAnimation(forKey: "scanLine")
        for cornerLayer in [topLeftLayer, topRightLayer, bottomLeftLayer, bottomRightLayer] {
            cornerLayer.removeAllAnimations()
        }
    }
}

// MARK: - Haptic Manager

enum HapticManager {

    static func lightTap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func mediumTap() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    static func successNotification() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    static func errorNotification() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }
}

// MARK: - UIDeviceOrientation Extension

extension UIDeviceOrientation {

    var videoOrientation: AVCaptureVideoOrientation? {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }
}
