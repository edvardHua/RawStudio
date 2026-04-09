import SwiftUI

enum SourceFilter: CaseIterable {
    case rawJPGPairs
    case rawOnly

    var label: String {
        switch self {
        case .rawJPGPairs: return String(localized: "RAW+JPG")
        case .rawOnly: return String(localized: "RAW Only")
        }
    }
}

enum GalleryLayout: String {
    case list
    case grid
}

struct GalleryView: View {
    @Bindable var manager: PhotoLibraryManager
    var presetStore: RAWEditPresetStore
    @State private var sourceFilter: SourceFilter = .rawJPGPairs
    @State private var layout: GalleryLayout = .list
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchConfirm = false
    @State private var pendingBatchAction: SplitAction?
    @State private var pendingBatchHDRType: String?
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
        switch sourceFilter {
        case .rawJPGPairs: return manager.pairs.filter { !$0.isRawOnly }
        case .rawOnly: return manager.pairs.filter { $0.isRawOnly }
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
                if manager.isLoading && manager.pairs.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Scanning library...")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("This may take a moment for large libraries")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !manager.isLoading && filteredPairs.isEmpty {
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
            .overlay(alignment: .top) {
                // Floating source filter capsules
                if !manager.isLoading || !manager.pairs.isEmpty {
                    sourceFilterCapsules
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: sourceFilter) {
                selectedIDs.removeAll()
            }
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
                    // Batch selection mode: show action buttons
                    if sourceFilter == .rawOnly {
                        ActionBarView(
                            onExportHDR: { confirmBatchHDR("adaptiveHDR") },
                            onExportUltraHDR: { confirmBatchHDR("ultraHDR") }
                        )
                    } else {
                        ActionBarView(
                            onKeepJPG: { confirmBatch(.keepJPG) },
                            onKeepRAW: { confirmBatch(.keepRAW) },
                            onExportHDR: { confirmBatchHDR("adaptiveHDR") },
                            onExportUltraHDR: { confirmBatchHDR("ultraHDR") }
                        )
                    }
                } else if !isSelecting {
                    // Normal mode: show bottom toolbar with Albums + Layout toggle
                    galleryBottomBar
                }
            }
            .alert("Confirm", isPresented: $showBatchConfirm) {
                Button("Confirm") {
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
                    pairs: filteredPairs,
                    startIndex: index,
                    presetStore: presetStore
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

    // MARK: - Source Filter Capsules (Floating Top)

    private var sourceFilterCapsules: some View {
        HStack(spacing: 8) {
            filterCapsule(label: String(localized: "RAW+JPG"), isActive: sourceFilter == .rawJPGPairs) {
                sourceFilter = .rawJPGPairs
            }
            filterCapsule(label: String(localized: "RAW Only"), isActive: sourceFilter == .rawOnly) {
                sourceFilter = .rawOnly
            }
            Spacer()
        }
    }

    private func filterCapsule(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isActive
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Toolbar (Liquid Glass Capsules)

    private var galleryBottomBar: some View {
        HStack(spacing: 12) {
            // Albums capsule
            Button {
                showAlbumPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 16, weight: .medium))
                    Text(manager.selectedAlbum?.title ?? String(localized: "Albums"))
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            // Layout toggle capsule
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    layout = layout == .list ? .grid : .list
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: layout == .list ? "square.grid.3x3" : "list.bullet")
                        .font(.system(size: 16, weight: .medium))
                    Text(layout == .list ? String(localized: "Grid View") : String(localized: "List View"))
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - List Layout

    private var listContent: some View {
        let grouped = manager.groupedByDate(filteredPairs)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(grouped, id: \.date) { section in
                    Section {
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

                            Divider().padding(.leading, 100)
                        }
                    } header: {
                        Text(section.date)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                    }
                }

                scanningMoreIndicator
            }
        }
    }

    // MARK: - Grid Layout

    private var gridContent: some View {
        let grouped = manager.groupedByDate(filteredPairs)
        return ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(grouped, id: \.date) { section in
                    Section {
                        LazyVGrid(columns: gridColumns, spacing: 2) {
                            ForEach(section.pairs) { pair in
                                PhotoGridItemView(
                                    pair: pair,
                                    isSelecting: isSelecting,
                                    isSelected: selectedIDs.contains(pair.id),
                                    manager: manager
                                )
                                .onTapGesture { handleTap(pair) }
                            }
                        }
                    } header: {
                        Text(section.date)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                    }
                }

                scanningMoreIndicator
            }
        }
    }

    @ViewBuilder
    private var scanningMoreIndicator: some View {
        if manager.isScanningMore {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Scanning more photos... \(manager.scanProgress)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
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
        } else {
            if let idx = filteredPairs.firstIndex(where: { $0.id == pair.id }) {
                navigateToCompareIndex = idx
            }
        }
    }

    private var batchConfirmMessage: String {
        let count = selectedIDs.count
        if let hdrType = pendingBatchHDRType {
            let format = hdrType == "adaptiveHDR"
                ? String(localized: "Adaptive HDR (HEIF)")
                : String(localized: "Ultra HDR (JPEG)")
            return String(localized: "Export \(count) photos as \(format)")
        }
        guard let action = pendingBatchAction else { return "" }
        let actionLine: String
        switch action {
        case .keepJPG: actionLine = String(localized: "Keep JPG for \(count) photos")
        case .keepRAW: actionLine = String(localized: "Keep RAW for \(count) photos")
        }
        return actionLine
    }

    private func confirmBatch(_ action: SplitAction) {
        pendingBatchAction = action
        pendingBatchHDRType = nil
        showBatchConfirm = true
    }

    private func confirmBatchHDR(_ type: String) {
        pendingBatchHDRType = type
        pendingBatchAction = nil
        showBatchConfirm = true
    }

    private func executeBatch() {
        let selected = manager.pairs.filter { selectedIDs.contains($0.id) }

        if let hdrType = pendingBatchHDRType {
            Task {
                manager.isBatchProcessing = true
                manager.batchTotal = selected.count
                manager.batchProgress = 0
                var success = 0
                var failed = 0

                for pair in selected {
                    do {
                        if hdrType == "adaptiveHDR" {
                            try await manager.exportAdaptiveHDR(for: pair)
                        } else {
                            try await manager.exportUltraHDRJPEG(for: pair)
                        }
                        success += 1
                    } catch {
                        failed += 1
                    }
                    manager.batchProgress += 1
                }

                manager.isBatchProcessing = false
                batchResultMessage = String(localized: "Successfully processed \(success), failed \(failed).")
                showBatchResult = true
            }
        } else if let action = pendingBatchAction {
            Task {
                let result = await manager.performBatchAction(action, on: selected)
                batchResultMessage = String(localized: "Successfully processed \(result.success), failed \(result.failed).")
                showBatchResult = true
            }
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
