# Compare View Gestures — Edge-Only Back + Reliable Pinch Zoom

## Problem

Two distinct gesture bugs in the photo viewer (`CompareView`):

1. **Right-swipe in the middle of the screen frequently navigates back to the gallery** instead of going to the previous photo. The system's `interactivePopGestureRecognizer` (left-edge pan) competes with the in-app right-swipe and often wins for swipes that start near the left side of the screen.

2. **Pinch-to-zoom appears to work for an instant, then snaps back to 1×.** `ZoomableImageView.updateUIView` reads the `zoomState` binding and calls `applyZoomState` on every SwiftUI render. A re-render that lands between pinch-delegate callbacks (when `Coordinator.isUserDriving` has been flipped back to `false` by its `DispatchQueue.main.async`) overwrites the user's in-flight scale with a stale value.

## Goals

- Only screen-left-edge right swipes (~20pt zone) navigate back. All other right swipes go to the previous photo.
- Pinch zoom holds. Image stays at the user's chosen scale after the gesture ends. Existing reset behavior (RAW/JPG switch, photo navigate) still works.
- No regression to existing swipe-left-for-next, double-tap zoom, or pinch-then-pan.

## Non-Goals

- Replacing the flick-style swipe with a follow-finger paginated `UIScrollView` (Photos.app-style). Out of scope.
- Adding new zoom features (e.g., share-zoom-across-photos, persisted zoom level).
- Touching the gallery's `NavigationStack` itself.

## Approach (high level)

Three localized changes:

1. **`ZoomableImageView` — break the binding-driven reset.** Replace "external `zoomState` write triggers `applyZoomState`" with a `resetVersion: Int` token. Parent increments the token to request a reset; the binding is now strictly *output-only* (UIScrollView writes its state up; nothing writes it down). Add a defense-in-depth guard so that even if `applyZoomState` is ever called, it short-circuits while the scroll view is mid-gesture.

2. **`CompareView` — adopt the reset token.** Replace each `zoomState = ZoomState()` write with `zoomResetVersion += 1` and pass the token into `ZoomableImageView`.

3. **New `EdgeOnlyPopModifier`** — UIKit bridge that, on `viewWillAppear`, disables the host `UINavigationController.interactivePopGestureRecognizer` and installs a `UIScreenEdgePanGestureRecognizer(edges: .left)` that calls `popViewController` on recognition. On `viewWillDisappear`, restore the system gesture and remove our own. Apply via `.edgeOnlyPop()` modifier on `CompareView`.

## Detailed Design

### 1. `ZoomableImageView` refactor

Add a new property and a reset entry-point:

```swift
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomState: ZoomState           // OUTPUT ONLY now
    let resetVersion: Int                       // NEW — bump to reset
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?
    ...
}
```

`Coordinator` tracks the last seen reset version:

```swift
class Coordinator {
    @Binding var zoomState: ZoomState
    var lastSeenResetVersion: Int = 0
    init(zoomState: Binding<ZoomState>, initialResetVersion: Int) {
        _zoomState = zoomState
        self.lastSeenResetVersion = initialResetVersion
    }
    func handleZoomStateChanged(_ state: ZoomState) {
        zoomState = state   // up-only; no more isUserDriving dance
    }
}
```

`updateUIView` becomes:

```swift
func updateUIView(_ view: ZoomableScrollView, context: Context) {
    if view.currentImage !== image {
        view.setImage(image)   // setImage already resets to 1.0 internally
        context.coordinator.lastSeenResetVersion = resetVersion
        return
    }
    view.onSwipeLeft = onSwipeLeft
    view.onSwipeRight = onSwipeRight
    if resetVersion != context.coordinator.lastSeenResetVersion {
        context.coordinator.lastSeenResetVersion = resetVersion
        view.resetZoom(animated: true)
    }
}
```

`ZoomableScrollView.resetZoom`:

```swift
func resetZoom(animated: Bool) {
    guard !isZooming, pinchGestureRecognizer?.state != .began,
          pinchGestureRecognizer?.state != .changed else { return }
    setZoomScale(1.0, animated: animated)
}
```

Remove `Coordinator.isUserDriving` and the `DispatchQueue.main.async` flip — they are no longer needed because nothing pushes binding values back into the scrollview.

### 2. `CompareView` reset-token wiring

