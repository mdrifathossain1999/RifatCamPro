import SwiftUI

// MARK: - App Info

enum AppInfo {

    static let name = "RifatCam Pro"
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.rifatcam.pro"
    static let version = Bundle.main.appVersion
    static let build = Bundle.main.buildNumber
    static let fullVersion = Bundle.main.fullVersion
    static let websiteURL = URL(string: "https://rifatcam.com")!
    static let supportEmail = "support@rifatcam.com"
    static let privacyPolicyURL = URL(string: "https://rifatcam.com/privacy")!
    static let appStoreID = "0000000000"
}

// MARK: - Default Values

enum DefaultValues {

    static let port: UInt16 = 4747
    static let resolution = VideoResolution.hd1080
    static let frameRate = 30
    static let bitrate = 4_000_000
    static let codec = StreamingCodec.h264
    static let connectionTimeout: TimeInterval = 10
    static let maxConnections = 1
    static let streamQuality = StreamQuality.balanced
    static let batteryLowThreshold: Float = 0.2
    static let thermalWarningThreshold = ThermalState.fair
    static let autoReconnectMaxAttempts = 5
    static let reconnectDelay: TimeInterval = 2.0
    static let heartbeatInterval: TimeInterval = 5.0
    static let statsUpdateInterval: TimeInterval = 1.0
}

// MARK: - Notification Names

extension Notification.Name {

    static let connectionStateChanged = Notification.Name("com.rifatcam.connectionStateChanged")
    static let streamingStateChanged = Notification.Name("com.rifatcam.streamingStateChanged")
    static let settingsDidChange = Notification.Name("com.rifatcam.settingsDidChange")
    static let batteryLevelChanged = Notification.Name("com.rifatcam.batteryLevelChanged")
    static let thermalStateChanged = Notification.Name("com.rifatcam.thermalStateChanged")
    static let deviceDiscovered = Notification.Name("com.rifatcam.deviceDiscovered")
    static let deviceLost = Notification.Name("com.rifatcam.deviceLost")
    static let appDidEnterBackground = Notification.Name("com.rifatcam.didEnterBackground")
    static let appWillEnterForeground = Notification.Name("com.rifatcam.willEnterForeground")
    static let cameraPermissionChanged = Notification.Name("com.rifatcam.cameraPermissionChanged")
}

// MARK: - UserDefaults Keys

enum UserDefaultsKeys {

    static let appSettings = "com.rifatcam.appSettings"
    static let settingsVersion = "com.rifatcam.settingsVersion"
    static let deviceIdentifier = "com.rifatcam.deviceIdentifier"
    static let lastConnectedHost = "com.rifatcam.lastConnectedHost"
    static let lastConnectedPort = "com.rifatcam.lastConnectedPort"
    static let hasCompletedOnboarding = "com.rifatcam.hasCompletedOnboarding"
    static let launchCount = "com.rifatcam.launchCount"
    static let lastLaunchDate = "com.rifatcam.lastLaunchDate"
    static let passwordHash = "com.rifatcam.security.passwordHash"
    static let passwordSalt = "com.rifatcam.security.passwordSalt"
    static let lastStreamingDuration = "com.rifatcam.lastStreamingDuration"
    static let favoriteResolutions = "com.rifatcam.favoriteResolutions"
}

// MARK: - Animation Durations

enum AnimationDuration {

    static let quick: Double = 0.15
    static let normal: Double = 0.3
    static let slow: Double = 0.5
    static let spring: Double = 0.4
    static let springBouncy: Double = 0.5
    static let shimmer: Double = 1.5
    static let pulse: Double = 1.2
    static let fadeTransition: Double = 0.25
    static let slideTransition: Double = 0.35

    static var springAnimation: Animation {
        .spring(duration: spring, bounce: 0.15)
    }

    static var springBouncyAnimation: Animation {
        .spring(duration: springBouncy, bounce: 0.3)
    }

    static var quickAnimation: Animation {
        .easeInOut(duration: quick)
    }

