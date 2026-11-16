import SwiftUI

struct NotchView: View {
    let notchSize: CGSize

    @State private var isExpanded = false
    @AppStorage("selectedWidget") private var selectedWidgetID = NotchWidget.all[0].id

    private var selectedWidget: NotchWidget {
        NotchWidget.all.first { $0.id == selectedWidgetID } ?? NotchWidget.all[0]
    }

    var body: some View {
        let size = isExpanded ? CGSize(width: 600, height: notchSize.height + 170) : notchSize
        let radius: CGFloat = isExpanded ? 28 : 10

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                .fill(.black)
            if isExpanded {
                expandedContent
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { isHovering in
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { isExpanded = isHovering }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(NotchWidget.all) { widget in
                    Button { selectedWidgetID = widget.id } label: {
                        Image(systemName: widget.systemImage)
                            .frame(width: 40, height: notchSize.height - 6)
                            .background(
                                widget.id == selectedWidget.id ? Color.white.opacity(0.15) : .clear,
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(widget.title)
                }
                Spacer()
            }
            .frame(height: notchSize.height)
            .padding(.horizontal, 24)

            selectedWidget.makeView()
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
    }
}
