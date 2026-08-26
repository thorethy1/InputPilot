import SwiftUI
import SwiftData

enum AppColors {
    static let primary = Color("AccentColor")
    static let primaryForeground = Color.white
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue
    static let neutral = Color.secondary
}

@main
struct InputPilotApp: App {
    private let container: ModelContainer = {
        let schema = Schema([StoredDevice.self, HIDPreset.self, HIDMacro.self])
        return try! ModelContainer(for: schema)
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(AppColors.primary)
        }
        .modelContainer(container)
    }
}
