import SwiftUI

struct StatsGridView: View {
    let stats: [StatItem]
    var columns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    var spacing: CGFloat = 12

    var body: some View {
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(stats) { stat in
                StatCell(stat: stat)
            }
        }
    }
}

// MARK: - Stat Item

struct StatItem: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let value: String
    let color: Color
}

// MARK: - Stat Cell

struct StatCell: View {
    let stat: StatItem
    @State private var displayedValue: String
    @State private var isAnimating = false

    init(stat: StatItem) {
        self.stat = stat
        _displayedValue = State(initialValue: stat.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: stat.icon)
                    .font(.caption)
                    .foregroundStyle(stat.color)
                    .frame(width: 16, height: 16)
                Text(stat.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(displayedValue)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(stat.color.opacity(0.15), lineWidth: 1)
        )
        .onChange(of: stat.value) { _, newValue in
            withAnimation(.snappy(duration: 0.25)) {
                displayedValue = newValue
                isAnimating = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isAnimating = false
            }
        }
    }
}

// MARK: - Compact Stats Row (for overlays)

struct CompactStatsRow: View {
    let stats: [StatItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stats) { stat in
                    CompactStatChip(stat: stat)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Compact Stat Chip

struct CompactStatChip: View {
    let stat: StatItem
    @State private var displayedValue: String

    init(stat: StatItem) {
        self.stat = stat
        _displayedValue = State(initialValue: stat.value)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: stat.icon)
                .font(.caption2)
                .foregroundStyle(stat.color)
            Text(displayedValue)
                .font(.caption2)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(stat.color.opacity(0.2), lineWidth: 0.5)
        )
        .onChange(of: stat.value) { _, newValue in
            withAnimation(.snappy(duration: 0.2)) {
                displayedValue = newValue
            }
        }
    }
}

// MARK: - Double Value Stat Item Extension

extension StatItem {
    static func formatted(
        icon: String,
        label: String,
        doubleValue: Double,
        format: StatValueFormat = .auto,
        color: Color = .primary
    ) -> StatItem {
        StatItem(
            icon: icon,
            label: label,
            value: StatItem.formatDouble(doubleValue, format: format),
            color: color
        )
    }
}

// MARK: - Stat Value Format

enum StatValueFormat {
    case auto
    case bitrate
    case speed
    case latency
    case percentage
    case count
    case custom(String)
}

// MARK: - Formatting Helpers

extension StatItem {
    static func formatDouble(_ value: Double, format: StatValueFormat) -> String {
        switch format {
        case .auto:
            return formatAuto(value)
        case .bitrate:
            return formatBitrate(value)
        case .speed:
            return formatSpeed(value)
        case .latency:
            return String(format: "%.1f ms", value)
        case .percentage:
            return String(format: "%.2f%%", value)
        case .count:
            return formatCount(value)
        case .custom(let template):
            return String(format: template, value)
        }
    }

    private static func formatAuto(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return String(format: "%.0f", value)
    }

    static func formatBitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
        } else if bitsPerSecond >= 1_000 {
            return String(format: "%.0f Kbps", bitsPerSecond / 1_000)
        }
        return String(format: "%.0f bps", bitsPerSecond)
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1_000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    static func formatCount(_ value: Double) -> String {
        let intVal = UInt64(value)
        if intVal >= 1_000_000 {
            return String(format: "%.1fM", Double(intVal) / 1_000_000)
        } else if intVal >= 1_000 {
            return String(format: "%.1fK", Double(intVal) / 1_000)
        }
        return "\(intVal)"
    }
}
