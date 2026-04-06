import SwiftUI
import Photos

struct CompareView: View {
    @Bindable var manager: PhotoLibraryManager
    let pairs: [PhotoPair]
    let startIndex: Int

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
    @Environment(\.dismiss) private var dismiss

    init(manager: PhotoLibraryManager, pairs: [PhotoPair], startIndex: Int) {
        self.manager = manager
        self.pairs = pairs
        self.startIndex = startIndex
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

                        // Top-left format badge
                        VStack {
                            HStack {
                                formatBadge
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)

                            Spacer()

                            // Bottom metadata bar
                            if let metadata = currentMetadata {
                                metadataBar(metadata)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
            .navigationTitle("\(currentIndex + 1) / \(pairs.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Only show toggle when pair has both RAW and JPG
                    if let pair = currentPair, !pair.isRawOnly, !isLoadingImages, !isProcessing {
                        Button {
                            zoomState = ZoomState()
                            showingRAW.toggle()
                        } label: {
                            Text(showingRAW ? "JPG" : "RAW")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let pair = currentPair, !isLoadingImages, !isProcessing {
                    if pair.isRawOnly {
                        // RAW-only: show two HDR buttons
                        ActionBarView(
                            onExportHDR: { exportHDR() },
                            onExportUltraHDR: { exportUltraHDR() }
                        )
                    } else {
                        // RAW+JPG pair: always show keep/split + HDR menu
                        ActionBarView(
                            onKeepJPG: { performAction(.keepJPG) },
                            onKeepRAW: { performAction(.keepRAW) },
                            onSplit: { performAction(.split) },
                            onExportHDR: { exportHDR() },
                            onExportUltraHDR: { exportUltraHDR() }
                        )
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
    }

    // MARK: - Format Badge

    private var formatBadge: some View {
        let isRAW = showingRAW
        let label = isRAW ? "RAW" : "JPG"
        let badgeColor: Color = isRAW
            ? Color(red: 0.4, green: 0.8, blue: 0.5)   // soft green
            : Color(red: 1.0, green: 0.85, blue: 0.35)  // soft yellow

        return Text(label)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(badgeColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }

    // MARK: - Metadata Bar

    private func metadataBar(_ metadata: PhotoMetadata) -> some View {
        VStack(spacing: 6) {
            // Camera model + dimensions + file size
            HStack(spacing: 12) {
                if let model = metadata.cameraModel {
                    metadataItem(icon: "camera", text: model)
                }
                metadataItem(icon: "aspectratio", text: metadata.dimensions)
                metadataItem(icon: "doc", text: metadata.fileSizeText)
            }

            // Shooting params
            HStack(spacing: 16) {
                if let aperture = metadata.aperture {
                    metadataChip(text: String(format: "ƒ/%.1f", aperture))
                }
                if let shutter = metadata.shutterSpeed {
                    metadataChip(text: shutter)
                }
                if let iso = metadata.iso {
                    metadataChip(text: "ISO \(iso)")
                }
                if let fl = metadata.focalLength {
                    metadataChip(text: String(format: "%.0fmm", fl))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func metadataItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private func metadataChip(text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Data Loading

    private func loadImages() async {
        guard let pair = currentPair else { return }
        isLoadingImages = true
        do {
            // Always load RAW
            let rawResult = try await manager.loadRAWImageWithMetadata(for: pair)
            rawImage = rawResult.0
            rawMetadata = rawResult.1

            // Load JPG only if available
            if let jpgResult = try await manager.loadJPGImageWithMetadata(for: pair) {
                jpgImage = jpgResult.0
                jpgMetadata = jpgResult.1
            } else {
                jpgImage = nil
                jpgMetadata = nil
            }

            showingRAW = true
            zoomState = ZoomState()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isLoadingImages = false
    }

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
                toastMessage = String(localized: "\(actionLabel) · Original can be recovered from Recently Deleted")
                withAnimation { showToast = true }

                try? await Task.sleep(for: .seconds(1.5))
                moveToNextOrDismiss()
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func moveToNextOrDismiss() {
        let remaining = pairs.filter { !$0.isProcessed }
        if remaining.isEmpty {
            dismiss()
            return
        }
        let nextIndex = min(currentIndex, remaining.count - 1)
        navigateTo(nextIndex)
    }

    private func exportHDR() {
        guard let pair = currentPair, !isProcessing else { return }
        Task {
            isProcessing = true
            processingMessage = String(localized: "Exporting HDR...")

            do {
                try await manager.exportAdaptiveHDR(for: pair)
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
                try await manager.exportUltraHDRJPEG(for: pair)
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

    private func navigateTo(_ index: Int) {
        guard !isProcessing else { return }
        currentIndex = index
        Task {
            await loadImages()
        }
    }
}
