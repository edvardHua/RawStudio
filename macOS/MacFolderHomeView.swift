import SwiftUI

struct MacFolderHomeView: View {
    @State private var access = FolderAccessStore()
    @State private var photos: [FolderPhotoItem] = []
    @State private var isScanning = false
    @State private var recursive = true
    @State private var scanError: String?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(access.folderURL?.lastPathComponent ?? "No folder selected")
                        .font(.headline)
                    Text(access.folderURL?.path ?? "Choose a Finder folder to scan RAW and image files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Toggle("Include subfolders", isOn: $recursive)
                    .toggleStyle(.checkbox)
                    .disabled(isScanning)
                    .onChange(of: recursive) { _, _ in if access.folderURL != nil { startScan() } }
                Button("Choose Folder…", systemImage: "folder.badge.plus") { chooseFolder() }
                if access.folderURL != nil {
                    Button("Rescan", systemImage: "arrow.clockwise") { startScan() }
                        .disabled(isScanning)
                }
            }
            .padding(16)

            if let error = scanError ?? access.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if isScanning { ProgressView("Scanning folder…").padding(.bottom, 12) }

            if photos.isEmpty && !isScanning {
                ContentUnavailableView(
                    access.folderURL == nil ? "Choose a Photo Folder" : "No Supported Images Found",
                    systemImage: access.folderURL == nil ? "folder" : "photo",
                    description: Text(access.folderURL == nil
                                     ? "Select a folder to find RAW, JPG, HEIC, and other image files."
                                     : "This folder contains no supported image files.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(photos) { photo in
                    HStack(spacing: 12) {
                        Image(systemName: photo.kind == .rawJpgPair ? "photo.on.rectangle.angled" : "photo")
                            .foregroundStyle(photo.kind == .rawJpgPair ? .green : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(photo.title).font(.body)
                            Text(photo.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(photo.kind.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        if let image = photo.imageFile, let raw = photo.rawFile {
                            Text("\(raw.fileExtension) + \(image.fileExtension)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text((photo.rawFile ?? photo.imageFile)?.fileExtension ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
            HStack {
                Text("\(photos.count) items")
                Spacer()
                Text("RAW + JPG/HEIC pairs are matched by filename in the same folder")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.bar)
        }
        .navigationTitle("RawStudio")
        .onAppear { if access.folderURL != nil && photos.isEmpty { startScan() } }
        .onDisappear { scanTask?.cancel(); access.endAccess() }
    }

    private func chooseFolder() {
        Task {
            if let url = await access.chooseFolder() {
                photos = []
                startScan()
            }
        }
    }

    private func startScan() {
        scanTask?.cancel()
        access.endAccess()
        let currentScanID = UUID()
        scanID = currentScanID
        do {
            let root = try access.beginAccess()
            photos = []
            scanError = nil
            isScanning = true
            scanTask = Task {
                defer {
                    if scanID == currentScanID { access.endAccess(); isScanning = false }
                }
                do {
                    for try await batch in FolderPhotoScanner().scan(root: root, recursive: recursive) {
                        try Task.checkCancellation()
                        photos.append(contentsOf: batch)
                    }
                } catch is CancellationError {
                } catch {
                    scanError = error.localizedDescription
                }
            }
        } catch {
            scanError = error.localizedDescription
        }
    }
}
