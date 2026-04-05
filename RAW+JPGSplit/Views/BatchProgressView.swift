import SwiftUI

struct BatchProgressView: View {
    let current: Int
    let total: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(.circular)
                    .scaleEffect(1.5)

                Text("Processing \(current)/\(total)...")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

#Preview {
    BatchProgressView(current: 3, total: 12)
}
