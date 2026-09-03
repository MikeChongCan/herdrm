import SwiftUI

@main
struct HerdrMobileApp: App {
    @State private var model = MobileAppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The public half of the device key, for the pairing UI and support
        // tooling. Public by definition; the private key never leaves Keychain.
        UserDefaults.standard.set(
            DeviceKey.authorizedKeysLine(DeviceKey.ensure()),
            forKey: "deviceKey.publicLine"
        )
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS stops servicing sockets in the background and may drop the
            // TCP connection outright; on return, re-prove the held session
            // instead of trusting it. `.inactive` is transient (control centre,
            // an incoming call) and proves nothing either way.
            switch phase {
            case .background:
                model.noteSuspended()
            case .active:
                model.resumeSelected()
            default:
                break
            }
        }
    }
}
