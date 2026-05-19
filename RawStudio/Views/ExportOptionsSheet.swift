import SwiftUI

struct ExportOptionsSheet: View {
    let selectedCount: Int
    let filter: SourceFilter
    let onCancel: () -> Void
    let onConfirm: (ExportOptions) -> Void

    @State private var source: ExportOptions.Source = .original
    @State private var format: ExportOptions.Format = .jpg
    @State private var useHDR: Bool = false
    @State private var saveToNewAlbum: Bool = false
    @State private var albumName: String = ExportOptionsSheet.defaultAlbumName()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Source — 仅 RAW+JPG 筛选显示
                    if filter == .rawJPGPairs {
                        sectionGroup(title: String(localized: "Source")) {
                            Picker("", selection: $source) {
                                Text("Keep Original").tag(ExportOptions.Source.original)
                                Text("Render from RAW").tag(ExportOptions.Source.fromRaw)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    // Format
                    sectionGroup(title: String(localized: "Format")) {
                        Picker("", selection: $format) {
                            Text("JPG").tag(ExportOptions.Format.jpg)
                            Text("HEIC").tag(ExportOptions.Format.heic)
                        }
                        .pickerStyle(.segmented)
                    }

                    // HDR
                    sectionGroup(title: String(localized: "HDR")) {
                        Toggle(isOn: $useHDR) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Export as HDR")
                                    .font(.body)
                                Text("Ultra HDR JPEG / Adaptive HEIC")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Save To
                    sectionGroup(title: String(localized: "Save To")) {
                        VStack(spacing: 12) {
                            Toggle(String(localized: "Save to New Album"), isOn: $saveToNewAlbum)
                            if saveToNewAlbum {
                                TextField(String(localized: "Album Name"), text: $albumName)
                                    .textFieldStyle(.roundedBorder)
                                    .submitLabel(.done)
                            }
                        }
                    }

                    // Primary button
                    Button {
                        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalAlbumName: String? = saveToNewAlbum
                            ? (trimmed.isEmpty ? Self.defaultAlbumName() : trimmed)
                            : nil
                        onConfirm(ExportOptions(
                            source: filter == .rawOnly ? .fromRaw : source,
                            format: format,
                            useHDR: useHDR,
                            newAlbumName: finalAlbumName
                        ))
                    } label: {
                        Text("Export \(selectedCount) Photos")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.vertical, 16)
            }
            .navigationTitle(String(localized: "Export Options"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel"), action: onCancel)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func sectionGroup<Content: View>(
        title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
        }
    }

    private static func defaultAlbumName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Export \(formatter.string(from: Date()))"
    }
}
