import SwiftUI

struct PhotoCardView: View {
    let pair: PhotoPair
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
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
                    Text(pair.rawFormatLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill, in: Capsule())

                    if let result = pair.processResult {
                        Text(resultLabel(result))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
        .opacity(pair.isProcessed ? 0.5 : 1.0)
    }

    private func resultLabel(_ result: ProcessResult) -> String {
        switch result {
        case .keptJPG: return String(localized: "Kept JPG")
        case .keptRAW: return String(localized: "Kept RAW")
        case .split: return String(localized: "Split")
        }
    }
}
