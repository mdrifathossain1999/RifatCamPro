import Foundation
import Combine
import Observation

@Observable
final class SettingsManager {

    // MARK: - Published State

    private(set) var currentSettings: AppSettings = .default
    private(set) var isLoading = false
    private(set) var lastSaveError: Error?

    // MARK: - Observable Convenience Properties

    var streamQuality: StreamQuality {
        get { currentSettings.streamQuality }
        set {
            currentSettings.streamQuality = newValue
            save()
            streamQualityChanged.send(newValue)
        }
    }

    var theme: AppTheme {
        get { currentSettings.theme }
        set {
            currentSettings.theme = newValue
            save()
            themeChanged.send(newValue)
        }
    }

    var backgroundStreaming: Bool {
        get { currentSettings.backgroundStreaming }
        set {
            currentSettings.backgroundStreaming = newValue
            save()
            backgroundStreamingChanged.send(newValue)
        }
    }

    var autoConnect: Bool {
        get { currentSettings.autoConnect }
        set {
            currentSettings.autoConnect = newValue
            save()
            autoConnectChanged.send(newValue)
        }
    }

    var showNetworkStats: Bool {
        get { currentSettings.showNetworkStats }
        set {
            currentSettings.showNetworkStats = newValue
            save()
            showNetworkStatsChanged.send(newValue)
        }
    }

    var enableNotifications: Bool {
        get { currentSettings.enableNotifications }
        set {
            currentSettings.enableNotifications = newValue
            save()
            enableNotificationsChanged.send(newValue)
        }
    }

    var networkConfiguration: NetworkConfiguration {
        get { currentSettings.network }
        set {
            currentSettings.network = newValue
            save()
            networkConfigurationChanged.send(newValue)
        }
    }

    var cameraConfiguration: CameraConfiguration {
        get { currentSettings.camera }
        set {
            currentSettings.camera = newValue
            save()
            cameraConfigurationChanged.send(newValue)
        }
    }

    // MARK: - Combine Publishers

    let settingsDidChange = PassthroughSubject<AppSettings, Never>()
    let streamQualityChanged = PassthroughSubject<StreamQuality, Never>()
    let themeChanged = PassthroughSubject<AppTheme, Never>()
    let backgroundStreamingChanged = PassthroughSubject<Bool, Never>()
    let autoConnectChanged = PassthroughSubject<Bool, Never>()
    let showNetworkStatsChanged = PassthroughSubject<Bool, Never>()
    let enableNotificationsChanged = PassthroughSubject<Bool, Never>()
    let networkConfigurationChanged = PassthroughSubject<NetworkConfiguration, Never>()
    let cameraConfigurationChanged = PassthroughSubject<CameraConfiguration, Never>()
    let settingsImported = PassthroughSubject<Bool, Never>()
    let settingsExported = PassthroughSubject<Data?, Never>()

    // MARK: - Private

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let saveQueue = DispatchQueue(label: "com.rifatcam.settings.save", qos: .utility)
    private let settingsKey = "com.rifatcam.appSettings"
    private let versionKey = "com.rifatcam.settingsVersion"
    private let currentVersion = 2

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    // MARK: - Load

    func load() {
        isLoading = true
        defer { isLoading = false }

        migrateIfNeeded()

        guard let data = defaults.data(forKey: settingsKey) else {
            currentSettings = .default
            save()
            return
        }

        do {
            currentSettings = try decoder.decode(AppSettings.self, from: data)
        } catch {
            lastSaveError = error
            currentSettings = .default
        }
    }

    // MARK: - Save

