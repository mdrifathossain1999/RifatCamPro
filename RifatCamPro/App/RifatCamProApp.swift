import SwiftUI

@main
struct RifatCamProApp: App {

    // MARK: - Core Services (no dependencies)

    @State private var cameraService = CameraService()
    @State private var networkService = NetworkService()
    @State private var settingsManager = SettingsManager()
    @State private var bonjourService = BonjourService()
    @State private var securityService = SecurityService()
    @State private var batteryManager = BatteryManager()
    @State private var focusManager = FocusManager()
    @State private var videoEncoder = VideoEncoder()

    // MARK: - Dependent Services

    @State private var streamManager: StreamManager
    @State private var connectionManager: ConnectionManager

    // MARK: - ViewModels

    @State private var homeViewModel: HomeViewModel

    // MARK: - Init

    init() {
        let camera = CameraService()
        let network = NetworkService()
        let settings = SettingsManager()
        let security = SecurityService()
        let bonjour = BonjourService()
        let battery = BatteryManager()
        let encoder = VideoEncoder()

        let stream = StreamManager()
        let connection = ConnectionManager(
            cameraService: camera,
            securityService: security,
            settingsManager: settings,
            speedMonitor: SpeedMonitor()
        )

        let home = HomeViewModel(
            cameraService: camera,
            networkService: network,
            streamManager: stream,
            connectionManager: connection,
            settingsManager: settings,
            bonjourService: bonjour,
            securityService: security,
            batteryManager: battery,
            videoEncoder: encoder
        )

        _cameraService = State(wrappedValue: camera)
        _networkService = State(wrappedValue: network)
        _settingsManager = State(wrappedValue: settings)
        _bonjourService = State(wrappedValue: bonjour)
        _securityService = State(wrappedValue: security)
        _batteryManager = State(wrappedValue: battery)
        _focusManager = State(wrappedValue: FocusManager())
        _videoEncoder = State(wrappedValue: encoder)
        _streamManager = State(wrappedValue: stream)
        _connectionManager = State(wrappedValue: connection)
        _homeViewModel = State(wrappedValue: home)
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(homeViewModel)
                .environmentObject(cameraService)
                .environment(networkService)
                .environmentObject(streamManager)
                .environmentObject(connectionManager)
                .environment(settingsManager)
                .environmentObject(bonjourService)
                .environment(securityService)
                .environmentObject(batteryManager)
                .environment(focusManager)
                .environmentObject(videoEncoder)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    configureAppearance()
                }
        }
    }

    // MARK: - Appearance

    @State private var colorScheme: ColorScheme?

    private func configureAppearance() {
        let theme = settingsManager.currentSettings.theme
        switch theme {
        case .light:
            colorScheme = .light
        case .dark:
            colorScheme = .dark
        case .system:
            colorScheme = nil
        }
    }
}
