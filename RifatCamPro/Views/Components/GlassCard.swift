import SwiftUI

struct GlassCard<Header: View, Content: View>: View {

    var cornerRadii: CGFloat = Layout.cornerRadius16
    var material: Material = .ultraThinMaterial
    var padding: CGFloat = Layout.spacing16
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    init(
        cornerRadii: CGFloat = Layout.cornerRadius16,
        material: Material = .ultraThinMaterial,
        padding: CGFloat = Layout.spacing16,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadii = cornerRadii
        self.material = material
        self.padding = padding
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !(header is EmptyView) {
                header
                    .padding(.horizontal, padding)
                    .padding(.top, padding)
                    .padding(.bottom, Layout.spacing8)
            }

            content
                .padding(.horizontal, padding)
                .padding(.vertical, header is EmptyView ? padding : 0)
        }
        .background {
            RoundedRectangle(cornerRadius: cornerRadii, style: .continuous)
                .fill(material)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadii, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadii, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

// MARK: - Content-Only Initializer

extension GlassCard where Header == EmptyView {

    init(
        cornerRadii: CGFloat = Layout.cornerRadius16,
        material: Material = .ultraThinMaterial,
        padding: CGFloat = Layout.spacing16,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadii = cornerRadii
        self.material = material
        self.padding = padding
        self.header = EmptyView()
        self.content = content()
    }
}
