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
    @State private var showingRAW = false
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

    var body: some View {
        ZStack {
            // Background
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
                    ZStack(alignment: .topLeading) {
                        ZoomableImageView(image: image, zoomState: $zoomState)

                        // Format label
                        Text(showingRAW ? "RAW" : "JPG")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            }
            .navigationTitle("\(currentIndex + 1) / \(pairs.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !isLoadingImages && !isProcessing {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingRAW.toggle()
                                zoomState = ZoomState()
                            }
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

    private func loadImages() async {
        guard let pair = currentPair else { return }
        isLoadingImages = true
        do {
            async let jpgLoad = manager.loadJPGImage(for: pair.jpgResource)
            async let rawLoad = manager.loadRAWImage(for: pair.rawResource)
            let (jpg, raw) = try await (jpgLoad, rawLoad)
            jpgImage = jpg
            rawImage = raw
            showingRAW = false
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

    private func navigateTo(_ index: Int) {
        guard !isProcessing else { return }
        currentIndex = index
        Task {
            await loadImages()
        }
    }
}
