import SwiftUI
import SwiftData
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case berry = "Berry"
    case coolBlue = "Cool Blue"
    case fuchsia = "Fuchsia"
    case protokolle = "Protokolle"
    case inputPilot = "Aidoku (InputPilot Red)"
    case clock = "Clock"
    case peculiar = "Peculiar"
    case veryPeculiar = "Very Peculiar"
    case emily = "Emily"
    case custom = "Custom"

    var id: Self { self }

    func color(customHex: String = AccentColorCodec.defaultCustomHex) -> Color {
        switch self {
        case .berry: Color(red: 1.00, green: 0.48, blue: 0.55)
        case .coolBlue: Color(red: 0.49, green: 0.58, blue: 0.95)
        case .fuchsia: Color(red: 0.87, green: 0.43, blue: 0.88)
        case .protokolle: Color(red: 0.67, green: 0.52, blue: 0.83)
        case .inputPilot: Color("AccentColor")
        case .clock: Color(red: 1.00, green: 0.58, blue: 0.15)
        case .peculiar: Color(red: 0.31, green: 0.39, blue: 0.88)
        case .veryPeculiar: Color(red: 0.30, green: 0.59, blue: 0.95)
        case .emily: Color(red: 0.85, green: 0.49, blue: 0.66)
        case .custom: AccentColorCodec.color(from: customHex)
        }
    }

    static func resolve(_ storedValue: String) -> Self {
        if let accent = Self(rawValue: storedValue) { return accent }
        switch storedValue {
        case "Blue": return .coolBlue
        case "Indigo": return .peculiar
        case "Teal": return .veryPeculiar
        case "Orange": return .clock
        default: return .inputPilot
        }
    }
}

enum AppInterfaceStyle: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case rounded = "Rounded"

    var id: Self { self }
    var fontDesign: Font.Design { self == .rounded ? .rounded : .default }
    var controlRadius: CGFloat { self == .rounded ? 22 : 12 }
}

enum AccentColorCodec {
    static let defaultCustomHex = "#8E8CD8"

    static func color(from value: String) -> Color {
        let hex = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6, let rgb = UInt64(hex, radix: 16) else {
            return color(from: defaultCustomHex)
        }
        return Color(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }

    static func hex(from color: Color) -> String {
        let resolved = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return defaultCustomHex
        }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable = "Stable"
    case beta = "Beta"

    var id: Self { self }

    static var buildDefault: Self {
        Bundle.main.object(forInfoDictionaryKey: "InputPilotUpdateChannel") as? String == "beta" ? .beta : .stable
    }

    var detail: String {
        switch self {
        case .stable: "Receives tested public app and firmware releases."
        case .beta: "Receives prerelease app and firmware builds for early testing."
        }
    }

    var releaseAPIURL: URL {
        switch self {
        case .stable:
            URL(string: "https://api.github.com/repos/thorethy1/InputPilot/releases/latest")!
        case .beta:
            URL(string: "https://api.github.com/repos/thorethy1/InputPilot/releases?per_page=30")!
        }
    }

    var altStoreSourceURL: URL {
        switch self {
        case .stable:
            URL(string: "https://github.com/thorethy1/InputPilot/releases/latest/download/altstore-source.json")!
        case .beta:
            URL(string: "https://github.com/thorethy1/InputPilot/releases/download/beta/altstore-source.json")!
        }
    }
}

enum AppTheme {
    enum Spacing {
        static let compact: CGFloat = 8
        static let standard: CGFloat = 12
        static let spacious: CGFloat = 16
        static let section: CGFloat = 24
    }

    enum Radius {
        static let control: CGFloat = 12
        static let card: CGFloat = 16
        static let trackpad: CGFloat = 18
    }

    static let minimumInteractionSize: CGFloat = 44
}

enum AppColors {
    static let primary = Color.accentColor
    static let primaryForeground = Color.white
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue
    static let neutral = Color.secondary
    static let connected = success
    static let available = info
    static let offline = neutral
    static let attention = warning
    static let destructive = error
}

@main
struct InputPilotApp: App {
    @AppStorage("appAppearance") private var appearanceName = AppAppearance.system.rawValue
    @AppStorage("appAccent") private var accentName = AppAccent.inputPilot.rawValue
    @AppStorage("customAccentHex") private var customAccentHex = AccentColorCodec.defaultCustomHex
    @AppStorage("appInterfaceStyle") private var interfaceStyleName = AppInterfaceStyle.standard.rawValue

    private let container: ModelContainer = {
        let schema = Schema([StoredDevice.self, HIDPreset.self, HIDMacro.self])
        return try! ModelContainer(for: schema)
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(accent.color(customHex: customAccentHex))
                .preferredColorScheme(appearance.colorScheme)
                .fontDesign(interfaceStyle.fontDesign)
                .buttonBorderShape(.roundedRectangle(radius: interfaceStyle.controlRadius))
        }
        .modelContainer(container)
    }

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceName) ?? .system
    }

    private var accent: AppAccent {
        AppAccent.resolve(accentName)
    }

    private var interfaceStyle: AppInterfaceStyle {
        AppInterfaceStyle(rawValue: interfaceStyleName) ?? .standard
    }
}
