import SwiftUI

struct StreamingView: View {
    @Bindable var viewModel: StreamingViewModel

    @State private var showStopAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                statsOverviewCard
                protocolCard
                clientConnectionCard
                networkStatsCard
                eventLogCard
                stopButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Streaming")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Stop Streaming", isPresented: $showStopAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Stop", role: .destructive) {
                viewModel.stopStreaming()
            }
        } message: {
            Text("Are you sure you want to stop the current stream? This will disconnect all clients.")
        }
        .alert(viewModel.errorTitle, isPresented: $viewModel.showErrorAlert) {
            Button("OK", role: .cancel) {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    // MARK: - Header (Live + Duration)

    private var headerCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    StreamingStatusIndicator(isStreaming: viewModel.isStreaming)
                    Text(viewModel.isStreaming ? "LIVE" : "OFFLINE")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(viewModel.isStreaming ? .red : .secondary)
                        .tracking(1.2)
                }
                Spacer()
            }

            Text(viewModel.formattedDuration)
                .font(.system(size: 56, weight: .light, design: .monospaced))
                .foregroundStyle(viewModel.isStreaming ? .primary : .tertiary)
                .contentTransition(.numericText())
                .animation(.snappy, value: viewModel.formattedDuration)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)

            HStack(spacing: 16) {
                StatPill(
                    icon: "film",
                    text: "\(viewModel.streamingFrameRate) fps"
                )
                StatPill(
                    icon: "rectangle.resize",
                    text: viewModel.streamingResolution.rawValue
                )
                StatPill(
                    icon: "gauge.with.dots.needle.33percent",
                    text: String(format: "%.1f Mbps", Double(viewModel.streamingBitrate) / 1_000_000)
                )
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Stats Overview

    private var statsOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "chart.bar.fill", title: "Stream Statistics")
            StatsGridView(
                stats: [
                    StatItem(
                        icon: "film.stack",
                        label: "Frames Sent",
                        value: formatFrameCount(viewModel.framesEncoded),
                        color: .blue
                    ),
                    StatItem(
                        icon: "exclamationmark.triangle",
                        label: "Frames Dropped",
                        value: formatFrameCount(viewModel.framesDropped),
                        color: viewModel.framesDropped > 0 ? .orange : .secondary
                    ),
                    StatItem(
                        icon: "chart.line.downtrend.xyaxis",
                        label: "Drop Rate",
                        value: viewModel.formattedDropRate,
                        color: dropRateColor
                    ),
                    StatItem(
                        icon: "speedometer",
                        label: "Current Bitrate",
                        value: viewModel.formattedCurrentBitrate,
                        color: .green
                    ),
                    StatItem(
                        icon: viewModel.bitrateTrend.indicator,
                        label: "Adaptive",
                        value: viewModel.adaptiveBitrateEnabled
                            ? viewModel.bitrateTrend.displayName
                            : "Off",
                        color: viewModel.adaptiveBitrateEnabled
                            ? adaptiveTrendColor
                            : .secondary
                    ),
                    StatItem(
                        icon: "film",
                        label: "FPS",
                        value: String(format: "%.0f", viewModel.currentFPS),
                        color: .purple
                    )
                ],
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ]
            )
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Protocol Card

    private var protocolCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "video.badge.ellipsis", title: "Protocol")
            HStack(spacing: 12) {
                Image(systemName: viewModel.protocolIcon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.protocolName)
                        .font(.headline)
                    Text(viewModel.transportProtocol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(viewModel.streamingResolution.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.1), in: Capsule())
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Client Connection Card

    private var clientConnectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "person.circle.fill", title: "Client Connection")
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.title3)
                    .foregroundStyle(viewModel.clientAddress != "None" ? .green : .secondary)
                    .frame(width: 40, height: 40)
                    .background(
                        (viewModel.clientAddress != "None" ? Color.green : Color.secondary)
                            .opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.clientAddress)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .monospaced()
                    Text("Connected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Uptime")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(viewModel.formattedUptime)
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Network Stats Card

    private var networkStatsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "network", title: "Network")
            StatsGridView(
                stats: [
                    StatItem(
                        icon: "arrow.up.circle.fill",
                        label: "Upload Speed",
                        value: viewModel.formattedUploadSpeed,
                        color: .green
                    ),
                    StatItem(
                        icon: "arrow.down.circle.fill",
                        label: "Download Speed",
                        value: viewModel.formattedDownloadSpeed,
                        color: .blue
                    ),
                    StatItem(
                        icon: "clock.badge.questionmark",
                        label: "Latency",
                        value: viewModel.formattedLatency,
                        color: latencyColor
                    ),
                    StatItem(
                        icon: "internaldrive.fill",
                        label: "Total Sent",
                        value: viewModel.formattedTotalBytesSent,
                        color: .purple
                    )
                ],
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ]
            )
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Event Log Card

    private var eventLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(icon: "text.book.closed", title: "Event Log")
                Spacer()
                if !viewModel.streamEvents.isEmpty {
                    Button("Clear") {
                        viewModel.clearEvents()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if viewModel.streamEvents.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("No events yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.streamEvents.prefix(20)) { event in
                        EventRow(event: event)
                        if event.id != viewModel.streamEvents.prefix(20).last?.id {
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Stop Button

    private var stopButton: some View {
        Button {
            showStopAlert = true
        } label: {
            HStack {
                Spacer()
                Image(systemName: "stop.circle.fill")
                    .font(.title3)
                Text("Stop Streaming")
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                viewModel.isStreaming
                    ? AnyShapeStyle(Color.red)
                    : AnyShapeStyle(Color.red.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .disabled(!viewModel.isStreaming)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func formatFrameCount(_ count: UInt64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private var dropRateColor: Color {
        let rate = viewModel.dropRate
        if rate < 1 { return .green }
        if rate < 5 { return .orange }
        return .red
    }

    private var adaptiveTrendColor: Color {
        switch viewModel.bitrateTrend {
        case .increasing: return .green
        case .decreasing: return .orange
        case .stable: return .blue
        }
    }

    private var latencyColor: Color {
        let ms = viewModel.latency * 1000
        if ms < 10 { return .green }
        if ms < 50 { return .orange }
        return .red
    }
}

// MARK: - Streaming Status Indicator

struct StreamingStatusIndicator: View {
    let isStreaming: Bool
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(isStreaming ? Color.red : Color.secondary)
            .frame(width: 10, height: 10)
            .overlay(
                Group {
                    if isStreaming {
                        Circle()
                            .stroke(Color.red.opacity(0.5), lineWidth: 2)
                            .frame(width: 18, height: 18)
                            .scaleEffect(isPulsing ? 1.4 : 1.0)
                            .opacity(isPulsing ? 0 : 0.6)
                    }
                }
            )
            .onAppear {
                guard isStreaming else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                if streaming {
                    isPulsing = false
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        isPulsing = true
                    }
                } else {
                    isPulsing = false
                }
            }
    }
}

// MARK: - Stat Pill

struct StatPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: StreamEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: eventTypeIcon)
                .font(.caption)
                .foregroundStyle(eventTypeColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.message)
                    .font(.caption)
                    .lineLimit(2)
                Text(event.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var eventTypeIcon: String {
        switch event.type {
        case .started: return "play.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .paused: return "pause.circle.fill"
        case .resumed: return "play.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .clientConnected: return "person.circle.fill"
        case .clientDisconnected: return "person.circle.slash"
        case .codecChanged: return "film"
        case .resolutionChanged: return "rectangle.resize"
        case .bitrateAdjusted: return "slider.horizontal.3"
        }
    }

    private var eventTypeColor: Color {
        switch event.type {
        case .started, .resumed: return .green
        case .stopped: return .red
        case .paused: return .yellow
        case .error: return .red
        case .clientConnected: return .blue
        case .clientDisconnected: return .orange
        case .codecChanged, .resolutionChanged: return .purple
        case .bitrateAdjusted: return .cyan
        }
    }
}
