import SwiftUI
import UIKit

// MARK: - App Colors

extension Color {

    static let appPrimary = UIColor(named: "AppPrimary").map(Color.init) ?? .blue
    static let appSecondary = UIColor(named: "AppSecondary").map(Color.init) ?? .indigo
    static let appAccent = UIColor(named: "AppAccent").map(Color.init) ?? .blue
    static let appSuccess = UIColor(named: "AppSuccess").map(Color.init) ?? .green
    static let appWarning = UIColor(named: "AppWarning").map(Color.init) ?? .orange
    static let appError = UIColor(named: "AppError").map(Color.init) ?? .red
    static let appBackground = UIColor(named: "AppBackground").map(Color.init) ?? Color(.systemBackground)
    static let appSurface = UIColor(named: "AppSurface").map(Color.init) ?? Color(.secondarySystemBackground)
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - View Modifiers

extension View {

    func cardStyle(
        cornerRadius: CGFloat = Layout.cornerRadius16,
        padding: CGFloat = Layout.spacing16
    ) -> some View {
        self
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    func glassBackground(
        cornerRadius: CGFloat = Layout.cornerRadius16,
        material: Material = .ultraThinMaterial
    ) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(material)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 0.5)
                    }
            }
    }

    func hapticTap(style: UIImpactFeedbackGenerator.FeedbackStyle = .light) -> some View {
        self.onTapGesture {
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.impactOccurred()
        }
    }

    @ViewBuilder
    func shimmerLoading(_ isActive: Bool) -> some View {
        if isActive {
            self.modifier(ShimmerModifier())
        } else {
            self
        }
    }
}

// MARK: - Shimmer Modifier

private struct ShimmerModifier: ViewModifier {

    @State private var phase: CGFloat = -1.0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, phase - 0.3)),
                            .init(color: .white.opacity(0.15), location: phase),
                            .init(color: .clear, location: min(1, phase + 0.3))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .blendMode(.sourceAtop)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 2.0
                }
            }
    }
}

// MARK: - Date Formatting

extension Date {

    var shortTimeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: self)
    }

    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }

    func formatted(as style: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = style
        return formatter.string(from: self)
    }
}

// MARK: - String Validation

extension String {

    var isValidIPv4: Bool {
        let parts = split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = UInt8(part) else { return false }
            return "\(num)" == part
        }
    }

    var isValidIPv6: Bool {
        guard contains(":") else { return false }
        let parts = split(separator: ":")
        guard parts.count >= 2, parts.count <= 8 else { return false }
        return parts.allSatisfy { part in
            part.allSatisfy { $0.isHexDigit }
        }
    }

    var isValidIPAddress: Bool {
        isValidIPv4 || isValidIPv6
    }

    var isValidPort: Bool {
        guard let port = UInt16(self) else { return false }
        return port > 0 && port <= 65535
    }

    var isValidHost: Bool {
        let trimmed = trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        if trimmed.isValidIPAddress { return true }

        let hostPattern = #"^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$"#
        return trimmed.range(of: hostPattern, options: .regularExpression) != nil
    }

    var truncatedToFirstLine: String {
        components(separatedBy: "\n").first ?? self
    }
}

// MARK: - Data Size Formatting

extension Int {

    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }

    var formattedByteCountWithUnit: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}

extension UInt64 {

    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }

    var formattedBitrate: String {
        if self >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(self) / 1_000_000)
        } else if self >= 1_000 {
            return String(format: "%.0f Kbps", Double(self) / 1_000)
        }
        return "\(self) bps"
    }
}

extension Double {

    var formattedBitrate: String {
        if self >= 1_000_000 {
            return String(format: "%.1f Mbps", self / 1_000_000)
        } else if self >= 1_000 {
            return String(format: "%.0f Kbps", self / 1_000)
        }
        return String(format: "%.0f bps", self)
    }

    var formattedLatency: String {
        String(format: "%.1f ms", self * 1000)
    }

    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}

extension Data {

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - CGSize Aspect Ratio Helpers

extension CGSize {

    var aspectRatio: CGFloat {
        guard height > 0 else { return 0 }
        return width / height
    }

    var invertedAspectRatio: CGFloat {
        guard width > 0 else { return 0 }
        return height / width
    }

    func scaledToFill(targetSize: CGSize) -> CGSize {
        let widthRatio = targetSize.width / width
        let heightRatio = targetSize.height / height
        let scale = max(widthRatio, heightRatio)
        return CGSize(width: width * scale, height: height * scale)
    }

    func scaledToFit(targetSize: CGSize) -> CGSize {
        let widthRatio = targetSize.width / width
        let heightRatio = targetSize.height / height
        let scale = min(widthRatio, heightRatio)
        return CGSize(width: width * scale, height: height * scale)
    }

    func constrainedTo(maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil) -> CGSize {
        var result = self
        if let maxW = maxWidth, result.width > maxW {
            let ratio = maxW / result.width
            result.width = maxW
            result.height *= ratio
        }
        if let maxH = maxHeight, result.height > maxH {
            let ratio = maxH / result.height
            result.height = maxH
            result.width *= ratio
        }
        return result
    }

    func croppedTo(aspectRatio: CGFloat) -> CGSize {
        let targetHeight = width / aspectRatio
        if targetHeight <= height {
            return CGSize(width: width, height: targetHeight)
        }
        let targetWidth = height * aspectRatio
        return CGSize(width: targetWidth, height: height)
    }
}

// MARK: - UserDefaults Property Wrapper with Codable Support

@propertyWrapper
struct UserDefaultCodable<T: Codable>: Sendable {

    let key: String
    let defaultValue: T
    private let defaults: UserDefaults

    init(wrappedValue: T, key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = wrappedValue
        self.defaults = defaults
    }

    var wrappedValue: T {
        get {
            guard let data = defaults.data(forKey: key) else { return defaultValue }
            return (try? JSONDecoder().decode(T.self, from: data)) ?? defaultValue
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: key)
            }
        }
    }

    var projectedValue: Binding<T> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}

@propertyWrapper
struct UserDefaultRaw<T: RawRepresentable & Sendable>: Sendable where T.RawValue: Codable {

    let key: String
    let defaultValue: T
    private let defaults: UserDefaults

    init(wrappedValue: T, key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = wrappedValue
        self.defaults = defaults
    }

    var wrappedValue: T {
        get {
            guard let data = defaults.data(forKey: key),
                  let rawValue = try? JSONDecoder().decode(T.RawValue.self, from: data),
                  let value = T(rawValue: rawValue) else {
                return defaultValue
            }
            return value
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue.rawValue) {
                defaults.set(data, forKey: key)
            }
        }
    }

    var projectedValue: Binding<T> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}

// MARK: - Array Chunking

extension Array {

    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Double Clamping

extension Comparable {

    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Bundle Info

extension Bundle {

    var appName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "RifatCam Pro"
    }

    var appVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var buildNumber: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var fullVersion: String {
        "\(appVersion) (\(buildNumber))"
    }
}

// MARK: - UIColor Hex

extension UIColor {

    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}
