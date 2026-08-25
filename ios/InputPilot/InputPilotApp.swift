import SwiftUI
import SwiftData

@main
struct InputPilotApp: App {
    private let container: ModelContainer = {
        let schema = Schema([StoredDevice.self, HIDPreset.self, HIDMacro.self])
        return try! ModelContainer(for: schema)
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
