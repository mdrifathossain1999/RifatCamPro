import SwiftUI

struct ResolutionPicker: View {
    @Binding var selectedResolution: VideoResolution

    private let resolutions: [ResolutionCard] = [
        ResolutionCard(
            resolution: .qvga480,
            title: "480p",
            dimensions: "640 × 480",
            useCase: "Low bandwidth, quick sharing",
            iconName: "rectangle.compress.vertical",
            color: .green
        ),
        ResolutionCard(
            resolution: .hd720,
            title: "720p",
            dimensions: "1280 × 720",
            useCase: "Video calls, casual streaming",
            iconName: "rectangle",
            color: .blue
        ),
        ResolutionCard(
            resolution: .hd1080,
            title: "1080p",
            dimensions: "1920 × 1080",
            useCase: "HD streaming, recommended",
            iconName: "rectangle.expand.vertical",
            color: .purple
        ),
        ResolutionCard(
            resolution: .uhd4K,
            title: "4K",
            dimensions: "3840 × 2160",
            useCase: "Ultra HD, maximum quality",
            iconName: "rectangle.dashed.badge.record",
            color: .orange
        )
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerView
                resolutionGrid
                recommendationNote
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .navigationTitle("Resolution")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Select Stream Resolution")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Higher resolutions deliver better quality but require more bandwidth and processing power.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    // MARK: - Resolution Grid

    private var resolutionGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 12
        ) {
            ForEach(resolutions) { card in
                ResolutionCardView(
                    card: card,
                    isSelected: selectedResolution == card.resolution
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedResolution = card.resolution
                    }
                }
            }
        }
    }

    // MARK: - Recommendation Note

    private var recommendationNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
                .font(.body)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommendation")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("1080p provides the best balance of quality and performance for most streaming scenarios. Use 4K only on fast, stable connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
    }
}

// MARK: - Resolution Card Data

struct ResolutionCard: Identifiable {
    let id = UUID()
    let resolution: VideoResolution
    let title: String
    let dimensions: String
    let useCase: String
    let iconName: String
    let color: Color
}

// MARK: - Resolution Card View

struct ResolutionCardView: View {
    let card: ResolutionCard
    let isSelected: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: card.iconName)
                        .font(.title3)
                        .foregroundStyle(isSelected ? card.color : .secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(card.color)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(card.dimensions)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(isSelected ? card.color : .secondary)
                        .monospacedDigit()
                }

                Text(card.useCase)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? AnyShapeStyle(card.color.opacity(0.08))
                    : AnyShapeStyle(Color(.secondarySystemGroupedBackground))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isSelected ? card.color : Color(.separator),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .shadow(
                color: isSelected ? card.color.opacity(0.2) : .clear,
                radius: isSelected ? 8 : 0,
                y: isSelected ? 4 : 0
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.15)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}
