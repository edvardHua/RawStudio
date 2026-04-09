//
//  RAW_JPGSplitApp.swift
//  RAW+JPGSplit
//
//  Created by edvard.zeng on 2026/4/5.
//

import SwiftUI
import Photos

@main
struct RAW_JPGSplitApp: App {
    init() {
        copyBundleResourcesToDocuments()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    /// Copy bundled resource files to Documents directory on first launch.
    /// Files in the Resources/ folder of the bundle are copied to Documents/Resources/.
    /// Users can access these via Finder (iTunes File Sharing) or the iOS Files app.
    private func copyBundleResourcesToDocuments() {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destDir = docs.appendingPathComponent("Resources", isDirectory: true)

        // Create destination directory if needed
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Find bundled Resources directory
        guard let bundleResourceURL = Bundle.main.resourceURL else { return }
        let bundleResourcesDir = bundleResourceURL.appendingPathComponent("Resources")

        // If the bundle has a Resources subdirectory, copy its contents
        guard fileManager.fileExists(atPath: bundleResourcesDir.path) else { return }
        guard let files = try? fileManager.contentsOfDirectory(atPath: bundleResourcesDir.path) else { return }

        for file in files {
            let sourceURL = bundleResourcesDir.appendingPathComponent(file)
            let destURL = destDir.appendingPathComponent(file)

            // Only copy if file doesn't already exist (don't overwrite user modifications)
            if !fileManager.fileExists(atPath: destURL.path) {
                try? fileManager.copyItem(at: sourceURL, to: destURL)
            }
        }
    }
}
