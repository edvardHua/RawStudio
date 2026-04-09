# Custom Layer Editing — Design Spec

## Goal

Allow users to create up to 3 custom mask layers by painting (brush) or tapping (magic wand) to select specific regions of an image, then apply per-layer adjustments to only those regions.

## Tools

| Tool | Icon | Function |
|------|------|----------|
| Brush | `paintbrush.fill` | Finger painting to add selection, adjustable size (4-100px) |
| Magic Wand | `wand.and.stars` | Tap to auto-select similar color regions, adjustable tolerance (0-100%) |
| Eraser | `eraser.fill` | Finger painting to remove selection, adjustable size |

## UI Flow

1. User taps `+` button in layer selector → creates new custom layer → enters MaskPainterView
2. MaskPainterView: full-screen image with tool bar at bottom
3. User paints/taps to define selection → semi-transparent red overlay shows selected regions
4. User taps "Done" → returns to editor with custom mask applied
5. User adjusts 5 parameters (exposure, brightness, contrast, saturation, temperature) for that layer
6. Long-press custom layer → menu: "Edit Mask" / "Delete Layer"

## MaskPainterView Layout

```
┌──────────────────────────────────────┐
│  Cancel                Clear   Done  │
│                                      │
│              Image                   │
│        (finger paint/tap here)       │
│     Selected = red overlay           │
│                                      │
├──────────────────────────────────────┤
│  (🖌️Brush) (🪄Wand) (🧹Eraser)      │
│  Size/Tolerance  ━━━━●━━━━  24px     │
│  (↩️Undo)  (↪️Redo)                  │
└──────────────────────────────────────┘
```

## Data Model

- `LayerType`: add `.custom1`, `.custom2`, `.custom3`
- `LayerEdits`: add `custom1`, `custom2`, `custom3` properties
- Custom masks stored as grayscale PNG in app documents directory
- Key format: `{assetID}_custom{1|2|3}.png`

## Rendering Pipeline

Custom masks integrate into existing pipeline:
```
for layer in [.person, .skin, .foreground, .background, .custom1, .custom2, .custom3]:
    if layer has edits and mask exists:
        apply CIBlendWithMask compositing
```

## Technical Details

### Brush Drawing
- Core Graphics bitmap context (CGContext) for 60fps performance
- Draw circle stamps along finger path
- Output: grayscale bitmap (white=selected, black=unselected)

### Magic Wand
- Get tapped pixel RGB color
- Flood fill from tap point, selecting pixels within tolerance threshold
- RGB Euclidean distance for color similarity
- Run on background thread, merge result into mask
- Each tap adds to existing selection (cumulative)

### Mask Storage
- In memory: CIImage (consistent with auto-generated masks)
- Persistent: grayscale PNG Data in documents directory (not UserDefaults — masks can be large)
- Loaded into SegmentationService custom mask slots on editor open

### Undo/Redo
- Stack of mask snapshots (max 20)
- Snapshot taken on finger-up (brush/eraser) or after each wand tap

## Files

| File | Action | Lines |
|------|--------|-------|
| `Views/MaskPainterView.swift` | Create | ~400 |
| `Services/CustomMaskStore.swift` | Create | ~60 |
| `Models/LayerEditParams.swift` | Modify | ~30 |
| `Services/SegmentationService.swift` | Modify | ~40 |
| `Views/LayerSelectorView.swift` | Modify | ~50 |
| `Views/RAWEditorView.swift` | Modify | ~20 |
| `Views/JPGEditorView.swift` | Modify | ~20 |

## Constraints

- Max 3 custom layers per image
- Mask resolution matches preview (not full resolution) — scaled up on export
- Brush size range: 4-100px
- Tolerance range: 0-100%
- Undo history: max 20 steps
