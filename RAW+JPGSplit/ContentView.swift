//
//  ContentView.swift
//  RAW+JPGSplit
//
//  Created by edvard.zeng on 2026/4/5.
//

import SwiftUI

struct ContentView: View {
    @State private var manager = PhotoLibraryManager()

    var body: some View {
        Group {
            switch manager.permissionStatus {
            case .notDetermined:
                ProgressView("Requesting access...")
                    .task {
                        await manager.requestPermission()
                    }
            case .authorized:
                GalleryView(manager: manager)
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
