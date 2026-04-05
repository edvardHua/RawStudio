# RAW+JPG Split — Design Spec

## Overview

An iOS app that scans the user's photo library for RAW+JPG paired photos (imported from external cameras), allows side-by-side comparison of the RAW and JPG versions, and lets the user keep one version or split them into two independent photos.

## Target Devices

- iPhone and iPad
- iPad supports Split View / Slide Over multitasking

## Tech Stack

- SwiftUI (UI layer)
- PhotoKit — PHAsset, PHAssetResource, PHImageManager, PHCachingImageManager (data layer)
- Minimum deployment target: iOS 17

## Data Source

External camera photos (Sony ARW, Canon CR3, Nikon NEF, etc.) imported to iOS Photos via SD card reader, USB connection, or manufacturer apps. iOS merges the RAW and JPG into a single PHAsset containing multiple PHAssetResource entries.

## Data Layer

### RAW+JPG Pair Identification

A PHAsset is a RAW+JPG pair when `PHAssetResource.assetResources(for: asset)` contains both:
- `PHAssetResourceType.photo` (JPG)
- `PHAssetResourceType.alternatePhoto` (RAW)

Scan all image-type PHAssets and filter for those matching this criteria.

### Three Core Operations

**Keep JPG:**
1. Extract JPG resource data from the original asset
2. Create a new JPG-only asset via `PHAssetCreationRequest`, preserving EXIF/metadata
3. Delete the original paired asset (moves to system "Recently Deleted")

**Keep RAW:**
1. Extract RAW resource data from the original asset
2. Create a new RAW-only asset, preserving EXIF/metadata
3. Delete the original paired asset

**Split into Two:**
1. Extract both JPG and RAW resource data
2. Create two independent assets (one JPG, one RAW), preserving EXIF/metadata
3. Delete the original paired asset

### Resource Data Extraction

Use `PHAssetResourceManager.default().requestData(for:options:dataReceivedHandler:completionHandler:)` to extract raw file data from each resource. Write new photos via `PHAssetCreationRequest.addResource(with:data:options:)`.

### Permissions

- Request full photo library access (`PHAuthorizationStatus.authorized`) on first launch
- Requires read + write + delete permissions
- If denied, show a guidance screen explaining how to enable access in system Settings

### Error Handling

- **Deletion denied:** When iOS shows the system delete confirmation dialog and the user taps "Don't Allow", the new asset(s) have already been created. Show an alert: "Photos were saved but the original could not be deleted. You can delete it manually from Photos." Mark the pair as processed anyway.
- **Resource extraction failure:** If extracting RAW or JPG data fails (e.g., iCloud photo not downloaded), show an alert prompting the user to open Photos and ensure the image is downloaded locally before retrying.
- **Write failure:** If creating a new asset fails, do NOT delete the original. Show an error alert and leave the pair in unprocessed state.

### Performance

- Use `PHFetchResult` lazy loading — do not load all assets upfront
- Use `PHCachingImageManager` for thumbnail pre-caching during list scrolling
- Extract actual resource data (RAW/JPG files) only when entering the compare view or executing an operation
- Batch operations run on a background queue with a progress indicator

## Pages

The app has 3 pages/modes:

### 1. Gallery (Main List)

The primary screen. A vertically scrolling card list showing all RAW+JPG paired photos.

**Card Design:**
- Rounded rectangle card
- Left side: thumbnail (approximately 80x80pt)
- Right side: file name (primary title), capture date (subtitle), RAW format tag (capsule badge, e.g. "ARW")
- Processed cards become semi-transparent gray, display the result (e.g. "Kept JPG"), and sort to the bottom or are hidden based on filter

**Navigation Bar:**
- Title: "RAW+JPG"
- Left: filter button — toggle between "All" / "Unprocessed" / "Processed"
- Right: "Select" button to enter batch selection mode

**Sort Order:** Reverse chronological (newest first)

**Date Grouping:** Cards grouped by date with section headers (e.g. "April 5, 2026"). A semi-transparent date index strip on the right edge allows press-and-drag fast scrolling.

**Empty State:** Centered icon + text: "No RAW+JPG paired photos found. Import camera photos to your library and paired photos will appear here automatically."

### 2. Compare (Detail View)

Full-screen comparison of RAW vs JPG for a single pair.

**Adaptive Layout:**
- Image aspect ratio > 1 (landscape) → vertical stack (top/bottom)
- Image aspect ratio <= 1 (portrait) → horizontal stack (left/right)
- Each image has a semi-transparent label in its top-left corner: "RAW" or "JPG"

**Synchronized Zoom:**
- Pinch-to-zoom on either image synchronizes both to the same scale and position
- Single-finger pan synchronizes both images
- Double-tap resets to original size

**Bottom Action Bar:**
- Frosted glass (material) background, fixed at bottom
- Three buttons arranged horizontally with SF Symbol icons + text:
  - "Keep JPG" (photo icon)
  - "Keep RAW" (camera.filters icon)
  - "Split" (rectangle.split.2x1 icon)

**After Action:**
- Display a lightweight toast sliding down from top: "Kept JPG · Original can be recovered from Recently Deleted" (auto-dismiss after ~2 seconds)
- Automatically transition to the next unprocessed photo (slide-left animation)
- If all photos are processed, return to the gallery

**Navigation Within Compare:**
- Swipe left/right to move between paired photos without returning to gallery
- Top displays current progress: "3 / 27"

### 3. Batch Selection Mode

Entered from the gallery by tapping "Select".

**Selection UI:**
- Circular checkboxes appear on the left side of each card (empty circle = unselected, blue filled checkmark = selected)
- Navigation bar left becomes "Select All", right becomes "Cancel"
- Fixed bottom action bar appears (same three buttons as compare view)

**Confirmation Dialog:**
- System Alert before executing:
  - Title: "Keep JPG for 12 photos"
  - Message: "Original RAW+JPG paired photos will be deleted. They can be recovered from Recently Deleted."
  - Buttons: "Confirm" / "Cancel"

**Progress Display:**
- Full-screen semi-transparent overlay + circular progress indicator + text ("Processing 3/12...")
- Completion summary Alert: "Done. Successfully processed 12, failed 0."

## Visual Design

- **Color:** Follow system light/dark mode using semantic colors (`Color.primary`, `Color.secondary`, `Color.accentColor`)
- **Typography:** System dynamic type throughout (`.title`, `.body`, `.caption`)
- **Animation:** Native SwiftUI spring animations, natural transitions
- **Icons:** SF Symbols exclusively
- **Overall Style:** Inspired by Apple Files / Apple Photos — no unnecessary decoration, content-first

## iPad Adaptations

- Gallery uses wider card layout or two-column grid on iPad
- Compare view benefits from larger screen real estate for bigger comparison images
- Supports Split View and Slide Over multitasking
