import SwiftUI
import Observation

/// Adapted from Lara's ambient background: one clock, soft radial washes,
/// and no full-screen blur passes. Inactive scenes never advance the animation.
@MainActor @Observable
final class InputPilotAmbientClock {
    private(set) var elapsed: TimeInterval = 0
    private var activeSince: Date?

    func setActive(_ active: Bool, at date: Date = .now) {
        if active {
            if activeSince == nil { activeSince = date }
        } else if let activeSince {
            elapsed += max(0, date.timeIntervalSince(activeSince))
            self.activeSince = nil
        }
    }

    func time(at date: Date) -> TimeInterval {
        elapsed + (activeSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
}

enum AmbientPalette: String, CaseIterable, Identifiable {
    case accent = "Accent Color"
    case sand = "Sand"
    case sage = "Sage"
    case rose = "Rose"
    case ocean = "Ocean"
    case lavender = "Lavender"
    case graphite = "Graphite"

    var id: Self { self }

    func colors(accent: Color) -> [Color] {
        switch self {
        case .accent: [accent, accent.opacity(0.6), Color(red: 0.83, green: 0.70, blue: 0.84)]
        case .sand: [Color(red: 0.83, green: 0.69, blue: 0.51), Color(red: 0.88, green: 0.73, blue: 0.61), Color(red: 0.94, green: 0.84, blue: 0.63)]
        case .sage: [Color(red: 0.52, green: 0.72, blue: 0.59), Color(red: 0.64, green: 0.79, blue: 0.72), Color(red: 0.81, green: 0.84, blue: 0.66)]
        case .rose: [Color(red: 0.88, green: 0.61, blue: 0.70), Color(red: 0.78, green: 0.65, blue: 0.78), Color(red: 0.94, green: 0.76, blue: 0.70)]
        case .ocean: [Color(red: 0.47, green: 0.70, blue: 0.84), Color(red: 0.51, green: 0.79, blue: 0.79), Color(red: 0.69, green: 0.77, blue: 0.90)]
        case .lavender: [Color(red: 0.71, green: 0.63, blue: 0.88), Color(red: 0.83, green: 0.70, blue: 0.84), Color(red: 0.65, green: 0.75, blue: 0.90)]
        case .graphite: [Color(red: 0.59, green: 0.63, blue: 0.69), Color(red: 0.70, green: 0.72, blue: 0.76), Color(red: 0.79, green: 0.77, blue: 0.73)]
        }
    }
}

struct InputPilotAmbientBackground: View {
    @AppStorage("dynamicBackgrounds") private var enabled = true
    @AppStorage("ambientPalette") private var paletteName = AmbientPalette.accent.rawValue
    @AppStorage("appAccent") private var accentName = AppAccent.inputPilot.rawValue
    @AppStorage("customAccentHex") private var customAccentHex = AccentColorCodec.defaultCustomHex
    @Environment(InputPilotAmbientClock.self) private var clock: InputPilotAmbientClock?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isVisible = false

    var body: some View {
        let accent = AppAccent.resolve(accentName).color(customHex: customAccentHex)
        let palette = (AmbientPalette(rawValue: paletteName) ?? .accent).colors(accent: accent)
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if enabled && !reduceTransparency && contrast != .increased {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                    paused: reduceMotion || scenePhase != .active || !isVisible)) { timeline in
                    let phase = reduceMotion ? 0 : (clock?.time(at: timeline.date) ?? 0)
                        .truncatingRemainder(dividingBy: 32) / 32 * .pi * 2
                    Canvas { context, size in
                        let span = max(size.width, size.height)
                        let opacity = scheme == .dark ? 0.32 : 0.37
                        let breath = 1 + sin(phase * 2) * 0.09
                        wash(context: &context, size: size, color: palette[0], opacity: opacity,
                             x: 0.18 + sin(phase) * 0.29, y: 0.20 + cos(phase) * 0.20,
                             radius: span * 0.62 * breath)
                        wash(context: &context, size: size, color: palette[1], opacity: opacity,
                             x: 0.82 + cos(phase + .pi / 3) * 0.29, y: 0.48 + sin(phase + .pi / 3) * 0.26,
                             radius: span * 0.64 / breath)
                        wash(context: &context, size: size, color: palette[2], opacity: opacity,
                             x: 0.40 + sin(phase + .pi / 2) * 0.29, y: 0.90 + cos(phase + .pi / 2) * 0.20,
                             radius: span * 0.58 * breath)
                        wash(context: &context, size: size, color: accent, opacity: opacity * 0.4,
                             x: 0.65 + cos(phase + .pi) * 0.24, y: 0.10 + sin(phase) * 0.19,
                             radius: span * 0.48)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private func wash(context: inout GraphicsContext, size: CGSize, color: Color,
                      opacity: Double, x: Double, y: Double, radius: CGFloat) {
        let center = CGPoint(x: size.width * x, y: size.height * y)
        let bounds = CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: bounds), with: .radialGradient(
            Gradient(stops: [
                .init(color: color.opacity(opacity), location: 0),
                .init(color: color.opacity(opacity * 0.45), location: 0.45),
                .init(color: color.opacity(0), location: 1)
            ]), center: center, startRadius: 0, endRadius: radius))
    }
}

extension View {
    func inputPilotBackground() -> some View {
        scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { InputPilotAmbientBackground() }
    }
}

struct BackgroundSettingsSection: View {
    @AppStorage("dynamicBackgrounds") private var enabled = true
    @AppStorage("ambientPalette") private var paletteName = AmbientPalette.accent.rawValue

    var body: some View {
        Section {
            Toggle("Dynamic Backgrounds", isOn: $enabled)
            if enabled {
                Picker("Color Palette", selection: $paletteName) {
                    ForEach(AmbientPalette.allCases) { palette in
                        Text(palette.rawValue).tag(palette.rawValue)
                    }
                }
                .livePickerAccent()
            }
        } header: {
            Text("Background")
        } footer: {
            Text("Soft colors move behind the app, as in Lara. Reduce Motion keeps them still; Reduce Transparency and Increased Contrast use a plain background.")
        }
    }
}
