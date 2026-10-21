import SwiftUI

/// Keep this destination inert until portal workflows are reliable again.
/// Opening it must not create a transport session, poll, upload, or run scripts.
struct CaptivePortalScriptsView: View {
    let device: StoredDevice

    var body: some View {
        ContentUnavailableView(
            "Wi-Fi Portal Scripts Disabled",
            systemImage: "wifi.exclamationmark",
            description: Text("Portal scripts are not working reliably yet. Use Bluetooth or a Wi-Fi network without a browser login.")
        )
        .inputPilotBackground()
        .navigationTitle("Captive Portal")
    }
}
