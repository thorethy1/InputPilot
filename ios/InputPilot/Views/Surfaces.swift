import SwiftUI

/// Lara's content surface: native glass with a subtle scrim for readable text.
/// Keep the decoration behind the content so UIKit trackpad gestures and native
/// list interactions continue to receive their original touch events.
struct InputPilotSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat = AppTheme.Radius.card

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency || contrast == .increased {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
            } else if #available(iOS 26.0, *) {
                shape.fill(.clear)
                    .glassEffect(.regular, in: shape)
                    .overlay {
                        shape.fill(scheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.12))
                    }
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct InputPilotOutlinedSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                InputPilotSurface(cornerRadius: cornerRadius)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.07), radius: 12, x: 0, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : (scheme == .dark ? 0.16 : 0.10)), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func inputPilotSurface(cornerRadius: CGFloat = AppTheme.Radius.card) -> some View {
        modifier(InputPilotOutlinedSurface(cornerRadius: cornerRadius))
    }
}

/// Style the rows themselves; hiding the scroll background alone leaves native
/// grouped sections opaque. Native clipping, separators, swipes and reordering
/// remain owned by List/Form, as in Lara.
struct InputPilotList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        List {
            Group { content() }
                .listRowBackground(InputPilotSurface(cornerRadius: 0))
        }
        .scrollContentBackground(.hidden)
    }
}

struct InputPilotForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form {
            Group { content() }
                .listRowBackground(InputPilotSurface(cornerRadius: 0))
        }
        .scrollContentBackground(.hidden)
    }
}
