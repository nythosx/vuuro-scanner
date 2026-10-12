import SwiftUI

struct VuuroSheet<Content: View, Footer: View>: View {
    let title: String
    let onClose: () -> Void
    let content: Content
    let footer: Footer

    init(
        title: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(VuuroColor.handle)
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 16)

            HStack {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(VuuroColor.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(VuuroColor.overlayPill.opacity(0.12), in: Circle())
                }
                .accessibilityIdentifier("sheet.close")
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            ScrollView {
                content
            }

            footer
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .background(VuuroColor.bgApp)
                .overlay(alignment: .top) {
                    Rectangle().fill(VuuroColor.borderMed).frame(height: 1)
                }
        }
        .background(VuuroColor.bgApp)
    }
}

extension View {
    func vuuroSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        detents: Set<PresentationDetent> = [.large],
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        sheet(isPresented: isPresented) {
            content()
                .presentationDetents(detents)
                .presentationDragIndicator(.hidden)
        }
    }
}
