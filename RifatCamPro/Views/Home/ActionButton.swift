import SwiftUI

struct ActionButton: View {
    let icon: String
    let label: String
    var color: Color = .accentColor
    var isActive: Bool = false
    var isToggle: Bool = false
    var isEnabled: Bool = true
    var activeIcon: String?
    var action: () -> Void

    @State private var isPressed = false
    @State private var glowAnimating = false

    private var displayIcon: String {
        if isToggle && isActive {
            return activeIcon ?? "\(icon).fill"
        }
        return icon
    }

    var body: some View {
        Button(action: triggerAction) {
            VStack(spacing: 6) {
                ZStack {
                    if isToggle && isActive {
                        Circle()
                            .fill(color.opacity(0.35))
                            .frame(width: 56, height: 56)
                            .blur(radius: 10)
                            .scaleEffect(glowAnimating ? 1.3 : 0.9)
                            .animation(
                                .easeInOut(duration: 1.4)
                                    .repeatForever(autoreverses: true),
                                value: glowAnimating
                            )
                    }

                    Circle()
                        .fill(isToggle && isActive
                              ? AnyShapeStyle(color.opacity(0.2))
                              : AnyShapeStyle(Color(.systemGray6)))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isToggle && isActive
                                    ? color.opacity(0.45)
                                    : Color(.systemGray4).opacity(0.3),
                                    lineWidth: 1
                                )
                        )

                    Image(systemName: displayIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isToggle && isActive ? color : color.opacity(0.75))
                }
                .scaleEffect(isPressed ? 0.82 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.35)
        .sensoryFeedback(.selection, trigger: isActive)
        .onAppear { refreshGlow() }
        .onChange(of: isActive) { _, _ in refreshGlow() }
    }

    private func triggerAction() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        withAnimation(.spring(response: 0.14, dampingFraction: 0.5)) {
            isPressed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isPressed = false
            }
        }

        action()
    }

    private func refreshGlow() {
        if isToggle && isActive {
            glowAnimating = true
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                glowAnimating = false
            }
        }
    }
}

// MARK: - Preset Buttons

extension ActionButton {

    static func streamButton(isStreaming: Bool, isEnabled: Bool = true, action: @escaping () -> Void) -> ActionButton {
        ActionButton(
            icon: "play.fill",
            label: isStreaming ? "Stop" : "Stream",
            color: isStreaming ? .red : .green,
            isActive: isStreaming,
            isToggle: true,
            isEnabled: isEnabled,
            activeIcon: "stop.fill",
            action: action
        )
    }

    static func switchCamera(action: @escaping () -> Void) -> ActionButton {
        ActionButton(
            icon: "camera.rotate",
            label: "Switch",
            color: .white,
            action: action
        )
    }

    static func torchButton(isOn: Bool, action: @escaping () -> Void) -> ActionButton {
        ActionButton(
            icon: "flashlight.off.fill",
            label: "Torch",
            color: .yellow,
            isActive: isOn,
            isToggle: true,
            activeIcon: "flashlight.on.fill",
            action: action
        )
    }

    static func settingsButton(action: @escaping () -> Void) -> ActionButton {
        ActionButton(
            icon: "gearshape",
            label: "Settings",
            color: .gray,
            action: action
        )
    }

    static func qrCodeButton(action: @escaping () -> Void) -> ActionButton {
        ActionButton(
            icon: "qrcode",
            label: "Pair",
            color: .cyan,
            action: action
        )
    }
}
