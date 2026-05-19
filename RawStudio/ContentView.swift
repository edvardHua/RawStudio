//
//  ContentView.swift
//  RawStudio
//
//  Created by edvard.zeng on 2026/4/5.
//

import SwiftUI

struct ContentView: View {
    @State private var manager = PhotoLibraryManager()
    @State private var presetStore = RAWEditPresetStore()
    @State private var tagStore = PhotoTagStore()

    var body: some View {
        Group {
            switch manager.permissionStatus {
            case .notDetermined:
                ProgressView("Requesting access...")
                    .task {
                        await manager.requestPermission()
                    }
            case .authorized:
                GalleryView(manager: manager, presetStore: presetStore, tagStore: tagStore)
                    .task {
                        manager.fetchAlbums()
                        await manager.fetchPairedAssets()
                    }
            case .denied:
                PermissionDeniedView()
            }
        }
        .onAppear {
            manager.checkPermission()
        }
    }
}

#Preview {
    ContentView()
}
