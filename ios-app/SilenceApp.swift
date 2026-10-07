import SwiftUI
import AirliftFFI

@main
struct AirliftSilenceApp: App {
    init() {
        // Route Rust tracing logs into the same sink the UI drains.
        al_log_init({ _, msg in
            guard let msg = msg else { return }
            SilenceLog.shared.append(String(cString: msg))
        }, nil)

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
