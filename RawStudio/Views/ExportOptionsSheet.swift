import SwiftUI
import Photos

struct ExportOptionsSheet: View {
    let selectedCount: Int
    let filter: SourceFilter
    let manager: PhotoLibraryManager
    let onCancel: () -> Void
    let onConfirm: (ExportOptions) -> Void

    // 局部 picker tag，不污染 ExportOptions 模型
    private enum AlbumMode: Hashable {
        case none
        case createNew
        case existing
    }

    @State private var source: ExportOptions.Source = .original
    @State private var format: ExportOptions.Format = .jpg
    @State private var useHDR: Bool = false
    @State private var albumMode: AlbumMode = .none
    @State private var albumName: String = ExportOptionsSheet.defaultAlbumName()
    @State private var selectedExistingAlbumID: String? = nil
    @State private var selectedExistingAlbumTitle: String? = nil
    @State private var showAlbumPicker: Bool = false

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
                            Picker("", selection: $albumMode) {
                                Text("None").tag(AlbumMode.none)
                                Text("New").tag(AlbumMode.createNew)
                                Text("Existing").tag(AlbumMode.existing)
                            }
                            .pickerStyle(.segmented)

                            switch albumMode {
                            case .none:
                                EmptyView()

                            case .createNew:
                                TextField(String(localized: "Album Name"), text: $albumName)
                                    .textFieldStyle(.roundedBorder)
                                    .submitLabel(.done)

                            case .existing:
                                Button {
                                    showAlbumPicker = true
                                } label: {
                                    HStack {
                                        Text(String(localized: "Choose Album"))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(selectedExistingAlbumTitle ?? String(localized: "Not Selected"))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Primary button
                    Button {
                        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let albumTarget: ExportOptions.AlbumTarget
                        switch albumMode {
                        case .none:
                            albumTarget = .none
                        case .createNew:
                            albumTarget = .createNew(name: trimmed.isEmpty ? Self.defaultAlbumName() : trimmed)
                        case .existing:
                            // disabled-button 守卫保证 selectedExistingAlbumID 非 nil
                            albumTarget = .existing(id: selectedExistingAlbumID!)
                        }
                        onConfirm(ExportOptions(
                            source: filter == .rawOnly ? .fromRaw : source,
                            format: format,
                            useHDR: useHDR,
                            album: albumTarget
                        ))
                    } label: {
                        Text("Export \(selectedCount) Photos")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isExportReady ? .white : Color.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                isExportReady ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.gray.opacity(0.5)),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isExportReady)
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
            .sheet(isPresented: $showAlbumPicker) {
                let writableAlbums = manager.albums.filter { $0.collection.canPerform(.addContent) }
                AlbumPickerView(
                    albums: writableAlbums,
                    selectedAlbumID: selectedExistingAlbumID,
                    onSelect: { album in
                        selectedExistingAlbumID = album.id
                        selectedExistingAlbumTitle = album.title
                    },
                    isPresented: $showAlbumPicker
                )
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

    private var isExportReady: Bool {
        switch albumMode {
        case .none, .createNew: return true
        case .existing: return selectedExistingAlbumID != nil
        }
    }

    private static func defaultAlbumName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Export \(formatter.string(from: Date()))"
    }
}
