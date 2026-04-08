import SwiftUI
import Photos

struct CompareView: View {
    @Bindable var manager: PhotoLibraryManager
    let pairs: [PhotoPair]
    let startIndex: Int
    var presetStore: RAWEditPresetStore

    @State private var currentIndex: Int
    @State private var jpgImage: UIImage?
    @State private var rawImage: UIImage?
    @State private var jpgMetadata: PhotoMetadata?
    @State private var rawMetadata: PhotoMetadata?
    @State private var isLoadingImages = true
    @State private var isProcessing = false
    @State private var processingMessage = ""
    @State private var showingRAW = true
    @State private var zoomState = ZoomState()
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showEditor = false
    @State private var showJPGEditor = false
    @State private var showExportSheet = false
    @State private var showInfoBubble = false
    @State private var cachedRawData: Data?
    @State private var cachedJPGData: Data?
    @State private var currentEditParams = RAWEditParams()
    @State private var currentJPGEditParams = JPGEditParams()
    @State private var currentLayerEdits = LayerEdits()
    @State private var currentJPGLayerEdits = LayerEdits()
    @Environment(\.dismiss) private var dismiss

    init(manager: PhotoLibraryManager, pairs: [PhotoPair], startIndex: Int, presetStore: RAWEditPresetStore) {
        self.manager = manager
        self.pairs = pairs
        self.startIndex = startIndex
        self.presetStore = presetStore
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
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoadingImages {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(.white)
                        Text("Downloading from iCloud...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image = currentDisplayImage {
                    ZStack {
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

                        // Overlays on image
                        imageOverlays
                    }
                    .onTapGesture {
                        // Tap image to dismiss info bubble
                        if showInfoBubble {
                            withAnimation(.spring(duration: 0.3)) {
                                showInfoBubble = false
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(currentIndex + 1) / \(pairs.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Segmented control for RAW/JPG (only for pairs)
                    if let pair = currentPair, !pair.isRawOnly, !isLoadingImages, !isProcessing {
                        Picker("Format", selection: $showingRAW) {
                            Text("RAW").tag(true)
                            Text("JPG").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                        .onChange(of: showingRAW) { _, _ in
                            zoomState = ZoomState()
                            withAnimation(.spring(duration: 0.3)) {
                                showInfoBubble = false
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !isLoadingImages && !isProcessing {
                    bottomToolbar
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

            // Processing overlay
            if isProcessing {
                Color.black.opacity(0.3)
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
        .navigationBarBackButtonHidden(isProcessing)
        .confirmationDialog("Export", isPresented: $showExportSheet) {
            exportSheetButtons
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let rawData = cachedRawData, let pair = currentPair {
                RAWEditorView(
                    rawData: rawData,
                    resourceHint: pair.rawResource.uniformTypeIdentifier,
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

    // MARK: - Image Overlays (format badge + info button/bubble)

    private var imageOverlays: some View {
        VStack {
            HStack(alignment: .top) {
                // Format badge (top-left)
                formatBadge

                Spacer()

                // Info button + bubble (top-right)
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            showInfoBubble.toggle()
                        }
                    } label: {
                        Text("i")
                            .font(.system(size: 14, weight: .bold, design: .serif))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.4), in: Circle())
                    }

                    if showInfoBubble, let metadata = currentMetadata {
                        infoBubble(metadata)
                            .transition(.scale(scale: 0.5, anchor: .topTrailing).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Format Badge

    private var formatBadge: some View {
        let isRAW = showingRAW
        let label = isRAW ? "RAW" : "JPG"
        let badgeColor: Color = isRAW
            ? Color(red: 0.4, green: 0.8, blue: 0.5)
            : Color(red: 1.0, green: 0.85, blue: 0.35)

        return Text(label)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(badgeColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }

    // MARK: - Info Bubble

    private func infoBubble(_ metadata: PhotoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let model = metadata.cameraModel {
                infoRow(icon: "camera", text: model)
            }
            infoRow(icon: "aspectratio", text: metadata.dimensions)
            infoRow(icon: "doc", text: metadata.fileSizeText)

            if metadata.aperture != nil || metadata.shutterSpeed != nil || metadata.iso != nil {
                Divider().overlay(.white.opacity(0.2))

                if let aperture = metadata.aperture {
                    infoRow(icon: "camera.aperture", text: String(format: "ƒ/%.1f", aperture))
                }
                if let shutter = metadata.shutterSpeed {
                    infoRow(icon: "timer", text: shutter)
                }
                if let iso = metadata.iso {
                    infoRow(icon: "light.max", text: "ISO \(iso)")
                }
                if let fl = metadata.focalLength {
                    infoRow(icon: "scope", text: String(format: "%.0f mm", fl))
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(width: 180)
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: - Bottom Toolbar (Edit / Export / Delete)

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            // Edit
            toolbarButton(icon: "slider.horizontal.3", label: "Edit") {
                openEditor()
            }

            Divider().frame(height: 30)

            // Export
            toolbarButton(icon: "square.and.arrow.up", label: "Export") {
                showExportSheet = true
            }

            Divider().frame(height: 30)

            // Delete
            toolbarButton(icon: "trash", label: "Delete") {
                deleteOriginal()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Export Sheet

    @ViewBuilder
    private var exportSheetButtons: some View {
        if let pair = currentPair {
            if !pair.isRawOnly {
                Button("Keep JPG") { performAction(.keepJPG) }
                Button("Keep RAW") { performAction(.keepRAW) }
                Button("Split (JPG + RAW)") { performAction(.split) }
            }
            Button("Adaptive HDR — Apple") { exportHDR() }
            Button("Ultra HDR — Universal") { exportUltraHDR() }
        }
    }

    // MARK: - Data Loading

    private func loadImages() async {
        guard let pair = currentPair else { return }
        isLoadingImages = true
        do {
            let rawData = try await manager.extractRawData(for: pair.rawResource)
            cachedRawData = rawData

            if let jpgResource = pair.jpgResource {
                let jpgData = try await manager.extractRawData(for: jpgResource)
                cachedJPGData = jpgData
            } else {
                cachedJPGData = nil
            }

            currentEditParams = presetStore.loadParams(for: pair.id)
            currentJPGEditParams = presetStore.loadJPGParams(for: pair.id)
            currentLayerEdits = presetStore.loadLayerEdits(for: pair.id)
            currentJPGLayerEdits = presetStore.loadJPGLayerEdits(for: pair.id)

            let rawResult = try await manager.loadRAWImageWithMetadata(for: pair, editParams: currentEditParams)
            rawImage = rawResult.0
            rawMetadata = rawResult.1

            if let jpgResult = try await manager.loadJPGImageWithMetadata(for: pair) {
                jpgImage = jpgResult.0
                jpgMetadata = jpgResult.1
            } else {
                jpgImage = nil
                jpgMetadata = nil
            }

            showingRAW = true
            zoomState = ZoomState()
            showInfoBubble = false
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isLoadingImages = false
    }

    // MARK: - Actions

    private func performAction(_ action: SplitAction) {
        guard let pair = currentPair, !isProcessing else { return }
        Task {
            isProcessing = true
            switch action {
            case .keepJPG: processingMessage = String(localized: "Saving JPG...")
            case .keepRAW: processingMessage = String(localized: "Saving RAW...")
            case .split: processingMessage = String(localized: "Splitting photos...")
            }

            do {
                try await manager.performAction(action, on: pair)
                isProcessing = false

                let actionLabel: String
                switch action {
                case .keepJPG: actionLabel = String(localized: "Kept JPG")
                case .keepRAW: actionLabel = String(localized: "Kept RAW")
                case .split: actionLabel = String(localized: "Split into two photos")
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
                toastMessage = String(localized: "Original deleted")
                withAnimation { showToast = true }

                try? await Task.sleep(for: .seconds(1.5))
                moveToNextOrDismiss()
            }
        }
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

    private func moveToNextOrDismiss() {
        if currentIndex >= pairs.count {
            dismiss()
            return
        }
        let nextIndex = min(currentIndex, pairs.count - 1)
        navigateTo(nextIndex)
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