    static var normalAnimation: Animation {
        .easeInOut(duration: normal)
    }
}

// MARK: - Layout Constants

enum Layout {

    static let cornerRadius8: CGFloat = 8
    static let cornerRadius10: CGFloat = 10
    static let cornerRadius12: CGFloat = 12
    static let cornerRadius14: CGFloat = 14
    static let cornerRadius16: CGFloat = 16
    static let cornerRadius20: CGFloat = 20
    static let cornerRadius24: CGFloat = 24

    static let spacing2: CGFloat = 2
    static let spacing4: CGFloat = 4
    static let spacing6: CGFloat = 6
    static let spacing8: CGFloat = 8
    static let spacing10: CGFloat = 10
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32
    static let spacing40: CGFloat = 40
    static let spacing48: CGFloat = 48

    static let paddingSmall: CGFloat = 8
    static let paddingMedium: CGFloat = 16
    static let paddingLarge: CGFloat = 24

    static let iconSizeSmall: CGFloat = 16
    static let iconSizeMedium: CGFloat = 24
    static let iconSizeLarge: CGFloat = 32
    static let iconSizeXL: CGFloat = 48

    static let buttonHeight: CGFloat = 50
    static let buttonHeightCompact: CGFloat = 40
    static let buttonHeightSmall: CGFloat = 34

    static let minimumTouchTarget: CGFloat = 44
    static let maximumContentWidth: CGFloat = 600
    static let qrCodeSize: CGFloat = 220
    static let avatarSize: CGFloat = 48
    static let statusBarHeight: CGFloat = 44

    static let tabBarHeight: CGFloat = 83
    static let navigationBarHeight: CGFloat = 44
    static let toolbarHeight: CGFloat = 44
}

// MARK: - Color Definitions

enum AppColors {

    static let primary = Color.appPrimary
    static let secondary = Color.appSecondary
    static let accent = Color.appAccent
    static let success = Color.appSuccess
    static let warning = Color.appWarning
    static let error = Color.appError
    static let background = Color.appBackground
    static let surface = Color.appSurface

    static let gradientStart = Color(hex: "667EEA")
    static let gradientEnd = Color(hex: "764BA2")

    static let streamingGradientStart = Color(hex: "00B09B")
    static let streamingGradientEnd = Color(hex: "96C93D")

    static let darkOverlay = Color.black.opacity(0.4)
    static let lightOverlay = Color.white.opacity(0.08)

    static let qrBackground = Color.white
    static let qrForeground = Color.black
}

// MARK: - SF Symbol Names

enum SFSymbols {

    enum TabBar {
        static let home = "video.fill"
        static let settings = "gearshape.fill"
        static let streaming = "antenna.radiowaves.left.and.right"
    }

    enum Connection {
        static let connected = "wifi"
        static let disconnected = "wifi.slash"
        static let connecting = "wifi.exclamationmark"
        static let error = "exclamationmark.triangle.fill"
        static let passwordRequired = "lock"
        static let scanning = "qrcode.viewfinder"
        static let bluetooth = "antenna.radiowaves.left.and.right"
    }

    enum Camera {
        static let front = "camera.fill"
        static let back = "camera.fill"
        static let switchCamera = "camera.rotate"
        static let flash = "bolt.fill"
        static let flashOff = "bolt.slash.fill"
        static let focus = "focus"
        static let photo = "camera.viewfinder"
    }

    enum Streaming {
        static let play = "play.fill"
        static let pause = "pause.fill"
        static let stop = "stop.fill"
        static let recording = "record.circle.fill"
        static let quality = "sparkles"
        static let audio = "waveform"
        static let audioMuted = "waveform.slash"
    }

    enum Settings {
        static let resolution = "aspectratio.fill"
        static let frameRate = "film"
        static let bitrate = "gauge.with.dots.needle.67percent"
        static let codec = "doc.plaintext"
        static let network = "network"
        static let security = "lock.shield"
        static let appearance = "paintbrush"
        static let background = "arrow.down.left.and.arrow.up.right"
        static let notifications = "bell"
        static let export = "square.and.arrow.up"
        static let importIcon = "square.and.arrow.down"
        static let reset = "arrow.counterclockwise"
        static let info = "info.circle"
        static let advanced = "wrench.and.screwdriver"
    }

