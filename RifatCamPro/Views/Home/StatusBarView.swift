import SwiftUI

struct StatusBarView: View {
    let localIP: String
    let port: UInt16
    let connectionStatus: ConnectionStatus
    let resolution: VideoResolution
    let fps: Double
    let batteryLevel: Float
    let batteryIconName: String
    var isStreaming: Bool = false
    var bitrate: String = ""
    var latency: String = ""
    var duration: String = ""

    @State private var isExpanded = false
    @State private var dotPulsing = false

    var body: some View {
        VStack(spacing: 0) {
            mainRow

            if isExpanded {
                Divider()
                    .transition(.opacity)

                expandedStats
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
    }

    // MARK: - Main Row

    private var mainRow: some View {
        HStack(spacing: 12) {
            connectionIndicator

            Divider()
                .frame(height: 24)

            Label(
                "\(localIP):\(port)",
                systemImage: connectionStatus.isConnected ? "wifi" : "wifi.slash"
            )
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Spacer()

            badge(text: resolution.rawValue)

            Text("\(Int(fps)) fps")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 3) {
                Image(systemName: batteryIconName)
                    .font(.system(size: 12))
                Text("\(Int(batteryLevel * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(batteryColor)

            expandButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Connection Indicator

    private var connectionIndicator: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.3))
                    .frame(width: 8, height: 8)

                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .scaleEffect(dotPulsing ? 1.3 : 1.0)
                    .animation(
                        dotPulsing
                        ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.3),
                        value: dotPulsing
                    )
            }

            Text(statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
        }
        .onAppear { refreshPulse() }
        .onChange(of: isConnected) { _, _ in refreshPulse() }
    }

    // MARK: - Expanded Stats

    private var expandedStats: some View {
        VStack(spacing: 8) {
            if isStreaming {
                statRow(icon: "arrow.up.circle", label: "Bitrate", value: bitrate)
                statRow(icon: "gauge.with.dots.needle.67percent", label: "Latency", value: latency)
                statRow(icon: "clock.badge.checkmark", label: "Duration", value: duration)
            }
            statRow(icon: "network", label: "Address", value: "\(localIP):\(port)")
            statRow(icon: "film", label: "Resolution", value: "\(resolution.rawValue) @ \(Int(fps)) fps")
        }
    }

    // MARK: - Helpers

    private func statRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func badge(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(.systemGray5))
            .clipShape(Capsule())
    }

    private var expandButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch connectionStatus {
        case .disconnected: return .red
        case .connecting: return .orange
        case .connected: return .green
        case .error: return .red
        case .passwordRequired: return .yellow
        }
    }

    private var statusLabel: String {
        switch connectionStatus {
        case .disconnected: return "Offline"
        case .connecting: return "Connecting"
        case .connected: return "Live"
        case .error: return "Error"
        case .passwordRequired: return "Auth"
        }
    }

    private var batteryColor: Color {
        if batteryLevel < 0.2 { return .red }
        if batteryLevel < 0.5 { return .orange }
        return .green
    }

    private var isConnected: Bool {
        connectionStatus.isConnected
    }

    private func refreshPulse() {
        if isConnected {
            dotPulsing = true
        } else {
            dotPulsing = false
        }
    }
}

// MARK: - Network Stats Overlay

struct NetworkStatsOverlay: View {
    let bitrate: String
    let latency: String
    let duration: String

    var body: some View {
        HStack(spacing: 16) {
            statItem(icon: "arrow.up.circle.fill", value: bitrate, color: .green)
            statItem(icon: "gauge.with.dots.needle.67percent", value: latency, color: .cyan)
            statItem(icon: "clock.fill", value: duration, color: .orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }

    private func statItem(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}
