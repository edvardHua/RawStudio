import SwiftUI

struct PhotoCardView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    var manager: PhotoLibraryManager?
    var presetStore: RAWEditPresetStore

    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        let _ = presetStore.changeCounter   // 订阅刷新触发
        HStack(spacing: 12) {
            if isSelecting {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            // Thumbnail
            thumbnailView
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(pair.fileName)
                    .font(.body)
                    .lineLimit(1)

                Text(Self.dateFormatter.string(from: pair.captureDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(pair.formatLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill, in: Capsule())

                    if presetStore.isEdited(for: pair.id) {
                        indicatorBadge(systemName: "pencil")
                    }
                    if presetStore.hasUsedPreset(for: pair.id) {
                        indicatorBadge(systemName: "wand.and.stars")
                    }
                }
            }

            Spacer()

            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .task(id: pair.id) {
            guard let manager else { return }
            thumbnail = nil   // 清掉视图复用残留的旧图
            let side = 72 * displayScale
            let px = CGSize(width: side, height: side)
            for await img in manager.loadThumbnailStream(for: pair, size: px) {
                thumbnail = img
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    ProgressView()
                }
        }
    }

    @ViewBuilder
    private func indicatorBadge(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.5), in: Circle())
    }
}
