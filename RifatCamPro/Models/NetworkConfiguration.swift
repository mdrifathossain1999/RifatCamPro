import Foundation

struct NetworkConfiguration: Codable, Sendable {
    var port: UInt16 = 4747
    var password: String = ""
    var enablePasswordProtection: Bool = false
    var enableBonjour: Bool = true
    var autoDetectIP: Bool = true
    var customIPAddress: String = ""
    var enableTLS: Bool = false
    var connectionTimeout: TimeInterval = 10
    var maxConnections: Int = 1
}

enum ConnectionStatus: Sendable {
    case disconnected
    case connecting
    case connected(address: String)
    case error(String)
    case passwordRequired
    
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
    
    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected(let addr): return "Connected to \(addr)"
        case .error(let msg): return "Error: \(msg)"
        case .passwordRequired: return "Password Required"
        }
    }
    
    var iconName: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .connecting: return "wifi.exclamationmark"
        case .connected: return "wifi"
        case .error: return "exclamationmark.triangle"
        case .passwordRequired: return "lock"
        }
    }
}

enum StreamingProtocol: String, Codable, CaseIterable, Sendable {
    case mjpeg
    case h264
    case hevc
    case webRTC
    case rtsp
    case rtmp
    
    var defaultPort: UInt16 {
        switch self {
        case .mjpeg: return 4747
        case .h264: return 4748
        case .hevc: return 4749
        case .webRTC: return 4750
        case .rtsp: return 554
        case .rtmp: return 1935
        }
    }
}

struct NetworkStats: Codable, Sendable {
    var localIP: String = "Detecting..."
    var port: UInt16 = 4747
    var bitrate: Double = 0
    var latency: Double = 0
    var fps: Double = 0
    var bytesSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var connectionStatus: ConnectionStatus = .disconnected
    var uptime: TimeInterval = 0
    
    var formattedBitrate: String {
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", bitrate / 1_000_000)
        } else if bitrate >= 1_000 {
            return String(format: "%.0f Kbps", bitrate / 1_000)
        }
        return String(format: "%.0f bps", bitrate)
    }
    
    var formattedLatency: String {
        String(format: "%.1f ms", latency)
    }
    
    var formattedBytesSent: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesSent), countStyle: .file)
    }
}
