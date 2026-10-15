import SwiftUI
import UIKit
import AirliftFFI

/// SwiftUI's `onOpenURL` does not deliver a document that another app opens
/// with while this app is still cold-starting — which is the normal case for a
/// sideloaded app that is not already running, and why the share-sheet route
/// ("Open in AirliftSilence") used to do nothing at all. The app delegate is
/// the entry point that does fire on a cold launch, so document opens go
/// through here; the URL scheme keeps using `onOpenURL` in ContentView.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.isFileURL else { return false }
        // Delegate callbacks arrive on the main thread; stated explicitly
        // because the view model is main-actor isolated.
        MainActor.assumeIsolated {
            SilenceViewModel.shared.adoptPairingFile(at: url)
        }
        return true
    }
}

@main
struct AirliftSilenceApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Route Rust tracing logs into the same sink the UI drains.
        al_log_init({ _, msg in
            guard let msg = msg else { return }
            SilenceLog.shared.append(String(cString: msg))
        }, nil)

        // Pairing hands the user a PIN they have to type while inside Settings,
        // where this app is off-screen — ask up front so the notification can
        // actually be delivered later.
        PinNotifier.requestAuthorization()

        // The Rust core looks up ALGetGrappaToken with dlsym(RTLD_DEFAULT, …).
        // Without a hard reference the linker is free to drop the symbol from
        // GrappaHelper.m, and iOS 27.0.1 then rejects every sync with
        // "Grappa session could not be established". Calling it with a null
        // buffer trips the helper's own argument check and returns -1 safely.
        _ = ALGetGrappaToken(0, 0, 0, nil, 0, nil, nil, 0)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

@_silgen_name("ALGetGrappaToken")
func ALGetGrappaToken(
    _ inVersion: UInt32,
    _ inDeviceType: UInt32,
    _ inProtocolVersion: UInt32,
    _ outBuf: UnsafeMutablePointer<UInt8>?,
    _ maxLen: Int,
    _ outLen: UnsafeMutablePointer<Int>?,
    _ errBuf: UnsafeMutablePointer<CChar>?,
    _ errLen: Int
) -> Int32
