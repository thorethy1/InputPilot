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
        AppShortcut(
            intent: SwitchDeviceIntent(),
            phrases: ["Switch \(.applicationName) device"],
            shortTitle: "Switch Device",
            systemImageName: "arrow.left.arrow.right"
        )
        AppShortcut(
            intent: StartMouseMoveIntent(),
            phrases: ["Start mouse movement with \(.applicationName)"],
            shortTitle: "Start Mouse Move",
            systemImageName: "cursorarrow"
        )
        AppShortcut(
            intent: StopMouseMoveIntent(),
            phrases: ["Stop mouse movement with \(.applicationName)"],
            shortTitle: "Stop Mouse Move",
            systemImageName: "stop.circle"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .red }
}
