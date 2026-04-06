import SwiftUI

enum GalleryFilter: CaseIterable {
    case all
    case unprocessed
    case processed

    var label: String {
        switch self {
        case .all: return String(localized: "All")
        case .unprocessed: return String(localized: "Unprocessed")
        case .processed: return String(localized: "Processed")
        }
    }
}

enum GalleryLayout: String {
    case list
    case grid
}

struct GalleryView: View {
    @Bindable var manager: PhotoLibraryManager
    @State private var filter: GalleryFilter = .unprocessed
    @State private var layout: GalleryLayout = .grid
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchConfirm = false
    @State private var pendingBatchAction: SplitAction?
    @State private var showBatchResult = false
    @State private var batchResultMessage = ""
    @State private var navigateToCompareIndex: Int?
    @State private var showAlbumPicker = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var filteredPairs: [PhotoPair] {
        switch filter {
        case .all: return manager.pairs
        case .unprocessed: return manager.unprocessedPairs
        case .processed: return manager.processedPairs
        }
    }

    private var navigationTitle: String {
        if let album = manager.selectedAlbum {
            return album.title
        }
        return String(localized: "All Photos")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if manager.isLoading {
                    ProgressView("Scanning library...")
                } else if manager.pairs.isEmpty {
                    EmptyStateView()
                } else {
                    if layout == .list {
                        listContent
                    } else {
                        gridContent
                    }
                }

                if manager.isBatchProcessing {
                    BatchProgressView(current: manager.batchProgress, total: manager.batchTotal)
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelecting {
                        Button(selectedIDs.count == filteredPairs.count ? "Deselect All" : "Select All") {
                            if selectedIDs.count == filteredPairs.count {
                                selectedIDs.removeAll()
                            } else {
                                selectedIDs = Set(filteredPairs.map(\.id))
                            }
                        }
                    } else {
                        Menu {
                            // Album picker
                            Section {
                                Button {
                                    showAlbumPicker = true
                                } label: {
                                    Label("Albums", systemImage: "folder")
                                }

                                if manager.selectedAlbum != nil {
                                    Button {
                                        Task { await manager.selectAlbum(nil) }
                                    } label: {
                                        Label("All Photos", systemImage: "photo.on.rectangle")
                                    }
                                }
                            }

                            // Filter
                            Section {
                                Picker("Filter", selection: $filter) {
                                    ForEach(GalleryFilter.allCases, id: \.self) { f in
                                        Text(f.label).tag(f)
                                    }
                                }
                            }

                            // Layout toggle
                            Section {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        layout = layout == .list ? .grid : .list
                                    }
                                } label: {
                                    Label(
                                        layout == .list
                                            ? String(localized: "Grid View")
                                            : String(localized: "List View"),
                                        systemImage: layout == .list
                                            ? "square.grid.3x3"
                                            : "list.bullet"
                                    )
                                }
                            }
                        } label: {
                            Label("Menu", systemImage: "ellipsis.circle")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedIDs.removeAll()
                        }
                    }
                    .disabled(manager.pairs.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selectedIDs.isEmpty {
                    ActionBarView(
                        onKeepJPG: { confirmBatch(.keepJPG) },
                        onKeepRAW: { confirmBatch(.keepRAW) },
                        onSplit: { confirmBatch(.split) }
                    )
                }
            }
            .alert("Confirm", isPresented: $showBatchConfirm) {
                Button("Confirm", role: .destructive) {
                    executeBatch()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(batchConfirmMessage)
            }
            .alert("Done", isPresented: $showBatchResult) {
                Button("OK") {
                    isSelecting = false
                    selectedIDs.removeAll()
                }
            } message: {
                Text(batchResultMessage)
            }
            .navigationDestination(item: $navigateToCompareIndex) { index in
                CompareView(
                    manager: manager,
                    pairs: filteredPairs.filter { !$0.isProcessed },
                    startIndex: index
                )
            }
            .sheet(isPresented: $showAlbumPicker) {
                AlbumPickerView(
                    albums: manager.albums,
                    selectedAlbumID: manager.selectedAlbum?.id,
                    onSelect: { album in
                        Task { await manager.selectAlbum(album) }
                    },
                    isPresented: $showAlbumPicker
                )
            }
        }
    }

    // MARK: - List Layout

    private var listContent: some View {
        let grouped = manager.groupedByDate(filteredPairs)
        return List {
            ForEach(grouped, id: \.date) { section in
                Section(header: Text(section.date)) {
                    ForEach(section.pairs) { pair in
                        PhotoCardView(
                            pair: pair,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(pair.id),
                            onToggleSelect: { toggleSelect(pair.id) },
                            manager: manager
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(pair) }
                        .listRowInsets(EdgeInsets())
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Grid Layout

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 2) {
                ForEach(filteredPairs) { pair in
                    PhotoGridItemView(
                        pair: pair,
                        isSelecting: isSelecting,
                        isSelected: selectedIDs.contains(pair.id),
                        manager: manager
                    )
                    .onTapGesture { handleTap(pair) }
                }
            }
        }
    }

    // MARK: - Shared Actions

    private func toggleSelect(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func handleTap(_ pair: PhotoPair) {
        if isSelecting {
            toggleSelect(pair.id)
        } else if !pair.isProcessed {
            let unprocessed = filteredPairs.filter { !$0.isProcessed }
            if let idx = unprocessed.firstIndex(where: { $0.id == pair.id }) {
                navigateToCompareIndex = idx
            }
        }
    }

    private var batchConfirmMessage: String {
        guard let action = pendingBatchAction else { return "" }
        let count = selectedIDs.count
        let actionLine: String
        switch action {
        case .keepJPG: actionLine = String(localized: "Keep JPG for \(count) photos")
        case .keepRAW: actionLine = String(localized: "Keep RAW for \(count) photos")
        case .split: actionLine = String(localized: "Split \(count) photos")
        }
        return actionLine + "\n" + String(localized: "Original RAW+JPG paired photos will be deleted. They can be recovered from Recently Deleted.")
    }

    private func confirmBatch(_ action: SplitAction) {
        pendingBatchAction = action
        showBatchConfirm = true
    }

    private func executeBatch() {
        guard let action = pendingBatchAction else { return }
        let selected = manager.pairs.filter { selectedIDs.contains($0.id) }
        Task {
            let result = await manager.performBatchAction(action, on: selected)
            batchResultMessage = String(localized: "Successfully processed \(result.success), failed \(result.failed).")
            showBatchResult = true
        }
    }
}

// MARK: - Album Picker

struct AlbumPickerView: View {
    let albums: [Album]
    let selectedAlbumID: String?
    let onSelect: (Album) -> Void
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(albums, id: \.id) { album in
                        albumRow(album)
                        Divider().padding(.leading)
                    }
                }
            }
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }

    private func albumRow(_ album: Album) -> some View {
        Button {
            onSelect(album)
            isPresented = false
        } label: {
            HStack {
                Image(systemName: "folder")
                Text(album.title)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedAlbumID == album.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }
}
