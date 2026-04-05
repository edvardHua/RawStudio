import SwiftUI
import Photos

struct CompareView: View {
    @Bindable var manager: PhotoLibraryManager
    let pairs: [PhotoPair]
    let startIndex: Int

    @State private var currentIndex: Int
    @State private var jpgImage: UIImage?
    @State private var rawImage: UIImage?
    @State private var isLoadingImages = true
    @State private var isProcessing = false
    @State private var processingMessage = ""
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

    private var isLandscape: Bool {
        guard let pair = currentPair else { return false }
        let w = CGFloat(pair.asset.pixelWidth)
        let h = CGFloat(pair.asset.pixelHeight)
        return w > h
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if isLoadingImages {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Downloading from iCloud...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let jpg = jpgImage, let raw = rawImage {
                    compareContent(jpg: jpg, raw: raw)
                }
            }
            .navigationTitle("\(currentIndex + 1) / \(pairs.count)")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if currentPair != nil && !isLoadingImages && !isProcessing {
                    ActionBarView(
                        onKeepJPG: { performAction(.keepJPG) },
                        onKeepRAW: { performAction(.keepRAW) },
                        onSplit: { performAction(.split) }
                    )
                }
            }
            .toast(message: toastMessage, isPresented: $showToast)
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "An unknown error occurred.")
            }
            .gesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        if zoomState.scale <= 1.0 && !isProcessing {
                            if value.translation.width < -50 && currentIndex < pairs.count - 1 {
                                navigateTo(currentIndex + 1)
                            } else if value.translation.width > 50 && currentIndex > 0 {
                                navigateTo(currentIndex - 1)
                            }
                        }
                    }
            )
            .task {
                await loadImages()
            }

            // Processing overlay — covers content but NOT navigation bar
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

    @ViewBuilder
    private func compareContent(jpg: UIImage, raw: UIImage) -> some View {
        if isLandscape {
            // Landscape: vertical stack (top/bottom)
            VStack(spacing: 1) {
                imagePanel(image: raw, label: "RAW")
                imagePanel(image: jpg, label: "JPG")
            }
        } else {
            // Portrait: horizontal stack (left/right)
            HStack(spacing: 1) {
                imagePanel(image: raw, label: "RAW")
                imagePanel(image: jpg, label: "JPG")
            }
        }
    }

    private func imagePanel(image: UIImage, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            ZoomableImageView(image: image, zoomState: $zoomState)

            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(8)
        }
    }

    private func loadImages() async {
        guard let pair = currentPair else { return }
        isLoadingImages = true
        do {
            async let jpgLoad = manager.loadFullImage(for: pair.jpgResource)
            async let rawLoad = manager.loadFullImage(for: pair.rawResource)
            let (jpg, raw) = try await (jpgLoad, rawLoad)
            jpgImage = jpg
            rawImage = raw
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
            case .keepJPG: processingMessage = "Saving JPG..."
            case .keepRAW: processingMessage = "Saving RAW..."
            case .split: processingMessage = "Splitting photos..."
            }

            do {
                try await manager.performAction(action, on: pair)
                isProcessing = false

                let actionLabel: String
                switch action {
                case .keepJPG: actionLabel = "Kept JPG"
                case .keepRAW: actionLabel = "Kept RAW"
                case .split: actionLabel = "Split into two photos"
                }
                toastMessage = "\(actionLabel) · Original can be recovered from Recently Deleted"
                withAnimation { showToast = true }

                // Move to next unprocessed or dismiss
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
        // Try to stay at same index or go to next valid one
        let nextIndex = min(currentIndex, remaining.count - 1)
        navigateTo(nextIndex)
    }

    private func navigateTo(_ index: Int) {
        guard !isProcessing else { return }
        currentIndex = index
        Task {
            await loadImages()
        }
    }
}
