import Foundation

struct AppSettings: Codable, Sendable {
    var camera: CameraConfiguration = CameraConfiguration()
    var network: NetworkConfiguration = NetworkConfiguration()
    var theme: AppTheme = .dark
    var backgroundStreaming: Bool = true
    var autoConnect: Bool = false
    var showNetworkStats: Bool = true
    var enableNotifications: Bool = true
    var streamQuality: StreamQuality = .balanced
    
    static var `default`: AppSettings {
        AppSettings()
    }
}

enum AppTheme: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case system
    
    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
}

enum StreamQuality: String, Codable, CaseIterable, Sendable {
    case ultraLow
    case low
    case balanced
    case high
    case ultraHigh
    
    var displayName: String {
        switch self {
        case .ultraLow: return "Ultra Low"
        case .low: return "Low"
        case .balanced: return "Balanced"
        case .high: return "High"
        case .ultraHigh: return "Ultra High"
        }
    }
    
    var bitrateMultiplier: Double {
        switch self {
        case .ultraLow: return 0.25
        case .low: return 0.5
        case .balanced: return 1.0
        case .high: return 1.5
        case .ultraHigh: return 2.0
        }
    }
    
    var description: String {
        switch self {
        case .ultraLow: return "Minimum bandwidth usage"
        case .low: return "Good for slow connections"
        case .balanced: return "Best balance of quality and speed"
        case .high: return "High quality streaming"
        case .ultraHigh: return "Maximum quality"
        }
    }
}

enum AppError: Error, Identifiable, Sendable {
    case cameraAccessDenied
    case audioAccessDenied
    case cameraNotFound
    case configurationFailed(String)
    case networkError(String)
    case streamingError(String)
    case encodingError(String)
    case connectionTimeout
    case invalidPassword
    case serverUnavailable
    case portAlreadyInUse
    case tlsError(String)
    
    var id: String {
        switch self {
        case .cameraAccessDenied: return "camera_access"
        case .audioAccessDenied: return "audio_access"
        case .cameraNotFound: return "camera_not_found"
        case .configurationFailed: return "config_failed"
        case .networkError: return "network_error"
        case .streamingError: return "streaming_error"
        case .encodingError: return "encoding_error"
        case .connectionTimeout: return "timeout"
        case .invalidPassword: return "invalid_password"
        case .serverUnavailable: return "server_unavailable"
        case .portAlreadyInUse: return "port_in_use"
        case .tlsError: return "tls_error"
        }
    }
    
    var title: String {
        switch self {
        case .cameraAccessDenied: return "Camera Access Denied"
        case .audioAccessDenied: return "Audio Access Denied"
        case .cameraNotFound: return "Camera Not Found"
        case .configurationFailed: return "Configuration Error"
        case .networkError: return "Network Error"
        case .streamingError: return "Streaming Error"
        case .encodingError: return "Encoding Error"
        case .connectionTimeout: return "Connection Timeout"
        case .invalidPassword: return "Invalid Password"
        case .serverUnavailable: return "Server Unavailable"
        case .portAlreadyInUse: return "Port In Use"
        case .tlsError: return "TLS Error"
        }
    }
    
    var message: String {
        switch self {
        case .cameraAccessDenied: return "Please enable camera access in Settings > Privacy & Security > Camera."
        case .audioAccessDenied: return "Please enable microphone access in Settings > Privacy & Security > Microphone."
        case .cameraNotFound: return "No compatible camera was found on this device."
        case .configurationFailed(let detail): return "Failed to configure camera: \(detail)"
        case .networkError(let detail): return "Network error: \(detail)"
        case .streamingError(let detail): return "Streaming error: \(detail)"
        case .encodingError(let detail): return "Encoding error: \(detail)"
        case .connectionTimeout: return "The connection attempt timed out."
        case .invalidPassword: return "The password you entered is incorrect."
        case .serverUnavailable: return "The streaming server is unavailable."
        case .portAlreadyInUse: return "The specified port is already in use."
        case .tlsError(let detail): return "TLS error: \(detail)"
        }
    }
}
