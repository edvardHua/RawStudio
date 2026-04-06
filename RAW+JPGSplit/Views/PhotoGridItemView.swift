import SwiftUI

struct PhotoGridItemView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    var manager: PhotoLibraryManager?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Thumbnail
            Group {
                if let thumbnail = pair.thumbnail {
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

                // Process result badge
                if let result = pair.processResult {
                    HStack {
                        Spacer()
                        Text(resultLabel(result))
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                    }
                    .padding(6)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(pair.isProcessed ? 0.5 : 1.0)
        .task {
            if let manager {
                await manager.loadThumbnail(for: pair)
            }
        }
    }

    private func resultLabel(_ result: ProcessResult) -> String {
        switch result {
        case .keptJPG: return String(localized: "Kept JPG")
        case .keptRAW: return String(localized: "Kept RAW")
        case .split: return String(localized: "Split")
        }
    }
}