- Replace `@State private var zoomState = ZoomState()` — keep it. (Still used as read-only output if any caller wants it; harmless.)
- Add `@State private var zoomResetVersion: Int = 0`.
- Replace all three sites that currently write `zoomState = ZoomState()`:
  - JPG format tab tap
  - RAW format tab tap
  - End of `loadImages()` (called after photo navigate and on first load)
- Each site becomes `zoomResetVersion += 1`.
- Pass `resetVersion: zoomResetVersion` to `ZoomableImageView`.

### 3. `EdgeOnlyPopModifier` (new file `RawStudio/Views/EdgeOnlyPopGesture.swift`)

```swift
import SwiftUI
import UIKit

struct EdgeOnlyPopModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(_NavGestureBridge())
    }
}

extension View {
    func edgeOnlyPop() -> some View { modifier(EdgeOnlyPopModifier()) }
}

private struct _NavGestureBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> _Controller { _Controller() }
    func updateUIViewController(_ vc: _Controller, context: Context) {}
}

private final class _Controller: UIViewController {
    private weak var installedEdgeGesture: UIScreenEdgePanGestureRecognizer?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let nav = navigationController else { return }
        nav.interactivePopGestureRecognizer?.isEnabled = false
        if installedEdgeGesture == nil {
            installEdgeGesture(on: nav)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let nav = navigationController else { return }
        nav.interactivePopGestureRecognizer?.isEnabled = true
        if let g = installedEdgeGesture {
            nav.view.removeGestureRecognizer(g)
            installedEdgeGesture = nil
        }
    }

    private func installEdgeGesture(on nav: UINavigationController) {
        let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdge(_:)))
        g.edges = .left
        nav.view.addGestureRecognizer(g)
        installedEdgeGesture = g
    }

    @objc private func handleEdge(_ g: UIScreenEdgePanGestureRecognizer) {
        guard g.state == .recognized || g.state == .ended else { return }
        navigationController?.popViewController(animated: true)
    }
}
```

Add `.edgeOnlyPop()` at the end of `CompareView.body` (alongside the other view modifiers).

### Behavior matrix (acceptance criteria)

| Action | Expected |
|---|---|
| Mid-screen right swipe, zoom = 1× | Previous photo |
| Mid-screen left swipe | Next photo |
| Left-edge (~20pt) right pan | Pop back to Gallery |
| Two-finger pinch in middle | Image scales up to 5× and **stays** |
| Two-finger pinch, release | Holds scale (no snap-back to 1×) |
| Double-tap image | Toggle 1× / 3× zoom (unchanged) |
| Switch RAW/JPG tab while zoomed | Zoom resets to 1× |
| Navigate to next/previous photo while zoomed | Zoom resets to 1× |
| Right swipe while zoomed >1× | Pan inside image (unchanged) |

## Edge Cases

- **`fullScreenCover` for RAW/JPG editor**: Modal, not in the navigation stack. Our gesture changes don't reach it. The cover dismisses via its own X button.
- **`viewWillAppear` re-entrancy**: After returning from the editor cover, `viewWillAppear` fires again. We disable interactivePop again and add a *fresh* edge gesture. Guarded by `installedEdgeGesture == nil`-style check — we always re-install on appear and tear down on disappear, so no leak.
- **`viewWillDisappear` failure to restore**: If the controller is deallocated mid-transition without `viewWillDisappear` firing, the system pop stays disabled. Mitigated by also restoring in `deinit`.
- **iPad split view / multi-window**: `UIScreenEdgePanGestureRecognizer` honors the host view's bounds, so the left edge of the split pane is still the trigger zone. Behavior matches user expectation.
- **VoiceOver**: Edge pan is preserved as a system back gesture; VoiceOver users typically use the back button anyway. No regression.

## Testing

Project has no XCTest target. Verification is on-device:

1. Build & install to `Edvardzeng`.
2. Open a photo in CompareView.
3. Run through every row in the behavior matrix above.
4. Sanity: switch RAW/JPG while zoomed → zoom resets. Navigate next/prev while zoomed → zoom resets.
5. Back out to Gallery, push CompareView again → system pop still disabled, edge pop still works (no leaks).
6. Open editor via fullScreenCover, dismiss → CompareView gestures unchanged.

## Out-of-scope improvements noted

- The existing `UISwipeGestureRecognizer` flick model is strict about velocity. A pan-driven follow-finger pager (Photos.app-style) would feel smoother but doubles the surface area of this change. Deferred.
- The current `applyZoomState` removal also means we no longer "restore" zoom when SwiftUI re-renders for unrelated reasons. That's the desired behavior — the scrollview owns its state.
