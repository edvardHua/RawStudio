import SwiftUI
import UIKit

struct ZoomState: Equatable {
    var scale: CGFloat = 1.0
    var offset: CGPoint = .zero
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomState: ZoomState

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 100
        scrollView.addSubview(imageView)

        // Double tap to reset
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = scrollView.viewWithTag(100) as? UIImageView else { return }
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)

        // Sync from binding (driven by the other image's zoom)
        if !context.coordinator.isUserDriving {
            scrollView.zoomScale = zoomState.scale
            scrollView.contentOffset = zoomState.offset
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomState: $zoomState)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var zoomState: ZoomState
        var isUserDriving = false

        init(zoomState: Binding<ZoomState>) {
            _zoomState = zoomState
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(100)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            isUserDriving = true
            zoomState = ZoomState(scale: scrollView.zoomScale, offset: scrollView.contentOffset)
            DispatchQueue.main.async { self.isUserDriving = false }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView.isDragging || scrollView.isDecelerating else { return }
            isUserDriving = true
            zoomState = ZoomState(scale: scrollView.zoomScale, offset: scrollView.contentOffset)
            DispatchQueue.main.async { self.isUserDriving = false }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: scrollView.viewWithTag(100))
                let size = CGSize(
                    width: scrollView.bounds.width / 3.0,
                    height: scrollView.bounds.height / 3.0
                )
                let rect = CGRect(
                    origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                    size: size
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}
