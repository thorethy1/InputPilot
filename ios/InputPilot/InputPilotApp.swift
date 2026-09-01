import SwiftUI
import SwiftData

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
    case inputPilot = "InputPilot Red"
    case blue = "Blue"
    case indigo = "Indigo"
    case teal = "Teal"
    case orange = "Orange"

    var id: Self { self }

    var color: Color {
        switch self {
        case .inputPilot: Color("AccentColor")
        case .blue: .blue
        case .indigo: .indigo
        case .teal: .teal
        case .orange: .orange
        }
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
    static let primary = Color("AccentColor")
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

    private let container: ModelContainer = {
        let schema = Schema([StoredDevice.self, HIDPreset.self, HIDMacro.self])
        return try! ModelContainer(for: schema)
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(accent.color)
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(container)
    }

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceName) ?? .system
    }

    private var accent: AppAccent {
        AppAccent(rawValue: accentName) ?? .inputPilot
    }
}
