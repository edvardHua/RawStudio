import SwiftUI

struct ToastView: View {
    let message: String
    @Binding var isPresented: Bool

    var body: some View {
        if isPresented {
            VStack {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.top, 8)

                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isPresented = false
                    }
                }
            }
        }
    }
}

struct ToastModifier: ViewModifier {
    let message: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            ToastView(message: message, isPresented: $isPresented)
                .animation(.spring(duration: 0.4), value: isPresented)
        }
    }
}

extension View {
    func toast(message: String, isPresented: Binding<Bool>) -> some View {
        modifier(ToastModifier(message: message, isPresented: isPresented))
    }
}

#Preview {
    Text("Content")
        .toast(message: "Kept JPG · Original can be recovered from Recently Deleted", isPresented: .constant(true))
}
