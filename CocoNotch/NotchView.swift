import CocoNotchCore
import SwiftUI

struct NotchView: View {
    let notchSize: CGSize
    let showSettings: () -> Void

    @State private var isExpanded = false
    @AppStorage("selectedWidget") private var selectedWidgetID = ""
    @AppStorage(PreferenceKey.widgetPreferences) private var storedWidgetPreferences = ""
    @AppStorage(PreferenceKey.backgroundStyle) private var backgroundStyle = BackgroundStyle.solid
    @AppStorage(PreferenceKey.backgroundColor) private var backgroundColorData = Data()
    @AppStorage(PreferenceKey.backgroundOpacity) private var backgroundOpacity = 1.0
    @AppStorage(PreferenceKey.expandsOnClick) private var expandsOnClick = false

    private var enabledWidgets: [NotchWidget] {
        getEnabledWidgetIDs(NotchWidget.getPreferences(stored: storedWidgetPreferences))
            .compactMap { NotchWidget.find(id: $0) }
    }

    // Falls back to the first enabled widget when the last selected one was switched off.
    private var selectedWidget: NotchWidget {
        enabledWidgets.first { $0.id == selectedWidgetID } ?? enabledWidgets.first ?? NotchWidget.all[0]
    }

    private var usesDarkText: Bool {
        guard isExpanded, backgroundStyle == .solid else { return false }
        let color = Color.Resolved.decode(colorData: backgroundColorData)
        return shouldUseDarkText(
            linearRed: Double(color.linearRed),
            linearGreen: Double(color.linearGreen),
            linearBlue: Double(color.linearBlue)
        )
    }

    var body: some View {
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
        // Expanded, the height follows the widget's content instead of a fixed size.
        .frame(width: isExpanded ? 600 : notchSize.width, height: isExpanded ? nil : notchSize.height)
        .fixedSize(horizontal: false, vertical: isExpanded)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if !isHovering || !expandsOnClick { setExpanded(isHovering) }
        }
        .onTapGesture {
            if expandsOnClick && !isExpanded { setExpanded(true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, usesDarkText ? .light : .dark)
    }

    private func setExpanded(_ isExpanded: Bool) {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { self.isExpanded = isExpanded }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(enabledWidgets) { widget in
                    Button {
                        selectedWidgetID = widget.id
                    } label: {
                        Image(systemName: widget.systemImage)
                            .frame(width: 40, height: notchSize.height - 6)
                            .background(
                                widget.id == selectedWidget.id ? Color.primary.opacity(0.15) : .clear,
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
            .padding(.top, 8)

            selectedWidget.makeView()
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.primary)
        // Content taller than the panel would be cut off by the window edge, so clip it at the panel's height instead.
        .frame(maxHeight: NotchPanel.size.height, alignment: .top)
        .clipped()
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
