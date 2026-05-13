import SwiftUI

struct PhotoGridItemView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    var manager: PhotoLibraryManager?

    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Thumbnail
                thumbnailView
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                // Overlays
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        // RAW format badge
                        Text(pair.formatLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)

                        Spacer()

                        // Selection checkbox
                        if isSelecting {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : .white)
                                .shadow(radius: 2)
                        }
                    }
                    .padding(6)

                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .task(id: pair.id) {
                guard let manager else { return }
                thumbnail = nil
                let side = max(proxy.size.width, 1) * displayScale
                let px = CGSize(width: side, height: side)
                for await img in manager.loadThumbnailStream(for: pair, size: px) {
                    thumbnail = img
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
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
}
