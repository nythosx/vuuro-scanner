struct VuuroCenterView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(VuuroColor.bgApp)
    }
}

struct VuuroIconBadge: View {
    let systemName: String
    let tint: Color
    let background: Color
    var size: CGFloat = 80
    var iconSize: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(background, in: Circle())
    }
}