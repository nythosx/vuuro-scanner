import SwiftUI

struct VuuroNavBar<Leading: View, Trailing: View>: View {
    let title: String
    let leading: Leading
    let trailing: Trailing

    init(
        title: String,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(VuuroColor.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 80)

            HStack(spacing: 0) {
                leading
                Spacer(minLength: 0)
                trailing
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 20)
        .background(VuuroColor.bgApp)
    }
}

struct VuuroNavButton: View {
    let label: String
    let icon: String?
    let action: () -> Void

    init(_ label: String, icon: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.3)
            }
            .foregroundStyle(VuuroColor.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VuuroNavSpacer: View {
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
    }
}