import SwiftUI

/// Liquid Glass is macOS 26. On macOS 15 the same controls use a material capsule.
struct CapsuleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        }
    }
}
