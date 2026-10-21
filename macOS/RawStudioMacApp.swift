import SwiftUI

@main
struct RawStudioMacApp: App {
    var body: some Scene {
        WindowGroup {
            MacFolderHomeView()
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}
