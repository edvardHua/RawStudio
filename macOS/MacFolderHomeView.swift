import SwiftUI

struct MacFolderHomeView: View {
    var body: some View {
        ContentUnavailableView(
            "Choose a Photo Folder",
            systemImage: "folder",
            description: Text("Folder access and photo scanning will be available in a later stage.")
        )
        .navigationTitle("RawStudio")
    }
}
