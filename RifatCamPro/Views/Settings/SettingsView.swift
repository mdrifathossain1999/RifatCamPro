import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var showResetAlert = false
    @State private var portText: String = ""
    @State private var showPassword: Bool = false
    @State private var manualFocusPosition: Float = 0.5
    @State private var showImportResult = false
    @State private var showExportResult = false
    @State private var exportResultMessage = ""
    @State private var importFileURL: URL?
    @State private var exportFileURL: URL?
    @State private var showDocumentPicker = false
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            Form {
                cameraSection
                focusSection
                exposureSection
                audioSection
                networkSection
                appearanceSection
                advancedSection
                importExportSection
                resetSection
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.visible)
            .onAppear {
                portText = "\(viewModel.port)"
                manualFocusPosition = viewModel.settingsManager.cameraConfiguration.manualFocusLensPosition
            }
            .onChange(of: portText) { _, newValue in
                applyPort(newValue)
            }
            .alert("Reset to Defaults", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    viewModel.resetToDefaults()
                    portText = "\(viewModel.port)"
                }
            } message: {
                Text("All settings will be restored to their default values. This action cannot be undone.")
            }
            .alert(viewModel.errorTitle, isPresented: $viewModel.showErrorAlert) {
                Button("OK", role: .cancel) {
                    viewModel.dismissError()
                }
            } message: {
                Text(viewModel.errorMessage)
            }
            .alert("Import Result", isPresented: $showImportResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.importResultMessage)
            }
            .fileImporter(
                isPresented: $showDocumentPicker,
                allowedContentTypes: [UTType.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .fileExporter(
                isPresented: $isExporting,
                document: SettingsDocument(data: viewModel.exportSettings()),
                contentType: .json,
                defaultFilename: "RifatCamPro_Settings"
            ) { result in
                switch result {
                case .success:
                    exportResultMessage = "Settings exported successfully."
                case .failure(let error):
                    exportResultMessage = "Export failed: \(error.localizedDescription)"
                }
                showExportResult = true
            }
            .alert("Export Result", isPresented: $showExportResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportResultMessage)
            }
        }
    }

    // MARK: - Camera Section

    private var cameraSection: some View {
        Section {
            NavigationLink {
                ResolutionPicker(
                    selectedResolution: Binding(
                        get: { viewModel.resolution },
                        set: { viewModel.applyResolution($0) }
                    )
                )
            } label: {
                settingsRow(
                    icon: "rectangle.resize",
                    iconColor: .blue,
                    title: "Resolution",
                    value: viewModel.resolution.rawValue
                )
            }

            HStack {
                Label("Frame Rate", systemImage: "film")
                    .foregroundStyle(.primary)
                Spacer()
                Picker("", selection: Binding(
                    get: { viewModel.frameRate },
                    set: { viewModel.applyFrameRate($0) }
                )) {
                    ForEach(viewModel.availableFrameRates, id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }

            HStack {
                Label("Codec", systemImage: "video.badge.ellipsis")
                    .foregroundStyle(.primary)
                Spacer()
                Picker("", selection: Binding(
                    get: { viewModel.codec },
                    set: { viewModel.applyCodec($0) }
                )) {
                    ForEach(viewModel.availableCodecs, id: \.self) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Bitrate", systemImage: "gauge.with.dots.needle.33percent")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(format: "%.1f Mbps", Double(viewModel.bitrate) / 1_000_000))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(viewModel.bitrate) },
                        set: { viewModel.applyBitrate(Int($0)) }
                    ),
                    in: 1_000_000...20_000_000,
                    step: 100_000
                )
                .tint(.blue)
            }

            Toggle(isOn: Binding(
                get: { viewModel.enableHDR },
                set: { viewModel.applyHDR($0) }
            )) {
                Label("HDR", systemImage: "sun.max")
            }

            Toggle(isOn: Binding(
                get: { viewModel.enableTorch },
                set: { viewModel.applyTorch($0) }
            )) {
                Label("Torch", systemImage: "flashlight.on.fill")
            }
        } header: {
            Label("Camera", systemImage: "camera.fill")
        } footer: {
            Text("Higher bitrate and resolution improve quality but require more bandwidth. HDR is only available on supported devices.")
        }
    }

    // MARK: - Focus Section

    private var focusSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.enableAutoFocus },
                set: { viewModel.applyAutoFocus($0) }
            )) {
                Label("Auto Focus", systemImage: "focus.rings")
            }

            if !viewModel.enableAutoFocus {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Manual Focus", systemImage: "scope")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(String(format: "%.0f%%", manualFocusPosition * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $manualFocusPosition, in: 0...1, step: 0.01)
                        .tint(.orange)
                        .onChange(of: manualFocusPosition) { _, newValue in
                            applyManualFocus(newValue)
                        }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Zoom", systemImage: "magnifyingglass")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(format: "%.1fx", viewModel.zoomFactor))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { viewModel.zoomFactor },
                        set: { viewModel.applyZoom($0) }
                    ),
                    in: 1.0...viewModel.maxZoomFactor,
                    step: 0.1
                )
                .tint(.purple)
            }
        } header: {
            Label("Focus & Zoom", systemImage: "focus.rings")
        } footer: {
            Text("Disable auto focus to manually adjust the lens position. Zoom factor ranges from 1x to \(String(format: "%.0f", viewModel.maxZoomFactor))x.")
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.enableAutoFocus)
    }

    // MARK: - Exposure Section

    private var exposureSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("ISO", systemImage: "sun.haze")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(format: "%.0f", viewModel.exposureISO))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(viewModel.exposureISO) },
                        set: { viewModel.applyExposureISO(Float($0)) }
                    ),
                    in: Double(viewModel.isoRange.lowerBound)...Double(viewModel.isoRange.upperBound),
                    step: 50
                )
                .tint(.yellow)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("White Balance", systemImage: "thermometer.medium")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(Int(viewModel.whiteBalanceTemperature))K")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { viewModel.whiteBalanceTemperature },
                        set: { viewModel.applyWhiteBalance($0) }
                    ),
                    in: 3000...7000,
                    step: 100
                )
                .tint(.cyan)
            }
        } header: {
            Label("Exposure", systemImage: "sun.max.fill")
        } footer: {
            Text("Adjust ISO sensitivity and color temperature. Higher ISO increases brightness but may add noise. Lower Kelvin values produce cooler tones.")
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.enableAudio },
                set: { viewModel.applyAudioEnabled($0) }
            )) {
                Label("Enable Audio", systemImage: "mic.fill")
            }

            Toggle(isOn: Binding(
                get: { viewModel.enableNoiseSuppression },
                set: { viewModel.applyNoiseSuppression($0) }
            )) {
                Label("Noise Suppression", systemImage: "waveform.badge.magnifyingglass")
            }
            .disabled(!viewModel.enableAudio)

            Toggle(isOn: Binding(
                get: { viewModel.audioMuted },
                set: { viewModel.applyAudioMuted($0) }
            )) {
                Label("Mute Audio", systemImage: "mic.slash.fill")
            }
            .disabled(!viewModel.enableAudio)
        } header: {
            Label("Audio", systemImage: "waveform")
        } footer: {
            Text(viewModel.enableAudio
                ? "Noise suppression reduces background noise during streaming. Muting disables audio capture entirely."
                : "Enable audio to capture sound during streaming.")
        }
    }

    // MARK: - Network Section

    private var networkSection: some View {
        Section {
            HStack {
                Label("Port", systemImage: "number")
                    .foregroundStyle(.primary)
                Spacer()
                TextField("4747", text: $portText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
                    .onChange(of: portText) { _, newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered != newValue {
                            portText = filtered
                        }
                    }
            }
            .listRowBorderColor(!viewModel.isPortValid ? .red : .clear)

            if !viewModel.isPortValid && !viewModel.validationMessage.isEmpty {
                Text(viewModel.validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if viewModel.enablePasswordProtection {
                HStack {
                    Label("Password", systemImage: "lock.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    if showPassword {
                        TextField("Enter password", text: Binding(
                            get: { viewModel.password },
                            set: { viewModel.applyPassword($0) }
                        ))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                    } else {
                        SecureField("Enter password", text: Binding(
                            get: { viewModel.password },
                            set: { viewModel.applyPassword($0) }
                        ))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { viewModel.enablePasswordProtection },
                set: { viewModel.applyPasswordProtection($0) }
            )) {
                Label("Password Protection", systemImage: "lock.shield")
            }

            Toggle(isOn: Binding(
                get: { viewModel.enableBonjour },
                set: { viewModel.applyBonjour($0) }
            )) {
                Label("Bonjour Discovery", systemImage: "magnifyingglass")
            }

            Toggle(isOn: Binding(
                get: { viewModel.enableTLS },
                set: { viewModel.applyTLS($0) }
            )) {
                Label("Enable TLS", systemImage: "checkmark.shield.fill")
            }

            if !viewModel.securityWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.securityWarnings) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: warning.severity == .critical
                                ? "exclamationmark.triangle.fill"
                                : "exclamationmark.circle")
                                .foregroundStyle(warning.severity == .critical ? .red : .orange)
                                .font(.caption)
                            Text(warning.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("Network", systemImage: "network")
        } footer: {
            Text("Port must be between 1 and 65535. TLS encrypts all connections but may increase latency. Bonjour allows automatic device discovery on the local network.")
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        Section {
            HStack {
                Label("Theme", systemImage: "paintbrush.fill")
                    .foregroundStyle(.primary)
                Spacer()
                Picker("", selection: Binding(
                    get: { viewModel.selectedTheme },
                    set: { viewModel.applyTheme($0) }
                )) {
                    ForEach(viewModel.availableThemes, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }

            Toggle(isOn: Binding(
                get: { viewModel.mirrorFrontCamera },
                set: { viewModel.applyMirrorFront($0) }
            )) {
                Label("Mirror Front Camera", systemImage: "camera.metering.center.weighted")
            }

            Toggle(isOn: Binding(
                get: { viewModel.mirrorBackCamera },
                set: { viewModel.applyMirrorBack($0) }
            )) {
                Label("Mirror Back Camera", systemImage: "camera.metering.center.weighted")
            }

            HStack {
                Label("Watermark", systemImage: "textformat.abc")
                    .foregroundStyle(.primary)
                Spacer()
                TextField("None", text: Binding(
                    get: { viewModel.watermarkText },
                    set: { viewModel.applyWatermark($0) }
                ))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
            }
        } header: {
            Label("Appearance", systemImage: "paintbrush")
        } footer: {
            Text("Mirroring flips the preview horizontally. Watermark text is overlaid on the stream output.")
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.backgroundStreaming },
                set: { viewModel.applyBackgroundStreaming($0) }
            )) {
                Label("Background Streaming", systemImage: "app.badge")
            }

            Toggle(isOn: Binding(
                get: { viewModel.autoConnect },
                set: { viewModel.applyAutoConnect($0) }
            )) {
                Label("Auto Connect", systemImage: "arrow.triangle.2.circlepath")
            }

            Toggle(isOn: Binding(
                get: { viewModel.showNetworkStats },
                set: { viewModel.applyShowNetworkStats($0) }
            )) {
                Label("Show Stats Overlay", systemImage: "chart.bar.fill")
            }

            HStack {
                Label("Stream Quality", systemImage: "sparkles")
                    .foregroundStyle(.primary)
                Spacer()
                Picker("", selection: Binding(
                    get: { viewModel.streamQuality },
                    set: { viewModel.applyStreamQuality($0) }
                )) {
                    ForEach(viewModel.availableQualities, id: \.self) { quality in
                        VStack(alignment: .leading) {
                            Text(quality.displayName)
                            Text(quality.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }
        } header: {
            Label("Advanced", systemImage: "gearshape.2")
        } footer: {
            Text("Background streaming keeps sending video when the app is minimized. Stream quality presets automatically adjust bitrate for optimal performance.")
        }
    }

    // MARK: - Import / Export Section

    private var importExportSection: some View {
        Section {
            Button {
                showDocumentPicker = true
            } label: {
                Label("Import Settings", systemImage: "square.and.arrow.down")
                    .foregroundStyle(.blue)
            }

            Button {
                isExporting = true
            } label: {
                Label("Export Settings", systemImage: "square.and.arrow.up")
                    .foregroundStyle(.blue)
            }
        } header: {
            Label("Data", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text("Import or export your settings as a JSON file. Useful for backing up or transferring configuration between devices.")
        }
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetAlert = true
            } label: {
                HStack {
                    Spacer()
                    Text("Reset to Defaults")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
        } footer: {
            Text("This will restore all settings to their factory defaults. Your current configuration will be lost.")
        }
    }

    // MARK: - Helpers

    private func settingsRow(icon: String, iconColor: Color, title: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.forward")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func applyPort(_ text: String) {
        guard let port = UInt16(text), port > 0 else {
            viewModel.isPortValid = text.isEmpty
            return
        }
        viewModel.applyPort(port)
    }

    private func applyManualFocus(_ position: Float) {
        var config = viewModel.settingsManager.cameraConfiguration
        config.manualFocusLensPosition = position
        viewModel.settingsManager.cameraConfiguration = config
    }

    private func syncPortText() {
        portText = "\(viewModel.port)"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            _ = viewModel.importSettings(from: url)
            portText = "\(viewModel.port)"
        case .failure(let error):
            viewModel.showError(.networkError(error.localizedDescription))
        }
    }
}

// MARK: - Settings Document (FileExporter)

struct SettingsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data?

    init(data: Data?) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = fileData
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
