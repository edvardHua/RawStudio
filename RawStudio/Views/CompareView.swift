import SwiftUI
import Photos

struct CompareView: View {
    @Bindable var manager: PhotoLibraryManager
    @State private var pairs: [PhotoPair]
    let startIndex: Int
    var presetStore: RAWEditPresetStore
    var tagStore: PhotoTagStore

    @State private var currentIndex: Int
    @State private var jpgImage: UIImage?
    @State private var rawImage: UIImage?
    @State private var jpgMetadata: PhotoMetadata?
    @State private var rawMetadata: PhotoMetadata?
    @State private var isHDRJpgSource: Bool = false
    @State private var isLoadingImages = true
    @State private var isProcessing = false
    @State private var processingMessage = ""
    @State private var showingRAW = false
    @State private var zoomState = ZoomState()
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showEditor = false
    @State private var showJPGEditor = false
    @State private var showMoreMenu = false
    @State private var showShareSheet = false
    @State private var cachedRawData: Data?
    @State private var cachedJPGData: Data?
    @State private var currentEditParams = RAWEditParams()
    @State private var currentJPGEditParams = JPGEditParams()
    @State private var currentLayerEdits = LayerEdits()
    @State private var currentJPGLayerEdits = LayerEdits()
    @Environment(\.dismiss) private var dismiss

    @ScaledMetric(relativeTo: .body) private var capsulePadH: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var capsulePadV: CGFloat = 6
    @ScaledMetric(relativeTo: .body) private var iconButtonSize: CGFloat = 36

    init(manager: PhotoLibraryManager, pairs: [PhotoPair], startIndex: Int, presetStore: RAWEditPresetStore, tagStore: PhotoTagStore) {
        self.manager = manager
        self._pairs = State(initialValue: pairs)
        self.startIndex = startIndex
        self.presetStore = presetStore
        self.tagStore = tagStore
        self._currentIndex = State(initialValue: startIndex)
    }

    private var currentPair: PhotoPair? {
        guard currentIndex >= 0 && currentIndex < pairs.count else { return nil }
        return pairs[currentIndex]
    }

    private var currentDisplayImage: UIImage? {
        showingRAW ? rawImage : jpgImage
    }

    private var currentMetadata: PhotoMetadata? {
        showingRAW ? rawMetadata : jpgMetadata
    }

    // MARK: - Body

