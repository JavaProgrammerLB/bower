import SwiftUI

// macOS 26 SwiftUI calls live in this file so each macOS 15 fallback stays next to them.

extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func glassBar<Bar: View>(spacing: CGFloat? = nil, @ViewBuilder content: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: spacing) {
                VStack(spacing: 0) {
                    Divider()
                    content()
                }
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }

    func glassScrollEdge() -> some View {
        modifier(GlassScrollEdge())
    }
}

private struct GlassScrollEdge: ViewModifier {
    @State private var isScrolled = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .scrollEdgeEffectStyle(isScrolled ? .hard : .automatic, for: .top)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 0.5
                } action: { _, isScrolled in
                    self.isScrolled = isScrolled
                }
        } else {
            content
        }
    }
}

struct GlassToolbarGroup<Content: View>: ToolbarContent {
    @ViewBuilder var content: () -> Content

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) {
                content().glassCapsule()
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                content().glassCapsule()
            }
        }
    }
}
