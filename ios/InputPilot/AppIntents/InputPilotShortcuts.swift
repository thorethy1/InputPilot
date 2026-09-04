import AppIntents

struct InputPilotAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunPresetIntent(),
            phrases: ["Run \(.applicationName) preset"],
            shortTitle: "Run Preset",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ConnectDeviceIntent(),
            phrases: ["Connect \(.applicationName)"],
            shortTitle: "Connect Device",
            systemImageName: "point.3.connected.trianglepath.dotted"
        )
        AppShortcut(
            intent: SendKeyboardShortcutIntent(),
            phrases: ["Send shortcut with \(.applicationName)"],
            shortTitle: "Send Shortcut",
            systemImageName: "keyboard"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .red }
}
