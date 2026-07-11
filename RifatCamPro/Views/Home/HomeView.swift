import SwiftUI

// MARK: - Home View

struct HomeView: View {
    @Environment(HomeViewModel.self) private var viewModel

    @State private var selectedTab = 0
    @State private var showPairingSheet = false
    @State private var zoomFactor: CGFloat = 1.0

    var body: some View {
        @Bindable var vm = viewModel

        TabView(selection: $selectedTab) {
            homeTab
                .tag(0)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            streamingTab
                .tag(1)
                .tabItem {
                    Label("Stream", systemImage: "antenna.radiowaves.left.and.right")
                }

            settingsTab
                .tag(2)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(.accentColor)
        .errorAlert(
            isPresented: $vm.showErrorAlert,
            title: viewModel.errorTitle,
            message: viewModel.errorMessage
        )
    }

    // MARK: - Home Tab

    private var homeTab: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                cameraSection

                VStack(spacing: 0) {
                    topBar

                    Spacer()

                    if viewModel.isStreaming {
                        streamingOverlay
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    bottomControls
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 12)

                if viewModel.isInitializing {
                    loadingOverlay
                }
            }
            .navigationTitle("RifatCam Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                Task { await viewModel.initialize() }
            }
        }
    }

    // MARK: - Camera Section

    private var cameraSection: some View {
        CameraPreviewView(
            session: viewModel.cameraService.previewSession,
            cameraPosition: viewModel.currentPosition,
            mirrorFront: true,
            mirrorBack: false,
            onZoomChanged: { zoom in
                viewModel.cameraService.setZoom(zoom)
            },
            onFocusAt: { point in
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    let frame = window.bounds
                    viewModel.cameraService.setFocus(point: point, in: frame)
                }
            },
            zoomFactor: $zoomFactor
        )
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(spacing: 8) {
            StatusBarView(
                localIP: viewModel.localIP,
                port: viewModel.port,
                connectionStatus: viewModel.connectionStatus,
                resolution: viewModel.cameraService.currentConfiguration.resolution,
                fps: viewModel.currentFPS,
                batteryLevel: viewModel.batteryLevel,
                batteryIconName: viewModel.batteryIconName,
                isStreaming: viewModel.isStreaming,
                bitrate: viewModel.formattedBitrate,
                latency: viewModel.formattedLatency,
                duration: viewModel.streamingDuration
            )
            .padding(.top, 4)
        }
    }

    // MARK: - Streaming Overlay

    private var streamingOverlay: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(pulseOpacity)

            Text(viewModel.streamingDuration)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.4
            }
        }
        .onDisappear {
            pulseOpacity = 1.0
        }
    }

    @State private var pulseOpacity: Double = 1.0

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            actionRow

            if viewModel.isStreaming {
                NetworkStatsOverlay(
                    bitrate: viewModel.formattedBitrate,
                    latency: viewModel.formattedLatency,
                    duration: viewModel.streamingDuration
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 20) {
            ActionButton.qrCodeButton {
                viewModel.generateQRCode()
            }

            ActionButton.torchButton(isOn: viewModel.isTorchOn) {
                viewModel.toggleTorch()
            }

            ActionButton.streamButton(
                isStreaming: viewModel.isStreaming,
                isEnabled: viewModel.isSessionRunning
            ) {
                Task { await viewModel.toggleStreaming() }
            }

            ActionButton.switchCamera {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    viewModel.switchCamera()
                }
            }

            ActionButton.settingsButton {
                viewModel.navigateToSettings()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)

                Text("Initializing camera...")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .transition(.opacity)
    }

    // MARK: - Streaming Tab

    private var streamingTab: some View {
        NavigationStack {
            StreamingDetailContent(viewModel: viewModel)
                .navigationTitle("Stream")
                .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        NavigationStack {
            SettingsListContent()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Streaming Detail Content

private struct StreamingDetailContent: View {
    let viewModel: HomeViewModel

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: viewModel.isStreaming ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.title2)
                        .foregroundStyle(viewModel.isStreaming ? .green : .secondary)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Streaming Status")
                            .font(.headline)
                        Text(viewModel.isStreaming ? "Active" : "Inactive")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(viewModel.streamingDuration)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(viewModel.isStreaming ? .green : .secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Status")
            }

            Section("Connection") {
                statRow(icon: "wifi", title: "IP Address", value: viewModel.localIP)
                statRow(icon: "number", title: "Port", value: "\(viewModel.port)")

                HStack {
                    Label("Status", systemImage: viewModel.connectionStatus.iconName)
                    Spacer()
                    Text(viewModel.connectionStatus.displayText)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Network Stats") {
                statRow(icon: "arrow.up.circle", title: "Bitrate", value: viewModel.formattedBitrate)
                statRow(icon: "gauge.with.dots.needle.67percent", title: "Latency", value: viewModel.formattedLatency)
                statRow(icon: "arrow.up.arrow.down", title: "Bytes Sent", value: viewModel.formattedBytesSent)
                statRow(icon: "film", title: "Resolution", value: viewModel.cameraService.currentConfiguration.resolution.rawValue)
                statRow(icon: "speedometer", title: "FPS", value: String(format: "%.1f", viewModel.currentFPS))
            }

            Section("Device") {
                statRow(icon: "thermometer", title: "Thermal", value: viewModel.thermalState.displayName)

                HStack {
                    Label("Battery", systemImage: viewModel.batteryIconName)
                    Spacer()
                    Text("\(Int(viewModel.batteryLevel * 100))%")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await viewModel.toggleStreaming() }
                } label: {
                    HStack {
                        Spacer()
                        Text(viewModel.isStreaming ? "Stop Streaming" : "Start Streaming")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .listRowBackground(
                    viewModel.isStreaming
                    ? Color.red.opacity(0.15)
                    : Color.green.opacity(0.15)
                )
                .foregroundStyle(viewModel.isStreaming ? .red : .green)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func statRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Settings List Content

private struct SettingsListContent: View {
    var body: some View {
        List {
            Section {
                Label("Camera", systemImage: "camera.fill")
                Label("Network", systemImage: "network")
                Label("Security", systemImage: "lock.shield")
                Label("Streaming", systemImage: "antenna.radiowaves.left.and.right")
            } header: {
                Text("Configuration")
            }

            Section {
                Label("Appearance", systemImage: "paintbrush.fill")
                Label("Notifications", systemImage: "bell.fill")
                Label("Background Mode", systemImage: "app.badge")
            } header: {
                Text("Preferences")
            }

            Section {
                Label("Export Settings", systemImage: "square.and.arrow.up")
                Label("Import Settings", systemImage: "square.and.arrow.down")
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            } header: {
                Text("Data")
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Error Alert Modifier

private struct ErrorAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

private extension View {
    func errorAlert(isPresented: Binding<Bool>, title: String, message: String) -> some View {
        modifier(ErrorAlertModifier(isPresented: isPresented, title: title, message: message))
    }
}
