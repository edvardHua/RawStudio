# RAW+JPG Split — Project Context

## What This App Does

An iOS app that scans the user's photo library for RAW photos (both RAW+JPG paired and RAW-only), allows side-by-side comparison, editing, and provides three core workflows:

1. **RAW+JPG Pair Management** — Compare RAW vs JPG versions of paired photos, keep one, or split into two independent photos
2. **RAW Editing** — Built-in RAW editor with 15+ CIRAWFilter parameters (exposure, white balance, sharpness, noise reduction, etc.)
3. **HDR Export** — Export RAW photos as Adaptive HDR (HEIF) or Ultra HDR (JPEG with gain map) for HDR display on any device

## Tech Stack

- **Swift 6** with strict concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
- **SwiftUI** (iOS 17+, built with Xcode 26.2)
- **PhotoKit** — PHAsset, PHAssetResource, PHCachingImageManager
- **CoreImage** — CIRAWFilter for RAW processing, CIFilter chain for JPG editing
- **Vision** — VNGeneratePersonSegmentationRequest, VNGenerateForegroundInstanceMaskRequest for layer editing
- **No external dependencies** — everything is native Apple frameworks

## Build Command

```bash
xcodebuild -project "RAW+JPGSplit.xcodeproj" -scheme "RAW+JPGSplit" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The project uses `PBXFileSystemSynchronizedRootGroup` — files placed in `RAW+JPGSplit/` are auto-synced to the Xcode project. No manual pbxproj edits needed.

## Architecture

```
RAW+JPGSplit/
├── RAW_JPGSplitApp.swift              # App entry point
├── ContentView.swift                  # Root routing: permission → gallery
├── Models/
│   ├── PhotoPair.swift                # Data model for a RAW (+optional JPG) asset
│   ├── Album.swift                    # Wraps PHAssetCollection
│   ├── PhotoMetadata.swift            # EXIF extraction via CGImageSource
│   ├── RAWEditParams.swift            # 15+ CIRAWFilter parameters (Codable) + RAWEditPreset
│   ├── JPGEditParams.swift            # CIFilter chain parameters (Codable) + JPGEditPreset
│   └── LayerEditParams.swift          # Per-layer edit params (LayerType, LayerEditParams, LayerEdits)
├── Services/
│   ├── PhotoLibraryManager.swift      # Core service: fetch, thumbnail, export, operations
│   ├── RAWEditPresetStore.swift       # Unified persistence for all edit params and named presets
│   ├── UltraHDRWriter.swift           # Ultra HDR JPEG encoder (MPF + gain map)
│   ├── SegmentationService.swift      # Vision framework segmentation + skin detection (@Observable)
│   └── CustomMaskStore.swift          # Custom mask persistence (grayscale PNG in documents dir)
├── Views/
│   ├── GalleryView.swift              # Main list/grid with source filter, batch selection, album picker
│   ├── PhotoCardView.swift            # List item cell
│   ├── PhotoGridItemView.swift        # Grid item cell
│   ├── CompareView.swift              # Full-screen photo viewer + actions + delete
│   ├── ZoomableImageView.swift        # UIScrollView-backed pinch-to-zoom (ZoomableScrollView)
│   ├── RAWEditorView.swift            # Full-screen RAW editor (CIRAWFilter) with layer editing
│   ├── JPGEditorView.swift            # Full-screen JPG editor (CIFilter chain) with layer editing
│   ├── EditorComponents.swift         # Shared: EditorSlider, EditorTabBar, EditorToolbar, EditorFormatBadge, EditorToggle
│   ├── RAWPresetPickerView.swift      # RAW preset selection sheet
│   ├── JPGPresetPickerView.swift      # JPG preset selection sheet
│   ├── LayerSelectorView.swift        # Layer selector (glass capsules) + LayerParamsView
│   ├── MaskPainterView.swift          # Full-screen custom mask painting (brush/wand/eraser)
│   ├── ActionBarView.swift            # Bottom action buttons (keep/split/HDR)
│   ├── BatchProgressView.swift        # Batch operation overlay
│   ├── ToastView.swift                # Lightweight top toast (with optional undo)
│   ├── EmptyStateView.swift           # Empty library state
│   └── PermissionDeniedView.swift     # Permission guidance
├── Localizable.xcstrings              # en + zh-Hans translations
└── InfoPlist.xcstrings                # Localized permission description
```

## Key Design Decisions

### PhotoPair Model
- `jpgResource: PHAssetResource?` — optional, nil for RAW-only assets
- `isRawOnly: Bool` — computed from `jpgResource == nil`
- NOT `@Observable` — removed to avoid cascading SwiftUI re-renders when thumbnails load
- Thumbnails stored in `NSCache<NSString, UIImage>` on PhotoLibraryManager
- No "processed" state tracking — keep/split are pure export actions

### RAW Detection
RAW-only assets store their RAW file as `PHAssetResourceType.photo` (not `.alternatePhoto`). We check the UTI via `isRAWType()` to distinguish RAW from JPG when the resource type is `.photo`. Known RAW UTIs: ARW, CR2, CR3, NEF, RAF, ORF, RW2, DNG, PEF, SRW, etc.

`PHAssetMediaSubtype` has NO `photoRAW` flag — RAW photos cannot be pre-filtered at the PhotoKit database level.

### RAW Rendering
- JPG: `UIImage(data:)` — direct decode
- RAW: `CIRAWFilter` with customizable parameters — shows authentic RAW rendering different from camera JPG
- RAW preview in editor uses `isDraftModeEnabled = true` + `scaleFactor = 0.25` for fast rendering

### Ultra HDR JPEG
Implemented natively in `UltraHDRWriter.swift` without any C++ dependencies:
1. Render SDR (sRGB 8-bit) and HDR (HLG float16) from CIRAWFilter
2. Compute per-pixel gain map: `log2(hdrNits / sdrNits)`
3. Encode as MPF JPEG with XMP metadata (Adobe Gain Map spec + ISO 21496-1)

### Adaptive HDR HEIF
Uses `CIContext.writeHEIFRepresentation(of: sdrImage, options: [.hdrImage: hdrImage])` — iOS 18+ API that auto-computes gain map.

### Segmentation & Layer Editing
- `SegmentationService` is `@Observable` — mask property changes trigger UI updates
- Vision requests run on background thread via `Task.detached` with `nonisolated static` methods
- Input images forced to 8-bit sRGB via `createCGImage(format: .RGBA8, colorSpace: sRGB)` for Vision compatibility
- Skin detection: person mask AND YCbCr color thresholding in a single CPU pass
- RAW editor passes `previewImageForMask: UIImage` (pre-rendered standard CGImage) instead of CIRAWFilter output to avoid HDR format issues

### Performance Optimizations
1. **Batch streaming scan**: `AsyncStream` yields results every 50 assets, UI updates incrementally. Scan runs in `Task.detached` on background thread.
2. **No @Observable on PhotoPair**: Thumbnails in `NSCache`, each cell has its own `@State` thumbnail loaded via `.task(id:)`.
3. **LazyVStack instead of List**: Proper lazy rendering for sections with pinned headers.
4. **Static DateFormatter**: Cached for `groupedByDate()`.
5. **Thumbnail deliveryMode .fastFormat**: Single callback, no degraded → full quality round-trip.

## Feature Details

### Gallery (Main Screen)
- **Layout**: List (default) or Grid (3-column), togglable from menu
- **Source filter**: RAW+JPG pairs (default) or RAW-only — **Segmented Control at top** (not in menu)
- **Album picker**: Browse system smart albums (in Photos app order) and user albums
- **Grid date grouping**: Grid view shows photos grouped by date with section headers (same as list view)
- **Batch selection**: Select multiple → action bar appears
  - RAW+JPG mode: Keep JPG / Keep RAW / Split + HDR menu
  - RAW-only mode: Adaptive HDR / Ultra HDR buttons directly
- **Navigation title**: Fixed inline (doesn't collapse on scroll)
- **Loading states**: Full-screen spinner → list with bottom "scanning more" indicator

### Compare View (Photo Viewer)
- **Full-screen black background** with pinch-to-zoom (UIScrollView-based)
- **RAW/JPG toggle** button (top-right, only for pairs)
- **Format badge**: Top-left, green for RAW, yellow for JPG
- **EXIF metadata bar**: Bottom gradient overlay showing camera model, dimensions, file size, aperture, shutter speed, ISO, focal length
- **Edit button**: Opens RAW editor when viewing RAW, JPG editor when viewing JPG
- **Action bar behavior**:
  - RAW+JPG pair: Always shows Keep JPG / Keep RAW / Split + HDR menu (regardless of current format view)
  - RAW-only: Shows Adaptive HDR / Ultra HDR buttons directly
- **iCloud handling**: Shows "Downloading from iCloud..." during image loading; back button remains usable. Processing overlay (with `.navigationBarBackButtonHidden`) during save operations.
- **Swipe navigation**: Left/right swipe between photos (only when not zoomed)
- **Delete button**: Trash icon in toolbar, deletes original photo (system confirmation), then advances to next photo
- **After keep/split action**: Toast notification, stays on current photo (non-destructive export)

### RAW Editor
- **15+ parameters** in 4 tabs: Exposure / Color / Detail / Lens
- **Real-time preview** using CIRAWFilter draft mode (1/4 scale)
- **Presets**: Save named presets, load from preset picker, delete
- **Per-asset persistence**: Edit params saved via RAWEditPresetStore
- **Applied on export**: HDR exports use saved edit params
- **Layer editing**: 5 auto layers (Global / Person / Skin / Foreground / Background) + up to 3 custom layers with per-layer adjustments

### JPG Editor
- **10 parameters** in 3 tabs: Exposure / Color / Detail
- **CIFilter chain**: CIExposureAdjust, CIColorControls, CITemperatureAndTint, CIHighlightShadowAdjust, CIVibrance, CISharpenLuminance
- **Presets**: Save/load named presets (separate from RAW presets)
- **Per-asset persistence**: Edit params saved via RAWEditPresetStore
- **EXIF orientation handling**: Applies orientation transform before processing to prevent rotation
- **Layer editing**: Same 5 auto layers + 3 custom layers as RAW editor

### Layer Editing (Both Editors)
- **5 layer types**: Global (full image), Person (VNGeneratePersonSegmentationRequest), Skin (person mask + YCbCr color detection), Foreground (VNGenerateForegroundInstanceMaskRequest), Background (inverted foreground)
- **Per-layer parameters**: Exposure, Brightness, Contrast, Saturation, Temperature
- **Mask generation**: On editor open, masks generated in background. For RAW, uses pre-rendered UIImage from CompareView (avoids CIRAWFilter HDR format issues with Vision).
- **Rendering pipeline**: Global edits → for each layer with modifications, apply CIFilter chain through CIBlendWithMask compositing
- **Layer edits persisted** per asset via RAWEditPresetStore
- **Custom layers**: Up to 3 user-defined mask layers via MaskPainterView
  - **Brush tool**: finger painting to add selection, adjustable size (4-100px)
  - **Magic wand tool**: tap to auto-select similar color regions (flood fill), adjustable tolerance
  - **Eraser tool**: finger painting to remove selection
  - **Mask visualization**: semi-transparent red overlay on selected regions
  - **Undo/redo**: mask history stack (up to 20 steps)
  - **Persistence**: masks stored as grayscale PNG in app documents directory via CustomMaskStore
  - **UI**: "+" button in layer selector to add, long-press for edit/delete menu, purple accent for custom layers

### Localization
- English (source) + Simplified Chinese (zh-Hans)
- All UI strings use `String(localized:)` for programmatic strings
- SwiftUI `Text("...")` auto-localizes via `Localizable.xcstrings`
- `InfoPlist.xcstrings` for system permission dialog

## Known Limitations / Future Work

- **No pre-filter at database level**: `PHAssetMediaSubtype` has no RAW flag, so all image assets must be enumerated and checked via `PHAssetResource.assetResources()`. Batch streaming mitigates this but initial scan is still O(total images).
- **Ultra HDR JPEG gain map quality**: The gain map computation is a simplified implementation. Professional tools (libultrahdr) may produce better results.
- **iPad optimization**: App works on iPad but doesn't use two-column grid or other iPad-specific layouts.
- **Date index strip**: Spec mentioned a fast-scroll date index on the right edge — not implemented yet.
- **Photo library change observation**: App doesn't watch for `PHPhotoLibraryChangeObserver` to detect new imports while running.
- **Batch HDR export**: Works but doesn't apply per-asset edit params — uses default RAW rendering.
