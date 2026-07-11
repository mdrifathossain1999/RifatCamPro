import SwiftUI
import AVFoundation

// MARK: - Camera Preview (UIViewRepresentable)

struct CameraPreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession?
    var mirrorFront: Bool = true
    var mirrorBack: Bool = false
    var cameraPosition: CameraPosition = .back

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.cornerRadius = 0
        view.videoPreviewLayer.masksToBounds = true
        updateMirroring(on: view)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.videoPreviewLayer.session = session
        updateMirroring(on: uiView)
    }

    private func updateMirroring(on view: PreviewUIView) {
        guard let connection = view.videoPreviewLayer.connection else { return }
        if connection.isVideoMirroringSupported {
            let shouldMirror: Bool = {
                switch cameraPosition {
                case .front: return mirrorFront
                case .back: return mirrorBack
                }
            }()
            connection.isVideoMirrored = shouldMirror
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - Full Camera Preview with Overlays

struct CameraPreviewView: View {
    let session: AVCaptureSession?
    var cameraPosition: CameraPosition = .back
    var mirrorFront: Bool = true
    var mirrorBack: Bool = false
    var onZoomChanged: ((CGFloat) -> Void)?
    var onFocusAt: ((CGPoint) -> Void)?
    @Binding var zoomFactor: CGFloat

    @State private var focusPoint: CGPoint?
    @State private var focusScale: CGFloat = 0.6
    @State private var focusOpacity: Double = 0
    @State private var lastZoom: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewLayerView(
                    session: session,
                    mirrorFront: mirrorFront,
                    mirrorBack: mirrorBack,
                    cameraPosition: cameraPosition
                )
                .clipped()

                gradientOverlay

                focusIndicator
                    .position(focusPoint ?? .init(x: geometry.size.width / 2, y: geometry.size.height / 2))
                    .opacity(focusOpacity)
                    .scaleEffect(focusScale)

                zoomIndicator
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .gesture(pinchGesture)
            .gesture(tapGesture(in: geometry.size))
        }
    }

    // MARK: - Gradient Overlay

    private var gradientOverlay: some View {
        VStack {
            LinearGradient(
                colors: [.black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)

            Spacer()

            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 140)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Focus Indicator

    private var focusIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: 72, height: 72)

            Circle()
                .fill(.white.opacity(0.15))
                .frame(width: 8, height: 8)
        }
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .allowsHitTesting(false)
    }

    // MARK: - Zoom Indicator

    private var zoomIndicator: some View {
        VStack {
            Spacer()
            if zoomFactor > 1.01 {
                Text(String(format: "%.1fx", zoomFactor))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .padding(.bottom, 16)
            }
        }
        .animation(.spring(response: 0.3), value: zoomFactor > 1.01)
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newZoom = lastZoom * value.magnification
                let clamped = max(1.0, min(newZoom, 10.0))
                zoomFactor = clamped
                onZoomChanged?(clamped)
            }
            .onEnded { _ in
                lastZoom = zoomFactor
            }
    }

    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    focusPoint = value.location
                    focusOpacity = 1.0
                    focusScale = 1.0
                }

                onFocusAt?(value.location)

                withAnimation(.easeOut(duration: 0.8).delay(0.4)) {
                    focusOpacity = 0
                    focusScale = 1.4
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    focusPoint = nil
                    focusScale = 0.6
                    focusOpacity = 0
                }
            }
    }
}
