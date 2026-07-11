import SwiftUI

struct StatusIndicator: View {

    let status: ConnectionStatus
    var size: IndicatorSize = .small
    var showLabel: Bool = false

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: Layout.spacing8) {
            ZStack {
                if isPulsing {
                    Circle()
                        .fill(statusColor.opacity(0.35))
                        .frame(width: indicatorSize * 1.8, height: indicatorSize * 1.8)
                        .scaleEffect(isPulsing ? 1.5 : 0.8)
                        .opacity(isPulsing ? 0.0 : 0.6)
                        .animation(
                            .easeInOut(duration: 1.2).repeatForever(autoreverses: false),
                            value: isPulsing
                        )
                }

                Circle()
                    .fill(statusColor)
                    .frame(width: indicatorSize, height: indicatorSize)
                    .shadow(color: statusColor.opacity(0.5), radius: 3, y: 1)
            }

            if showLabel {
                Text(status.displayText)
                    .font(size.font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .onAppear {
            updatePulsing(for: status)
        }
        .onChange(of: status.displayText) { _, _ in
            updatePulsing(for: status)
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected:
            return Color.appSuccess
        case .connecting:
            return Color.appWarning
        case .error:
            return Color.appError
        case .disconnected:
            return Color(.systemGray3)
        case .passwordRequired:
            return Color.orange
        }
    }

    private var indicatorSize: CGFloat {
        size.rawValue
    }

    private func updatePulsing(for status: ConnectionStatus) {
        switch status {
        case .connecting:
            isPulsing = true
        default:
            isPulsing = false
        }
    }
}

// MARK: - Indicator Size

enum IndicatorSize: CGFloat {
    case small = 10
    case medium = 14
    case large = 18

    var font: Font {
        switch self {
        case .small: return .caption2
        case .medium: return .caption
        case .large: return .subheadline
        }
    }
}
