import SwiftUI

struct PermissionDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Photo Access Required", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("RAW+JPG Split needs full access to your photo library to find and process paired photos.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    PermissionDeniedView()
}
