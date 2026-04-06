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

struct GalleryView: View {
    @Bindable var manager: PhotoLibraryManager
    @State private var filter: GalleryFilter = .unprocessed
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchConfirm = false
    @State private var pendingBatchAction: SplitAction?
    @State private var showBatchResult = false
    @State private var batchResultMessage = ""
    @State private var navigateToCompareIndex: Int?

    private var filteredPairs: [PhotoPair] {
        switch filter {
        case .all: return manager.pairs
        case .unprocessed: return manager.unprocessedPairs
        case .processed: return manager.processedPairs
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if manager.isLoading {
                    ProgressView("Scanning library...")
                } else if manager.pairs.isEmpty {
                    EmptyStateView()
                } else {
                    listContent
                }

                if manager.isBatchProcessing {
                    BatchProgressView(current: manager.batchProgress, total: manager.batchTotal)
                }
            }
            .navigationTitle("RAW+JPG")
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
                            Picker("Filter", selection: $filter) {
                                ForEach(GalleryFilter.allCases, id: \.self) { f in
                                    Text(f.label).tag(f)
                                }
                            }
                        } label: {
                            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
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
        }
    }

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
                            onToggleSelect: {
                                if selectedIDs.contains(pair.id) {
                                    selectedIDs.remove(pair.id)
                                } else {
                                    selectedIDs.insert(pair.id)
                                }
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelecting {
                                if selectedIDs.contains(pair.id) {
                                    selectedIDs.remove(pair.id)
                                } else {
                                    selectedIDs.insert(pair.id)
                                }
                            } else if !pair.isProcessed {
                                let unprocessed = filteredPairs.filter { !$0.isProcessed }
                                if let idx = unprocessed.firstIndex(where: { $0.id == pair.id }) {
                                    navigateToCompareIndex = idx
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                    }
                }
            }
        }
        .listStyle(.plain)
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
