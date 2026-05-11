import SwiftUI

struct PhotoGridItemView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    var manager: PhotoLibraryManager?

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Thumbnail
            thumbnailView
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()

            // Overlays
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    // RAW format badge
                    Text(pair.rawFormatLabel)
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
            if let manager, thumbnail == nil {
                thumbnail = await manager.loadThumbnail(for: pair)
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
}
