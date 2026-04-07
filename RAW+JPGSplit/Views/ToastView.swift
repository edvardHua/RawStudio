import SwiftUI

struct ToastView: View {
    let message: String
    @Binding var isPresented: Bool
    var undoAction: (() -> Void)?
    var duration: TimeInterval = 3.0

    var body: some View {
        if isPresented {
            VStack {
                HStack(spacing: 12) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.white)

                    if let undoAction {
                        Button {
                            undoAction()
                            withAnimation(.easeOut(duration: 0.2)) {
                                isPresented = false
                            }
                        } label: {
                            Text("Undo")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.8), in: Capsule())
                .padding(.top, 8)

                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
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
    var undoAction: (() -> Void)?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            ToastView(message: message, isPresented: $isPresented, undoAction: undoAction)
                .animation(.spring(duration: 0.4), value: isPresented)
        }
    }
}

extension View {
    func toast(message: String, isPresented: Binding<Bool>, undoAction: (() -> Void)? = nil) -> some View {
        modifier(ToastModifier(message: message, isPresented: isPresented, undoAction: undoAction))
    }
}
