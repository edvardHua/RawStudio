import SwiftUI

enum SourceFilter: CaseIterable {
    case all
    case rawJPGPairs
    case rawOnly

    var label: String {
        switch self {
        case .all:         return String(localized: "All")
        case .rawJPGPairs: return String(localized: "RAW+JPG")
        case .rawOnly:     return String(localized: "RAW")
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
    var tagStore: PhotoTagStore
    @State private var sourceFilter: SourceFilter = .all
    @State private var tagFilter: PhotoTag? = nil
    @State private var layout: GalleryLayout = .list
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showExportSheet = false
    @State private var showBatchResult = false
    @State private var batchResultMessage = ""
    @State private var navigateToCompareIndex: Int?
    @State private var showAlbumPicker = false
    @State private var visibleDate: String = ""

    @ScaledMetric(relativeTo: .body) private var capsulePadH: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var capsulePadV: CGFloat = 10
    @ScaledMetric(relativeTo: .footnote) private var smallCapsulePadH: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var smallCapsulePadV: CGFloat = 6
    @ScaledMetric(relativeTo: .body) private var headerTopSpacer: CGFloat = 120
    @ScaledMetric(relativeTo: .body) private var iconButtonSize: CGFloat = 36

    private let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var filteredPairs: [PhotoPair] {
        let _ = tagStore.changeCounter   // 订阅 tag 变化触发刷新
        let base: [PhotoPair]
        switch sourceFilter {
        case .all:         base = manager.pairs
        case .rawJPGPairs: base = manager.pairs.filter { $0.kind == .rawJpgPair }
        case .rawOnly:     base = manager.pairs.filter { $0.kind == .rawOnly }
        }
        if let tag = tagFilter {
            return base.filter { tagStore.tag(for: $0.id) == tag }
        }
        return base
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
                if !manager.isLoading || !manager.pairs.isEmpty {
                    galleryHeader
                }
            }
            .navigationBarHidden(true)
            .onChange(of: sourceFilter) {
                selectedIDs.removeAll()
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selectedIDs.isEmpty {
                    batchActionCapsules
                } else if !isSelecting {
                    galleryBottomBar
                }
            }
            .sheet(isPresented: $showExportSheet) {
                ExportOptionsSheet(
                    selectedCount: selectedIDs.count,
                    filter: sourceFilter,
                    manager: manager,
                    onCancel: { showExportSheet = false },
                    onConfirm: { options in
                        showExportSheet = false
                        executeExport(options: options)
                    }
                )
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
            .onAppear {
                // Initialize visible date from first photo
                if visibleDate.isEmpty, let first = filteredPairs.first {
                    visibleDate = formatDate(first.captureDate)
                }
            }
        }
    }

    // MARK: - Date Formatting

    private static let sectionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        Self.sectionDateFormatter.string(from: date)
    }

    // MARK: - Gallery Header

