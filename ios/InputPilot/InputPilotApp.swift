import SwiftUI
import SwiftData

@main
struct InputPilotApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: StoredDevice.self)
    }
}
