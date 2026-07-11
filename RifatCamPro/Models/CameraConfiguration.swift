import Foundation
import AVFoundation

struct CameraConfiguration: Codable, Sendable {
    var resolution: VideoResolution = .hd1080
    var frameRate: Int = 30
    var codec: StreamingCodec = .h264
    var bitrate: Int = 4_000_000
    var enableHDR: Bool = false
    var enableTorch: Bool = false
    var enableAutoFocus: Bool = true
    var manualFocusLensPosition: Float = 0.5
    var zoomFactor: CGFloat = 1.0
    var exposureISO: Float = 100
    var exposureDuration: CMTime = CMTime(value: 1, timescale: 30)
    var whiteBalanceTemperature: CGFloat = 5600
    var mirrorFrontCamera: Bool = true
    var mirrorBackCamera: Bool = false
    var enableAudio: Bool = true
    var enableNoiseSuppression: Bool = true
    var audioMuted: Bool = false
    var watermarkText: String = ""
    var selectedCamera: CameraPosition = .back
}

enum VideoResolution: String, Codable, CaseIterable, Sendable {
    case qvga480 = "480p"
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4K = "4K"
    
    var width: Int {
        switch self {
        case .qvga480: return 640
        case .hd720: return 1280
        case .hd1080: return 1920
        case .uhd4K: return 3840
        }
    }
    
    var height: Int {
        switch self {
        case .qvga480: return 480
        case .hd720: return 720
        case .hd1080: return 1080
        case .uhd4K: return 2160
        }
    }
    
    var size: CGSize {
        CGSize(width: width, height: height)
    }
}

enum StreamingCodec: String, Codable, CaseIterable, Sendable {
    case mjpeg
    case h264
    case hevc
    case webRTC
    case rtsp
    case rtmp
    
    var displayName: String {
        switch self {
        case .mjpeg: return "MJPEG"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .webRTC: return "WebRTC"
        case .rtsp: return "RTSP"
        case .rtmp: return "RTMP"
        }
    }
}

enum CameraPosition: String, Codable, CaseIterable, Sendable {
    case front = "front"
    case back = "back"
    
    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
    
    var displayName: String {
        switch self {
        case .front: return "Front Camera"
        case .back: return "Back Camera"
        }
    }
}