    private var galleryHeader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                // Left: Title + Date (always visible)
                VStack(alignment: .leading, spacing: 2) {
                    Text(navigationTitle)
                        .font(.largeTitle.bold())
                    if !visibleDate.isEmpty {
                        Text(visibleDate)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Right: buttons change based on mode
                HStack(spacing: 8) {
                    if isSelecting {
                        // Select All / Deselect All
                        Button {
                            if selectedIDs.count == filteredPairs.count {
                                selectedIDs.removeAll()
                            } else {
                                selectedIDs = Set(filteredPairs.map(\.id))
                            }
                        } label: {
                            Text(selectedIDs.count == filteredPairs.count
                                 ? String(localized: "Deselect All")
                                 : String(localized: "Select All"))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, capsulePadH)
                                .padding(.vertical, smallCapsulePadV)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        // Cancel
                        Button {
                            isSelecting = false
                            selectedIDs.removeAll()
                        } label: {
                            Text(String(localized: "Cancel"))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, capsulePadH)
                                .padding(.vertical, smallCapsulePadV)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Source filter menu
                        Menu {
                            Picker("Source", selection: $sourceFilter) {
                                ForEach(SourceFilter.allCases, id: \.self) { s in
                                    Text(s.label).tag(s)
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.body)
                                .frame(width: iconButtonSize, height: iconButtonSize)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)

                        // Select
                        Button {
                            isSelecting = true
                        } label: {
                            Text(String(localized: "Select"))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, capsulePadH)
                                .padding(.vertical, smallCapsulePadV)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(manager.pairs.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)

            // Source filter pills (always visible)
            HStack(spacing: 8) {
                filterCapsule(
                    label: String(localized: "All"),
                    isActive: sourceFilter == .all
                ) { sourceFilter = .all }

                filterCapsule(
                    label: String(localized: "RAW+JPG"),
                    isActive: sourceFilter == .rawJPGPairs
                ) { sourceFilter = .rawJPGPairs }

                filterCapsule(
                    label: String(localized: "RAW"),
                    isActive: sourceFilter == .rawOnly
                ) { sourceFilter = .rawOnly }

                tagFilterCapsule

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Filter Capsule

    private func filterCapsule(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(isActive ? .white : .primary)
                .padding(.horizontal, smallCapsulePadH)
                .padding(.vertical, smallCapsulePadV)
                .background(
                    isActive
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    /// 顶部 Tag 筛选胶囊 — 第 4 个 pill，点开 Menu 选颜色
    private var tagFilterCapsule: some View {
        Menu {
            Button {
                tagFilter = nil
            } label: {
                Label(String(localized: "All Tags"),
                      systemImage: tagFilter == nil ? "checkmark" : "circle")
            }
            Divider()
            ForEach(PhotoTag.allCases) { tag in
                Button {
                    tagFilter = tag
                } label: {
                    Label(tag.label,
                          systemImage: tagFilter == tag ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(tag.color)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let t = tagFilter {
                    Circle().fill(t.color).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "tag")
                        .font(.footnote)
                }
                Text(String(localized: "Tag"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(tagFilter == nil ? Color.primary : .white)
            }
            .padding(.horizontal, smallCapsulePadH)
            .padding(.vertical, smallCapsulePadV)
            .background(
                tagFilter == nil
                    ? AnyShapeStyle(.ultraThinMaterial)
                    : AnyShapeStyle(Color.accentColor),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Batch Action Capsules (Glass Style)

    private var batchActionCapsules: some View {
        HStack(spacing: 10) {
            switch sourceFilter {
            case .all:
                tagCapsuleMenu
                deleteCapsule { confirmBatchDelete() }
            case .rawJPGPairs, .rawOnly:
                batchCapsule(icon: "square.and.arrow.up", label: "Export") {
                    showExportSheet = true
                }
                tagCapsuleMenu
                deleteCapsule { confirmBatchDelete() }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func batchCapsule(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                Text(label)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, capsulePadH)
            .padding(.vertical, capsulePadV)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func deleteCapsule(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.subheadline.weight(.medium))
                Text(String(localized: "Delete"))
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.red)
            .padding(.horizontal, capsulePadH)
            .padding(.vertical, capsulePadV)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 批量打标胶囊 — 选中模式下出现
    private var tagCapsuleMenu: some View {
        Menu {
            ForEach(PhotoTag.allCases) { tag in
                Button {
                    tagStore.setTag(tag, for: Array(selectedIDs))
                } label: {
                    Label(tag.label, systemImage: "circle.fill")
                        .foregroundStyle(tag.color)
                }
            }
            Divider()
            Button(role: .destructive) {
                tagStore.setTag(nil, for: Array(selectedIDs))
            } label: {
                Label(String(localized: "Clear Tag"), systemImage: "xmark.circle")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .font(.subheadline.weight(.medium))
                Text(String(localized: "Tag"))
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, capsulePadH)
            .padding(.vertical, capsulePadV)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Toolbar (Liquid Glass Capsules)

    private var galleryBottomBar: some View {
        HStack(spacing: 12) {
            Button {
                showAlbumPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.body)
                    Text(manager.selectedAlbum?.title ?? String(localized: "Albums"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, capsulePadH)
                .padding(.vertical, capsulePadV)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    layout = layout == .list ? .grid : .list
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: layout == .list ? "square.grid.3x3" : "list.bullet")
                        .font(.body)
                    Text(layout == .list ? String(localized: "Grid View") : String(localized: "List View"))
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, capsulePadH)
                .padding(.vertical, capsulePadV)
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
                // Top spacer so first photo starts below header
                Color.clear.frame(height: headerTopSpacer)

                ForEach(Array(grouped.enumerated()), id: \.element.date) { sectionIndex, section in
                    ForEach(Array(section.pairs.enumerated()), id: \.element.id) { pairIndex, pair in
                        PhotoCardView(
                            pair: pair,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(pair.id),
                            onToggleSelect: { toggleSelect(pair.id) },
                            manager: manager,
                            presetStore: presetStore
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(pair) }
                        .onAppear {
                            if pairIndex == 0 {
                                visibleDate = section.date
                            }
                        }

                        Divider().padding(.leading, 100)
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
            LazyVStack(spacing: 2) {
                // Top spacer so first photo starts below header
                Color.clear.frame(height: headerTopSpacer)

                ForEach(Array(grouped.enumerated()), id: \.element.date) { sectionIndex, section in
                    LazyVGrid(columns: gridColumns, spacing: 2) {
                        ForEach(section.pairs) { pair in
                            PhotoGridItemView(
                                pair: pair,
                                isSelecting: isSelecting,
                                isSelected: selectedIDs.contains(pair.id),
                                manager: manager,
                                presetStore: presetStore
                            )
                            .onTapGesture { handleTap(pair) }
                        }
                    }
                    .onAppear {
                        visibleDate = section.date
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

    private func confirmBatchDelete() {
        let selected = manager.pairs.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task {
            let result = await manager.deleteAssets(selected)
            if !result.cancelled {
                isSelecting = false
                selectedIDs.removeAll()
            }
            // result.cancelled == true：用户在系统弹框点取消，保留 selecting 状态
        }
    }

    private func executeExport(options: ExportOptions) {
        let selected = manager.pairs.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task {
            let result = await manager.performExportBatch(selected, options: options)
            var msg = String(localized: "Successfully exported \(result.success), failed \(result.failed).")
            if let err = result.albumError {
                msg += "\n" + String(localized: "Album creation failed: \(err)")
            }
            batchResultMessage = msg
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
