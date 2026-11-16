import SwiftUI

struct NotchView: View {
    let notchSize: CGSize
    let showSettings: () -> Void

    @State private var isExpanded = false
    @AppStorage("selectedWidget") private var selectedWidgetID = NotchWidget.all[0].id
    @AppStorage(PreferenceKey.backgroundStyle) private var backgroundStyle = BackgroundStyle.solid
    @AppStorage(PreferenceKey.backgroundColor) private var backgroundColorData = Data()
    @AppStorage(PreferenceKey.backgroundOpacity) private var backgroundOpacity = 1.0
    @AppStorage(PreferenceKey.expandsOnClick) private var expandsOnClick = false

    private var selectedWidget: NotchWidget {
        NotchWidget.all.first { $0.id == selectedWidgetID } ?? NotchWidget.all[0]
    }

    var body: some View {
        let size = isExpanded ? CGSize(width: 600, height: notchSize.height + 170) : notchSize
        let radius: CGFloat = isExpanded ? 28 : 10
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)

        ZStack(alignment: .top) {
            if !isExpanded {
                shape.fill(.black)
            } else if backgroundStyle == .blur {
                BehindWindowBlur()
                    .clipShape(shape)
                    .opacity(backgroundOpacity)
            } else {
                shape.fill(Color(colorData: backgroundColorData).opacity(backgroundOpacity))
            }
            if isExpanded {
                expandedContent
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if !isHovering || !expandsOnClick { setExpanded(isHovering) }
        }
        .onTapGesture {
            if expandsOnClick && !isExpanded { setExpanded(true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func setExpanded(_ isExpanded: Bool) {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { self.isExpanded = isExpanded }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(NotchWidget.all) { widget in
                    Button {
                        selectedWidgetID = widget.id
                    } label: {
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
                Button("Settings", systemImage: "gearshape", action: showSettings)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 40, height: notchSize.height - 6)
                    .contentShape(Capsule())
                    .help("Settings")
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

/// SwiftUI materials only blur the window's own content; this blurs the desktop behind the panel.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