    enum Status {
        static let battery = "battery.100"
        static let thermal = "thermometer"
        static let signal = "signal"
        static let clock = "clock"
    }

    enum Pairing {
        static let qrCode = "qrcode"
        static let scanQR = "qrcode.viewfinder"
        static let manual = "keyboard"
        static let discovered = "network"
        static let addDevice = "plus.circle.fill"
        static let device = "desktopcomputer"
    }

    enum Actions {
        static let connect = "arrow.right.circle.fill"
        static let disconnect = "xmark.circle.fill"
        static let refresh = "arrow.clockwise"
        static let share = "square.and.arrow.up"
        static let copy = "doc.on.doc"
        static let checkmark = "checkmark.circle.fill"
        static let close = "xmark"
    }
}

// MARK: - Bonjour Service

enum BonjourConfig {

    static let serviceType = "_rifatcam._tcp"
    static let domain = "local."
    static let serviceName = "RifatCam Pro"

    static let maxRetryCount = 3
    static let browseTimeout: TimeInterval = 30
    static let resolveTimeout: TimeInterval = 10
}

// MARK: - API Endpoints

enum APIEndpoints {

    static let baseURL = URL(string: "https://api.rifatcam.com/v1")!

    enum Stream {
        static let start = baseURL.appendingPathComponent("stream/start")
        static let stop = baseURL.appendingPathComponent("stream/stop")
        static let status = baseURL.appendingPathComponent("stream/status")
        static let configure = baseURL.appendingPathComponent("stream/configure")
    }

    enum Device {
        static let register = baseURL.appendingPathComponent("device/register")
        static let update = baseURL.appendingPathComponent("device/update")
        static let info = baseURL.appendingPathComponent("device/info")
    }

    enum Auth {
        static let token = baseURL.appendingPathComponent("auth/token")
        static let refresh = baseURL.appendingPathComponent("auth/refresh")
        static let revoke = baseURL.appendingPathComponent("auth/revoke")
    }

    static let healthCheck = baseURL.appendingPathComponent("health")
    static let version = baseURL.appendingPathComponent("version")
}

// MARK: - Network Constants

enum NetworkConstants {

    static let defaultPort: UInt16 = 4747
    static let maxPort: UInt16 = 65535
    static let minPort: UInt16 = 1
    static let connectionTimeout: TimeInterval = 10
    static let readTimeout: TimeInterval = 30
    static let writeTimeout: TimeInterval = 30
    static let keepAliveInterval: TimeInterval = 15
    static let maxPayloadSize = 10 * 1024 * 1024
    static let headerSize = 4
    static let bufferSize = 65_536
    static let maxRetries = 3
    static let retryDelay: TimeInterval = 2.0

    static let supportedProtocols: [StreamingProtocol] = [.mjpeg, .h264, .hevc]

    static let supportedCodecs: [StreamingCodec] = [.h264, .hevc, .mjpeg]
}

// MARK: - Camera Constants

enum CameraConstants {

    static let minBitrate = 100_000
    static let maxBitrate = 50_000_000
    static let defaultBitrate = 4_000_000
    static let minFrameRate = 15
    static let maxFrameRate = 60
    static let defaultFrameRate = 30
    static let minZoom: CGFloat = 1.0
    static let maxZoom: CGFloat = 10.0
    static let defaultZoom: CGFloat = 1.0
    static let minExposureISO: Float = 25
    static let maxExposureISO: Float = 1600
    static let defaultExposureISO: Float = 100
    static let focusAnimationDuration: Double = 0.3
    static let zoomAnimationDuration: Double = 0.25

    static let supportedResolutions: [VideoResolution] = [
        .qvga480, .hd720, .hd1080, .uhd4K
    ]

    static let supportedFrameRates = [15, 24, 25, 30, 48, 50, 60]
}
