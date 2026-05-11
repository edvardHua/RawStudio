import SwiftUI
import UIKit

struct ZoomState: Equatable {
    var scale: CGFloat = 1.0
    var offset: CGPoint = .zero
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomState: ZoomState
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    func makeUIView(context: Context) -> ZoomableScrollView {
        let view = ZoomableScrollView()
        view.zoomStateChanged = { state in
            context.coordinator.handleZoomStateChanged(state)
        }
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: ZoomableScrollView, context: Context) {
        let imageChanged = view.currentImage !== image
        if imageChanged {
            view.setImage(image)
        }

        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight

        // Sync from binding (driven externally, e.g. when switching RAW/JPG)
        if !context.coordinator.isUserDriving && !imageChanged {
            view.applyZoomState(zoomState)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomState: $zoomState)
    }

    class Coordinator {
        @Binding var zoomState: ZoomState
        var isUserDriving = false

        init(zoomState: Binding<ZoomState>) {
            _zoomState = zoomState
        }

        func handleZoomStateChanged(_ state: ZoomState) {
            isUserDriving = true
            zoomState = state
            DispatchQueue.main.async { self.isUserDriving = false }
        }
    }
}

// MARK: - UIKit ScrollView

class ZoomableScrollView: UIScrollView, UIScrollViewDelegate {

    private let imageView = UIImageView()
    private(set) var currentImage: UIImage?
    var zoomStateChanged: ((ZoomState) -> Void)?
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        delegate = self
        minimumZoomScale = 1.0
        maximumZoomScale = 5.0
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft(_:)))
        swipeLeft.direction = .left
        addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight(_:)))
        swipeRight.direction = .right
        addGestureRecognizer(swipeRight)
    }

    func setImage(_ image: UIImage) {
        currentImage = image
        imageView.image = image
        zoomScale = 1.0
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = currentImage, bounds.size != .zero else { return }

        let boundsSize = bounds.size
        let imageSize = image.size

        guard imageSize.width > 0 && imageSize.height > 0 else { return }

        // Calculate aspect-fit size
        let widthRatio = boundsSize.width / imageSize.width
        let heightRatio = boundsSize.height / imageSize.height
        let fitScale = min(widthRatio, heightRatio)

        let fitWidth = imageSize.width * fitScale
        let fitHeight = imageSize.height * fitScale

        // Set imageView frame to the fitted size
        imageView.frame = CGRect(
            x: 0, y: 0,
            width: fitWidth,
            height: fitHeight
        )
        contentSize = CGSize(width: fitWidth, height: fitHeight)

        // Center the image
        centerImageView()
    }

    private func centerImageView() {
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame

        if frameToCenter.size.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2.0
        } else {
            frameToCenter.origin.x = 0
        }

        if frameToCenter.size.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2.0
        } else {
            frameToCenter.origin.y = 0
        }

        imageView.frame = frameToCenter
    }

    func applyZoomState(_ state: ZoomState) {
        zoomScale = state.scale
        contentOffset = state.offset
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
        zoomStateChanged?(ZoomState(scale: zoomScale, offset: contentOffset))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isDragging || isDecelerating else { return }
        zoomStateChanged?(ZoomState(scale: zoomScale, offset: contentOffset))
    }

    // MARK: - Gestures

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.0 {
            setZoomScale(1.0, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(
                width: bounds.width / 3.0,
                height: bounds.height / 3.0
            )
            let rect = CGRect(
                origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                size: size
            )
            zoom(to: rect, animated: true)
        }
    }

    @objc private func handleSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
        guard zoomScale <= 1.0 else { return }
        onSwipeLeft?()
    }

    @objc private func handleSwipeRight(_ gesture: UISwipeGestureRecognizer) {
        guard zoomScale <= 1.0 else { return }
        onSwipeRight?()
    }
}
