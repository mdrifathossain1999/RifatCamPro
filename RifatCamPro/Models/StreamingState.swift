import Foundation
import AVFoundation

struct StreamingState: Sendable {
    var isStreaming: Bool = false
    var codec: StreamingCodec = .h264
    var resolution: VideoResolution = .hd1080
    var frameRate: Int = 30
    var bitrate: Int = 4_000_000
    var framesEncoded: UInt64 = 0
    var framesDropped: UInt64 = 0
    var startTime: Date?
    var adaptiveBitrateEnabled: Bool = true
    
    var duration: TimeInterval {
        guard let startTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }
    
    var formattedDuration: String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var dropRate: Double {
        guard framesEncoded > 0 else { return 0 }
        return Double(framesDropped) / Double(framesEncoded) * 100
    }
}

enum StreamEventType: String, Sendable {
    case started
    case stopped
    case paused
    case resumed
    case error
    case clientConnected
    case clientDisconnected
    case codecChanged
    case resolutionChanged
    case bitrateAdjusted
}

struct StreamEvent: Identifiable, Sendable {
    let id = UUID()
    let type: StreamEventType
    let message: String
    let timestamp: Date
    
    init(type: StreamEventType, message: String) {
        self.type = type
        self.message = message
        self.timestamp = Date()
    }
}

struct DeviceInfo: Sendable {
    let name: String
    let model: String
    let systemVersion: String
    let batteryLevel: Float
    let thermalState: ThermalState
    let availableCameras: [CameraInfo]
    
    var displayInfo: String {
        "\(model) - iOS \(systemVersion)"
    }
}

struct CameraInfo: Identifiable, Sendable {
    let id: String
    let position: CameraPosition
    let deviceType: AVCaptureDevice.DeviceType
    let supportsHDR: Bool
    let maxResolution: VideoResolution
    let maxFrameRate: Int
    
    var displayName: String {
        switch deviceType {
        case .builtInTripleCamera: return "Triple Camera"
        case .builtInDualCamera: return "Dual Camera"
        case .builtInUltraWideCamera: return "Ultra Wide"
        case .builtInWideAngleCamera: return "Wide Angle"
        case .builtInTelephotoCamera: return "Telephoto"
        default: return position.displayName
        }
    }
}

enum ThermalState: String, Sendable {
    case nominal
    case fair
    case serious
    case critical
    
    var displayName: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Overheating"
        }
    }
    
    var colorName: String {
        switch self {
        case .nominal: return "green"
        case .fair: return "yellow"
        case .serious: return "orange"
        case .critical: return "red"
        }
    }
}
