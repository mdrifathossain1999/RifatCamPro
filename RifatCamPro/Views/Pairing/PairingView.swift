import SwiftUI

struct PairingView: View {

    @State private var viewModel: PairingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showQRScanner = false
    @State private var activeTab: PairingTab = .qrCode
    @State private var showPassword = false

    init(viewModel: PairingViewModel) {
        _viewModel = State(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Layout.spacing20) {
                        connectionStatusBar
                        tabPicker
                        tabContent
                        discoveredDevicesSection
                    }
                    .padding(.vertical, Layout.spacing16)
                }
            }
            .navigationTitle("Pair Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        viewModel.stopBrowsing()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    viewModel.handleScannedQRCode(code)
                }
            }
            .alert(viewModel.errorTitle, isPresented: $viewModel.showErrorAlert) {
                Button("OK", role: .cancel) {
                    viewModel.dismissError()
                }
            } message: {
                Text(viewModel.errorMessage)
            }
            .onAppear {
                viewModel.startBrowsing()
                viewModel.generatePairingQR()
            }
            .onDisappear {
                viewModel.stopScanning()
                viewModel.stopBrowsing()
            }
        }
    }

    // MARK: - Connection Status Bar

    @ViewBuilder
    private var connectionStatusBar: some View {
        if case .disconnected = viewModel.connectionStatus {
            EmptyView()
        } else {
            GlassCard(cornerRadii: Layout.cornerRadius16) {
                HStack(spacing: Layout.spacing12) {
                    StatusIndicator(
                        status: viewModel.connectionStatus,
                        size: .medium
                    )
                    VStack(alignment: .leading, spacing: Layout.spacing2) {
                        Text(viewModel.connectionStatus.displayText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if case .connected(let address) = viewModel.connectionStatus {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnect()
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(Layout.spacing16)
            }
            .padding(.horizontal, Layout.spacing16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(duration: 0.3), value: viewModel.isConnecting)
        }
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        Picker("Pairing Method", selection: $activeTab) {
            ForEach(PairingTab.allCases) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Layout.spacing16)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .qrCode:
            qrCodeSection
        case .manual:
            manualConnectionSection
        case .scan:
            scanQRSection
        }
    }

    // MARK: - QR Code Display Section

    private var qrCodeSection: some View {
        GlassCard(cornerRadii: Layout.cornerRadius20) {
            VStack(spacing: Layout.spacing20) {
                Text("Show this QR code to your desktop app")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if viewModel.isGeneratingQR {
                    ProgressView()
                        .frame(width: 220, height: 220)
                } else if let qrImage = viewModel.qrCodeImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(Layout.spacing12)
                        .background {
                            RoundedRectangle(cornerRadius: Layout.cornerRadius12)
                                .fill(.white)
                        }
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                } else {
                    VStack(spacing: Layout.spacing12) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("No WiFi connection detected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 220, height: 220)
                }

                Button {
                    viewModel.generatePairingQR()
                } label: {
                    Label("Regenerate QR Code", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, Layout.spacing20)
            .padding(.horizontal, Layout.spacing16)
        }
        .padding(.horizontal, Layout.spacing16)
    }

    // MARK: - Scan QR Section

    private var scanQRSection: some View {
        GlassCard(cornerRadii: Layout.cornerRadius20) {
            VStack(spacing: Layout.spacing20) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)

                VStack(spacing: Layout.spacing8) {
                    Text("Scan QR Code from Desktop")
                        .font(.headline)
                    Text("Point your camera at the QR code displayed on your desktop app to connect instantly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    showQRScanner = true
                } label: {
                    Label("Open Scanner", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius14))
            }
            .padding(.vertical, Layout.spacing24)
            .padding(.horizontal, Layout.spacing16)
        }
        .padding(.horizontal, Layout.spacing16)
    }

    // MARK: - Manual Connection Section

    private var manualConnectionSection: some View {
        GlassCard(cornerRadii: Layout.cornerRadius20) {
            VStack(alignment: .leading, spacing: Layout.spacing20) {
                Label("Manual Connection", systemImage: "keyboard")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Layout.spacing4) {
                    Text("Host")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. 192.168.1.100", text: $viewModel.manualHost)
                        .textFieldStyle(.plain)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(Layout.spacing12)
                        .background {
                            RoundedRectangle(cornerRadius: Layout.cornerRadius10)
                                .fill(Color(.tertiarySystemFill))
                        }
                        .overlay(alignment: .trailing) {
                            if !viewModel.isHostValid && !viewModel.manualHost.isEmpty {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(Color.appError)
                                    .padding(.trailing, Layout.spacing12)
                            }
                        }
                }

                VStack(alignment: .leading, spacing: Layout.spacing4) {
                    Text("Port")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("4747", text: $viewModel.manualPort)
                        .textFieldStyle(.plain)
                        .keyboardType(.numberPad)
                        .textContentType(.URL)
                        .padding(Layout.spacing12)
                        .background {
                            RoundedRectangle(cornerRadius: Layout.cornerRadius10)
                                .fill(Color(.tertiarySystemFill))
                        }
                        .overlay(alignment: .trailing) {
                            if !viewModel.isPortValid && !viewModel.manualPort.isEmpty {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(Color.appError)
                                    .padding(.trailing, Layout.spacing12)
                            }
                        }
                }

                VStack(alignment: .leading, spacing: Layout.spacing4) {
                    Text("Password (optional)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack {
                        if showPassword {
                            TextField("Enter password", text: $viewModel.manualPassword)
                                .textFieldStyle(.plain)
                                .textContentType(.password)
                        } else {
                            SecureField("Enter password", text: $viewModel.manualPassword)
                                .textFieldStyle(.plain)
                                .textContentType(.password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(Layout.spacing12)
                    .background {
                        RoundedRectangle(cornerRadius: Layout.cornerRadius10)
                            .fill(Color(.tertiarySystemFill))
                    }
                }

                if !viewModel.validationMessage.isEmpty {
                    Text(viewModel.validationMessage)
                        .font(.caption)
                        .foregroundStyle(Color.appError)
                }

                Button {
                    Task {
                        await viewModel.manualConnect()
                    }
                } label: {
                    HStack {
                        if viewModel.isConnecting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        Text(viewModel.isConnecting ? viewModel.connectionProgressMessage : "Connect")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius14))
                .disabled(!viewModel.isFormValid || viewModel.isConnecting)
                .opacity(viewModel.isFormValid && !viewModel.isConnecting ? 1.0 : 0.6)
            }
            .padding(.vertical, Layout.spacing20)
            .padding(.horizontal, Layout.spacing16)
        }
        .padding(.horizontal, Layout.spacing16)
        .onChange(of: viewModel.manualHost) {
            viewModel.validateForm()
        }
        .onChange(of: viewModel.manualPort) {
            viewModel.validateForm()
        }
    }

    // MARK: - Discovered Devices Section

    private var discoveredDevicesSection: some View {
        GlassCard(cornerRadii: Layout.cornerRadius20) {
            VStack(alignment: .leading, spacing: Layout.spacing16) {
                HStack {
                    Label("Discovered Devices", systemImage: "network")
                        .font(.headline)
                    Spacer()
                    if viewModel.isBrowsing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        viewModel.toggleBrowsing()
                    } label: {
                        Image(systemName: viewModel.isBrowsing ? "stop.circle" : "arrow.clockwise")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.discoveredDevices.isEmpty {
                    VStack(spacing: Layout.spacing12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        if viewModel.isBrowsing {
                            Text("Searching for desktop apps...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ProgressView()
                        } else {
                            Text("No devices found")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Make sure the desktop app is running and on the same network.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Layout.spacing24)
                } else {
                    LazyVStack(spacing: Layout.spacing8) {
                        ForEach(viewModel.discoveredDevices) { device in
                            DiscoveredDeviceRow(
                                device: device,
                                isLoading: viewModel.selectedDevice?.id == device.id && viewModel.isConnecting,
                                onSelect: {
                                    Task {
                                        await viewModel.connectToDevice(device)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .padding(.vertical, Layout.spacing16)
            .padding(.horizontal, Layout.spacing16)
        }
        .padding(.horizontal, Layout.spacing16)
    }
}

// MARK: - Discovered Device Row

private struct DiscoveredDeviceRow: View {

    let device: DiscoveredDevice
    let isLoading: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Layout.spacing12) {
                Image(systemName: "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                    }

                VStack(alignment: .leading, spacing: Layout.spacing2) {
                    Text(device.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: Layout.spacing4) {
                        Text("\(device.host):\(device.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if device.isPasswordProtected {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Layout.spacing12)
            .background {
                RoundedRectangle(cornerRadius: Layout.cornerRadius12)
                    .fill(Color(.secondarySystemGroupedBackground))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pairing Tab

private enum PairingTab: String, CaseIterable, Identifiable {
    case qrCode
    case manual
    case scan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qrCode: return "My QR"
        case .manual: return "Manual"
        case .scan: return "Scan QR"
        }
    }

    var icon: String {
        switch self {
        case .qrCode: return "qrcode"
        case .manual: return "keyboard"
        case .scan: return "camera.viewfinder"
        }
    }
}