    var body: some View {
        let _ = tagStore.changeCounter
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            if isLoadingImages {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white)
                    Text("Downloading from iCloud...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    // Format switcher
                    formatSwitcher
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 8)

                    // Image — full screen, no rounding, no padding
                    if let image = currentDisplayImage {
                        ZoomableImageView(
                            image: image,
                            zoomState: $zoomState,
                            onSwipeLeft: {
                                if !isProcessing && currentIndex < pairs.count - 1 {
                                    navigateTo(currentIndex + 1)
                                }
                            },
                            onSwipeRight: {
                                if !isProcessing && currentIndex > 0 {
                                    navigateTo(currentIndex - 1)
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // EXIF card
                    if let metadata = currentMetadata {
                        exifCard(metadata)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }

                    // Action row
                    actionRow
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                }
            }

            // Processing overlay
            if isProcessing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)

                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(processingMessage)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .padding(32)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .navigationTitle("\(currentIndex + 1) / \(pairs.count)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !isLoadingImages && !isProcessing {
                    HStack(spacing: 2) {
                        Button { deleteOriginal() } label: {
                            Image(systemName: "trash")
                                .font(.subheadline)
                                .frame(width: iconButtonSize, height: iconButtonSize)
                        }
                        Button { shareImage() } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline)
                                .frame(width: iconButtonSize, height: iconButtonSize)
                        }
                    }
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
        }
        .toast(message: toastMessage, isPresented: $showToast)
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .task {
            await loadImages()
        }
        .navigationBarBackButtonHidden(isProcessing)
        .sheet(isPresented: $showShareSheet) {
            if let image = currentDisplayImage {
                ShareSheet(items: [image])
            }
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let rawData = cachedRawData, let pair = currentPair {
                RAWEditorView(
                    rawData: rawData,
                    resourceHint: pair.rawResource?.uniformTypeIdentifier ?? "",
                    assetID: pair.id,
                    previewImageForMask: rawImage,
                    presetStore: presetStore,
                    initialParams: currentEditParams,
                    initialLayerEdits: currentLayerEdits,
                    onDone: { params, layers in
                        currentEditParams = params
                        currentLayerEdits = layers
                        Task { await reRenderRAWPreview() }
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $showJPGEditor) {
            if let jpgData = cachedJPGData, let pair = currentPair {
                JPGEditorView(
                    imageData: jpgData,
                    assetID: pair.id,
                    presetStore: presetStore,
                    initialParams: currentJPGEditParams,
                    initialLayerEdits: currentJPGLayerEdits,
                    onDone: { params, layers, editedImage in
                        currentJPGEditParams = params
                        currentJPGLayerEdits = layers
                        if let editedImage {
                            jpgImage = editedImage
                        }
                    }
                )
            }
        }
    }

    // MARK: - Format Switcher

    @ViewBuilder
    private var formatSwitcher: some View {
        if let pair = currentPair {
            HStack {
                switch pair.kind {
                case .rawOnly:
                    // Static RAW badge（绿底）
                    Text("RAW")
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, capsulePadH)
                        .padding(.vertical, capsulePadV)
                        .background(Color(red: 0.4, green: 0.8, blue: 0.5).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 8))

                case .jpgOnly:
                    // Static format badge（灰底；显示实际格式名 HEIC/JPG/PNG…）
                    Text(pair.formatLabel)
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, capsulePadH)
                        .padding(.vertical, capsulePadV)
                        .background(Color(.systemGray3).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 8))

                case .rawJpgPair:
                    // Segmented control for JPG/RAW
                    HStack(spacing: 0) {
                        formatTab(label: "JPG", isActive: !showingRAW) {
                            zoomState = ZoomState()
                            showingRAW = false
                        }
                        formatTab(label: "RAW", isActive: showingRAW) {
                            zoomState = ZoomState()
                            showingRAW = true
                        }
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
        }
    }

    private func formatTab(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.bold())
                .foregroundStyle(.primary.opacity(isActive ? 1 : 0.5))
                .padding(.horizontal, capsulePadH)
                .padding(.vertical, capsulePadV)
                .background(
                    isActive
                        ? (label == "RAW"
                            ? Color(red: 0.4, green: 0.8, blue: 0.5).opacity(0.85)
                            : Color(red: 1.0, green: 0.85, blue: 0.35).opacity(0.85))
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - EXIF Card

    private func exifCard(_ metadata: PhotoMetadata) -> some View {
        VStack(spacing: 6) {
            // Row 1: Camera model, dimensions, file size
            HStack(spacing: 0) {
                if let model = metadata.cameraModel {
                    exifItem(text: model, bold: true)
                    exifDivider
                }
                exifItem(text: metadata.dimensions)
                exifDivider
                exifItem(text: metadata.fileSizeText)
            }

            // Row 2: Shooting params
            HStack(spacing: 0) {
                if let aperture = metadata.aperture {
                    exifItem(text: String(format: "ƒ/%.1f", aperture), bold: true)
                    exifDivider
                }
                if let shutter = metadata.shutterSpeed {
                    exifItem(text: shutter)
                    exifDivider
                }
                if let iso = metadata.iso {
                    exifItem(text: "ISO \(iso)")
                }
                if let fl = metadata.focalLength {
                    exifDivider
                    exifItem(text: String(format: "%.0fmm", fl))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func exifItem(text: String, bold: Bool = false) -> some View {
        Text(text)
            .font(bold ? .caption.weight(.semibold) : .caption)
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity)
    }

    private var exifDivider: some View {
        Rectangle()
            .fill(.primary.opacity(0.2))
            .frame(width: 1, height: 14)
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack(spacing: 0) {
            if let pair = currentPair {
                switch pair.kind {
                case .rawOnly:
                    actionItem(icon: "sun.max", label: "HDR HEIF") { exportHDR() }
                    actionDivider
                    actionItem(icon: "sun.max.fill", label: "HDR JPEG") { exportUltraHDR() }
                    actionDivider
                    tagMenuButton
                    actionDivider
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }

                case .rawJpgPair:
                    actionItem(icon: "square.and.arrow.down", label: "Save JPG") { performAction(.keepJPG) }
                    actionDivider
                    actionItem(icon: "square.and.arrow.down.fill", label: "Save RAW") { performAction(.keepRAW) }
                    actionDivider
                    tagMenuButton
                    actionDivider
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
                    actionDivider
                    // HDR menu
                    hdrMenuButton

                case .jpgOnly:
                    if isHDRJpgSource {
                        actionItem(icon: "sun.max.fill", label: "HDR JPEG") { exportUltraHDRFromImage() }
                        actionDivider
                    }
                    tagMenuButton
                    actionDivider
                    actionItem(icon: "slider.horizontal.3", label: "Edit") { openEditor() }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var tagMenuButton: some View {
        Menu {
            ForEach(PhotoTag.allCases) { tag in
                Button {
                    if let pair = currentPair {
                        tagStore.setTag(tag, for: pair.id)
                    }
                } label: {
                    Label(tag.label, systemImage: "circle.fill")
                        .foregroundStyle(tag.color)
                }
            }
            Divider()
            Button(role: .destructive) {
                if let pair = currentPair {
                    tagStore.setTag(nil, for: pair.id)
                }
            } label: {
                Label(String(localized: "Clear Tag"), systemImage: "xmark.circle")
            }
        } label: {
            VStack(spacing: 3) {
                if let pair = currentPair, let t = tagStore.tag(for: pair.id) {
                    Circle()
                        .fill(t.color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
                } else {
                    Image(systemName: "tag")
                        .font(.body)
                }
                Text(String(localized: "Tag"))
                    .font(.caption2)
            }
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity)
        }
    }

    private func actionItem(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.body)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var actionDivider: some View {
        Rectangle()
            .fill(.primary.opacity(0.15))
            .frame(width: 1, height: 28)
    }

    private var hdrMenuButton: some View {
        Menu {
            Button { exportHDR() } label: {
                Label("Adaptive HDR — Apple", systemImage: "photo.badge.checkmark")
            }
            Button { exportUltraHDR() } label: {
                Label("Ultra HDR — Universal", systemImage: "photo.badge.arrow.down")
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "sun.max.fill")
                    .font(.body)
                Text("HDR")
                    .font(.caption2)
            }
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data Loading

    private func loadImages() async {
        guard let pair = currentPair else { return }
        isLoadingImages = true
        defer { isLoadingImages = false }
        do {
            currentEditParams = presetStore.loadParams(for: pair.id)
            currentJPGEditParams = presetStore.loadJPGParams(for: pair.id)
            currentLayerEdits = presetStore.loadLayerEdits(for: pair.id)
            currentJPGLayerEdits = presetStore.loadJPGLayerEdits(for: pair.id)

            // 加载 RAW（如有）
            if let rawResource = pair.rawResource {
                let rawData = try await manager.extractRawData(for: rawResource)
                cachedRawData = rawData
                let rawResult = try await manager.loadRAWImageWithMetadata(for: pair, editParams: currentEditParams)
                rawImage = rawResult.0
                rawMetadata = rawResult.1
            } else {
                cachedRawData = nil
                rawImage = nil
                rawMetadata = nil
            }

            // 加载 JPG（如有）
            if let jpgResource = pair.jpgResource {
                let jpgData = try await manager.extractRawData(for: jpgResource)
                cachedJPGData = jpgData
                isHDRJpgSource = PhotoLibraryManager.isHDRImage(data: jpgData)
                if let jpgResult = try await manager.loadJPGImageWithMetadata(for: pair) {
                    jpgImage = jpgResult.0
                    jpgMetadata = jpgResult.1
                } else {
                    jpgImage = nil
                    jpgMetadata = nil
                }
            } else {
                cachedJPGData = nil
                isHDRJpgSource = false
                jpgImage = nil
                jpgMetadata = nil
            }

            // 按 kind 设定显示哪一面
            switch pair.kind {
            case .rawOnly:    showingRAW = true
            case .rawJpgPair: showingRAW = true     // 维持原默认行为
            case .jpgOnly:    showingRAW = false
            }
            zoomState = ZoomState()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    // MARK: - Actions

    private func performAction(_ action: SplitAction) {
        guard let pair = currentPair, !isProcessing else { return }
        Task {
            isProcessing = true
            switch action {
            case .keepJPG: processingMessage = String(localized: "Saving JPG...")
            case .keepRAW: processingMessage = String(localized: "Saving RAW...")
            }

            do {
                try await manager.performAction(action, on: pair)
                isProcessing = false

                let actionLabel: String
                switch action {
                case .keepJPG: actionLabel = String(localized: "Kept JPG")
                case .keepRAW: actionLabel = String(localized: "Kept RAW")
                }
                toastMessage = actionLabel
                withAnimation { showToast = true }
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func deleteOriginal() {
        guard let pair = currentPair, !isProcessing else { return }
        Task {
            isProcessing = true
            processingMessage = String(localized: "Deleting...")

            let success = await manager.deleteOriginal(for: pair)
            isProcessing = false

            if success {
                pairs.remove(at: currentIndex)
                moveToNextOrDismiss()
            }
        }
    }

    private func shareImage() {
        guard currentDisplayImage != nil else { return }
        showShareSheet = true
    }

    private func exportHDR() {
        guard let pair = currentPair, !isProcessing else { return }
        Task {
            isProcessing = true
            processingMessage = String(localized: "Exporting HDR...")

            do {
                try await manager.exportAdaptiveHDR(for: pair, editParams: currentEditParams)
                isProcessing = false

                toastMessage = String(localized: "HDR photo exported to library")
                withAnimation { showToast = true }
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func exportUltraHDR() {
        guard let pair = currentPair, !isProcessing else { return }
        Task {
            isProcessing = true
            processingMessage = String(localized: "Exporting Ultra HDR...")

            do {
                try await manager.exportUltraHDRJPEG(for: pair, editParams: currentEditParams)
                isProcessing = false

                toastMessage = String(localized: "Ultra HDR JPEG exported to library")
                withAnimation { showToast = true }
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func exportUltraHDRFromImage() {
        guard let pair = currentPair, !isProcessing else { return }
        Task {
            isProcessing = true
            processingMessage = String(localized: "Exporting Ultra HDR...")

            do {
                try await manager.exportUltraHDRJPEGFromImage(for: pair)
                isProcessing = false

                toastMessage = String(localized: "Ultra HDR JPEG exported to library")
                withAnimation { showToast = true }
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func moveToNextOrDismiss() {
        if pairs.isEmpty {
            dismiss()
            return
        }
        // currentIndex now points to the next item (after removal), clamp to last if needed
        let nextIndex = min(currentIndex, pairs.count - 1)
        if nextIndex != currentIndex {
            currentIndex = nextIndex
        }
        Task { await loadImages() }
    }

    private func navigateTo(_ index: Int) {
        guard !isProcessing else { return }
        currentIndex = index
        Task {
            await loadImages()
        }
    }

    private func openEditor() {
        if showingRAW {
            guard cachedRawData != nil else { return }
            showEditor = true
        } else {
            guard cachedJPGData != nil else { return }
            showJPGEditor = true
        }
    }

    private func reRenderRAWPreview() async {
        guard let pair = currentPair else { return }
        do {
            let rawResult = try await manager.loadRAWImageWithMetadata(for: pair, editParams: currentEditParams)
            rawImage = rawResult.0
            rawMetadata = rawResult.1
        } catch {
            // Silently fail
        }
    }
}

// MARK: - Share Sheet (UIActivityViewController wrapper)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