    func save() {
        saveQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try self.encoder.encode(self.currentSettings)
                self.defaults.set(data, forKey: self.settingsKey)
                self.defaults.set(self.currentVersion, forKey: self.versionKey)
                self.defaults.synchronize()
                DispatchQueue.main.async {
                    self.lastSaveError = nil
                    self.settingsDidChange.send(self.currentSettings)
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastSaveError = error
                }
            }
        }
    }

    // MARK: - Update

    func update(_ transform: (inout AppSettings) -> Void) {
        transform(&currentSettings)
        save()
    }

    func resetToDefaults() {
        currentSettings = .default
        save()
        settingsDidChange.send(currentSettings)
    }

    func resetCameraSettings() {
        currentSettings.camera = CameraConfiguration()
        save()
        cameraConfigurationChanged.send(currentSettings.camera)
    }

    func resetNetworkSettings() {
        currentSettings.network = NetworkConfiguration()
        save()
        networkConfigurationChanged.send(currentSettings.network)
    }

    // MARK: - Migration

    private func migrateIfNeeded() {
        let storedVersion = defaults.integer(forKey: versionKey)

        guard storedVersion < currentVersion else { return }

        if storedVersion < 1 {
            migrateToV1()
        }
        if storedVersion < 2 {
            migrateToV2()
        }

        defaults.set(currentVersion, forKey: versionKey)
    }

    private func migrateToV1() {
        guard let data = defaults.data(forKey: settingsKey) else { return }

        struct LegacySettingsV0: Codable {
            var port: Int = 4747
            var password: String = ""
            var enablePasswordProtection: Bool = false
            var resolution: Int = 1080
            var frameRate: Int = 30
            var bitrate: Int = 4_000_000
            var theme: String = "dark"
        }

        guard let legacy = try? decoder.decode(LegacySettingsV0.self, from: data) else { return }

        var settings = AppSettings.default
        settings.network.port = UInt16(legacy.port)
        settings.network.password = legacy.password
        settings.network.enablePasswordProtection = legacy.enablePasswordProtection

        switch legacy.resolution {
        case 480: settings.camera.resolution = .qvga480
        case 720: settings.camera.resolution = .hd720
        case 2160: settings.camera.resolution = .uhd4K
        default: settings.camera.resolution = .hd1080
        }

        settings.camera.frameRate = legacy.frameRate
        settings.camera.bitrate = legacy.bitrate

        switch legacy.theme {
        case "light": settings.theme = .light
        case "system": settings.theme = .system
        default: settings.theme = .dark
        }

        if let encoded = try? encoder.encode(settings) {
            defaults.set(encoded, forKey: settingsKey)
        }
    }

    private func migrateToV2() {
        guard let data = defaults.data(forKey: settingsKey),
              var settings = try? decoder.decode(AppSettings.self, from: data) else { return }

        if settings.network.connectionTimeout <= 0 {
            settings.network.connectionTimeout = 10
        }
        if settings.network.maxConnections <= 0 {
            settings.network.maxConnections = 1
        }

        if let encoded = try? encoder.encode(settings) {
            defaults.set(encoded, forKey: settingsKey)
        }
    }

    // MARK: - Import / Export

    func exportSettings() -> Data? {
        do {
            currentSettings.camera.selectedCamera = currentSettings.camera.selectedCamera
            let data = try encoder.encode(currentSettings)
            settingsExported.send(data)
            return data
        } catch {
            lastSaveError = error
            settingsExported.send(nil)
            return nil
        }
    }

    func exportSettingsAsJSON() -> String? {
        guard let data = exportSettings() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func importSettings(from data: Data) -> Bool {
        do {
            let imported = try decoder.decode(AppSettings.self, from: data)
            currentSettings = imported
            save()
            settingsImported.send(true)
            settingsDidChange.send(currentSettings)
            return true
        } catch {
            lastSaveError = error
            settingsImported.send(false)
            return false
        }
    }

    func importSettings(from jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8) else {
            settingsImported.send(false)
            return false
        }
        return importSettings(from: data)
    }

    func importSettings(from url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else {
            settingsImported.send(false)
            return false
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else {
            settingsImported.send(false)
            return false
        }

        return importSettings(from: data)
    }

    func exportSettingsToURL(_ url: URL) -> Bool {
        guard let data = exportSettings() else { return false }
        guard url.startAccessingSecurityScopedResource() else { return false }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            lastSaveError = error
            return false
        }
    }

    // MARK: - Combine Subscription

    func observeSettings() -> AnyPublisher<AppSettings, Never> {
        settingsDidChange.eraseToAnyPublisher()
    }

    func observeStreamQuality() -> AnyPublisher<StreamQuality, Never> {
        streamQualityChanged.eraseToAnyPublisher()
    }

    func observeNetworkConfiguration() -> AnyPublisher<NetworkConfiguration, Never> {
        networkConfigurationChanged.eraseToAnyPublisher()
    }

    func observeCameraConfiguration() -> AnyPublisher<CameraConfiguration, Never> {
        cameraConfigurationChanged.eraseToAnyPublisher()
    }

    // MARK: - Presets

    func applyPreset(_ preset: SettingsPreset) {
        switch preset {
        case .lowPower:
            currentSettings.streamQuality = .low
            currentSettings.camera.resolution = .qvga480
            currentSettings.camera.frameRate = 24
            currentSettings.camera.bitrate = 1_000_000
            currentSettings.backgroundStreaming = true
            currentSettings.camera.enableAudio = false

        case .balanced:
            currentSettings.streamQuality = .balanced
            currentSettings.camera.resolution = .hd1080
            currentSettings.camera.frameRate = 30
            currentSettings.camera.bitrate = 4_000_000
            currentSettings.backgroundStreaming = true
            currentSettings.camera.enableAudio = true

        case .highQuality:
            currentSettings.streamQuality = .high
            currentSettings.camera.resolution = .uhd4K
            currentSettings.camera.frameRate = 60
            currentSettings.camera.bitrate = 12_000_000
            currentSettings.backgroundStreaming = true
            currentSettings.camera.enableAudio = true
            currentSettings.camera.enableHDR = true

        case .minimal:
            currentSettings.streamQuality = .ultraLow
            currentSettings.camera.resolution = .qvga480
            currentSettings.camera.frameRate = 15
            currentSettings.camera.bitrate = 500_000
            currentSettings.backgroundStreaming = false
            currentSettings.camera.enableAudio = false
        }

        save()
        settingsDidChange.send(currentSettings)
    }

    // MARK: - Convenience Accessors

    var port: UInt16 {
        get { currentSettings.network.port }
        set {
            currentSettings.network.port = newValue
            save()
        }
    }

    var password: String {
        get { currentSettings.network.password }
        set {
            currentSettings.network.password = newValue
            save()
        }
    }

    var enablePasswordProtection: Bool {
        get { currentSettings.network.enablePasswordProtection }
        set {
            currentSettings.network.enablePasswordProtection = newValue
            save()
        }
    }

    var enableBonjour: Bool {
        get { currentSettings.network.enableBonjour }
        set {
            currentSettings.network.enableBonjour = newValue
            save()
        }
    }

    var enableTLS: Bool {
        get { currentSettings.network.enableTLS }
        set {
            currentSettings.network.enableTLS = newValue
            save()
        }
    }

    var resolution: VideoResolution {
        get { currentSettings.camera.resolution }
        set {
            currentSettings.camera.resolution = newValue
            save()
        }
    }

    var frameRate: Int {
        get { currentSettings.camera.frameRate }
        set {
            currentSettings.camera.frameRate = newValue
            save()
        }
    }

    var bitrate: Int {
        get { currentSettings.camera.bitrate }
        set {
            currentSettings.camera.bitrate = newValue
            save()
        }
    }

    var codec: StreamingCodec {
        get { currentSettings.camera.codec }
        set {
            currentSettings.camera.codec = newValue
            save()
        }
    }
}

// MARK: - Settings Presets

enum SettingsPreset: String, CaseIterable, Sendable {
    case lowPower
    case balanced
    case highQuality
    case minimal

    var displayName: String {
        switch self {
        case .lowPower: return "Low Power"
        case .balanced: return "Balanced"
        case .highQuality: return "High Quality"
        case .minimal: return "Minimal"
        }
    }

    var description: String {
        switch self {
        case .lowPower: return "Saves battery with reduced quality"
        case .balanced: return "Good quality with moderate battery usage"
        case .highQuality: return "Maximum quality, higher battery usage"
        case .minimal: return "Minimum bandwidth and processing"
        }
    }

    var iconName: String {
        switch self {
        case .lowPower: return "bolt.circle"
        case .balanced: return "equal.circle"
        case .highQuality: return "star.circle"
        case .minimal: return "minus.circle"
        }
    }
}
