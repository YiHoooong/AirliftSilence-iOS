import Foundation
import CryptoKit
import AirliftFFI

// MARK: - Actions

/// The three things a user — from the screen, or from a Shortcut — can ask for.
/// `SilenceIntents.swift` adds the `AppEnum` conformance that makes this
/// selectable in the Shortcuts app; the engine itself stays framework-free.
enum SilenceAction: String, CaseIterable, Sendable {
    case check
    case silence
    case restore

    var title: String {
        switch self {
        case .check: return String(localized: "Check")
        case .silence: return String(localized: "Silence the announcements")
        case .restore: return String(localized: "Restore the originals")
        }
    }
}

/// Which set of bundled files to push to the device.
enum ResourceGroup: String, Sendable {
    case silent
    case original

    var action: SilenceAction { self == .silent ? .silence : .restore }
}

/// What one file on the device looks like, judged against the app's own copies.
enum FileVerdict: Sendable {
    case silent
    case original
    case unknown

    var label: String {
        switch self {
        case .silent: return String(localized: "silenced")
        case .original: return String(localized: "original")
        case .unknown: return String(localized: "unknown build")
        }
    }
}

/// What the device currently has in the announcements folder.
enum SilenceState: Sendable {
    case unknown
    case silent
    case original
    case mixed

    var label: String {
        switch self {
        case .unknown: return String(localized: "Not checked")
        case .silent: return String(localized: "Silenced")
        case .original: return String(localized: "Original (audible)")
        case .mixed: return String(localized: "Partly silenced")
        }
    }

    var symbol: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .silent: return "checkmark.circle.fill"
        case .original: return "exclamationmark.triangle.fill"
        case .mixed: return "exclamationmark.triangle"
        }
    }
}

/// `Result`'s failure type must conform to `Error`; `String` does not.
struct SilenceFailure: Error, Sendable {
    let message: String
}

/// One announcement file as it exists on the device.
struct DeviceFile: Sendable {
    let size: UInt64
    let digest: String
}

/// Everything one run produced, so a caller can paint it on screen or turn it
/// into a Shortcut dialog.
struct SilenceOutcome: Sendable {
    let action: SilenceAction
    let ok: Bool
    let state: SilenceState
    /// One line per announcement file, for the detail card.
    let detail: [String]
    /// Human-readable lines for the run log.
    let lines: [String]
    /// A single short line, used as the Shortcut's spoken/dialog result.
    let summary: String
}

// MARK: - Log sink

/// Thread-safe sink for FFI log lines. Rust calls the log callback from
/// arbitrary threads, so the UI drains this on a timer instead of touching
/// @Published state from the wrong thread.
final class SilenceLog {
    static let shared = SilenceLog()
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = lines
        lines.removeAll()
        return out
    }
}

/// Non-capturing closure so it converts to a C function pointer.
let alLogBridge: ALLogCallback = { _, msg in
    guard let msg = msg else { return }
    SilenceLog.shared.append(String(cString: msg))
}

// MARK: - Engine

/// The device-side half of the app: the bundled replacement files, the FFI
/// calls, and the verdict logic, with no UI attached. Both the view model and
/// the Shortcuts intent drive this, so a Shortcut and the on-screen buttons can
/// never disagree about what "silenced" means.
///
/// Every method here is blocking and thread-agnostic — call it off the main
/// thread. The app's one serialisation point is `SilenceViewModel.run`, because
/// the device tolerates a single exploit session at a time.
enum SilenceEngine {

    /// Where iOS keeps the call-recording announcements.
    static let targetDir = "/var/mobile/Library/CallServices/Greetings/default"

    /// The announcements that play into the call at recording start and stop.
    /// The two voicemail greetings in the same folder — `Greeting.caf` and
    /// `GreetingWithTone.m4a` — are deliberately left alone.
    static let leaves = ["StartDisclosureWithTone.m4a", "StopDisclosure.caf", "StartDisclosure.caf"]

    /// LocalDevVPN's loopback address. Never 127.0.0.1: that wedges
    /// remotepairingdeviced until Developer Mode is toggled.
    static let defaultTargetHost = "10.7.0.1"
    static let targetHostKey = "silenceDeviceIP"

    /// The app answers `airliftsilence://check`, `://silence` and `://restore`,
    /// so a Shortcut can drive it with nothing but an "Open URLs" action. Must
    /// stay in sync with CFBundleURLSchemes in Info.plist.
    static let urlScheme = "airliftsilence"

    // MARK: - loopback tunnel

    static var storedTargetHost: String {
        get { UserDefaults.standard.string(forKey: targetHostKey) ?? defaultTargetHost }
        set { UserDefaults.standard.set(newValue, forKey: targetHostKey) }
    }

    static func applyTargetHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            al_clear_target_hosts()
        } else {
            trimmed.withCString { _ = al_set_target_host($0) }
        }
    }

    static func applyStoredTargetHost() { applyTargetHost(storedTargetHost) }

    // MARK: - bundled resources

    /// Bundled replacement file for one target. Resources carry a
    /// `silent-` / `original-` prefix so the two same-named announcement files
    /// can coexist in the bundle; the staging step renames them back.
    static func bundledFile(_ group: ResourceGroup, leaf: String) -> URL? {
        let ns = leaf as NSString
        return Bundle.main.url(
            forResource: "\(group.rawValue)-\(ns.deletingPathExtension)",
            withExtension: ns.pathExtension
        )
    }

    static func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func referenceDigest(_ group: ResourceGroup, leaf: String) -> String? {
        bundledFile(group, leaf: leaf).flatMap { digest(of: $0) }
    }

    static func verdict(leaf: String, digest: String) -> FileVerdict {
        if digest == referenceDigest(.silent, leaf: leaf) { return .silent }
        if digest == referenceDigest(.original, leaf: leaf) { return .original }
        return .unknown
    }

    // MARK: - runs

    /// Blocking entry point for one action. Call off the main thread.
    static func run(_ action: SilenceAction, pairingPath: String) -> SilenceOutcome {
        applyStoredTargetHost()
        switch action {
        case .check: return check(pairingPath: pairingPath)
        case .silence: return write(.silent, pairingPath: pairingPath)
        case .restore: return write(.original, pairingPath: pairingPath)
        }
    }

    // MARK: - check

    static func check(pairingPath: String) -> SilenceOutcome {
        var lines: [String] = []
        var detail: [String] = []
        var verdicts: [FileVerdict] = []
        var failed = false

        for leaf in leaves {
            switch readHash(pairingPath: pairingPath, leaf: leaf) {
            case let .success(file):
                let verdict = verdict(leaf: leaf, digest: file.digest)
                verdicts.append(verdict)
                let line = String(localized: "\(leaf) — \(verdict.label) · \(file.size.formatted()) bytes · \(String(file.digest.prefix(12)))…")
                detail.append(line)
                lines.append(line)
            case let .failure(failure):
                failed = true
                lines.append(String(localized: "✗ \(leaf): \(failure.message)"))
            }
        }

        let state = overallState(verdicts, failed: failed, fallback: .unknown)
        lines.append(String(localized: "Result: \(state.label)"))

        return SilenceOutcome(
            action: .check,
            ok: !failed,
            state: state,
            detail: detail,
            lines: lines,
            summary: String(localized: "Call-recording announcements: \(state.label)")
        )
    }

    /// Collapse per-file verdicts into the state shown on the status card.
    /// A failed read means "we do not know", never "it is fine".
    private static func overallState(_ verdicts: [FileVerdict], failed: Bool, fallback: SilenceState) -> SilenceState {
        guard !failed, !verdicts.isEmpty else { return .unknown }
        if verdicts.allSatisfy({ $0 == .silent }) { return .silent }
        if verdicts.allSatisfy({ $0 == .original }) { return .original }
        if verdicts.contains(.silent) { return .mixed }
        return fallback
    }

    // MARK: - write

    static func write(_ group: ResourceGroup, pairingPath: String) -> SilenceOutcome {
        let action = group.action
        let title = action.title
        var lines: [String] = []

        // Resolve the bundled files first: a missing resource is this app's
        // problem and must not cost a device session.
        var sources: [(leaf: String, url: URL)] = []
        for leaf in leaves {
            guard let url = bundledFile(group, leaf: leaf) else {
                let message = String(localized: "Bundled resource \(group.rawValue)-\(leaf) is missing")
                lines.append("✗ " + message)
                return SilenceOutcome(action: action, ok: false, state: .unknown, detail: [], lines: lines, summary: message)
            }
            sources.append((leaf, url))
        }

        // Stage a private copy under the real file names — write_dir sends
        // every file in this folder to the device using its leaf name.
        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        } catch {
            let message = String(localized: "Staging failed: \(error.localizedDescription)")
            lines.append("✗ " + message)
            return SilenceOutcome(action: action, ok: false, state: .unknown, detail: [], lines: lines, summary: message)
        }
        defer { try? FileManager.default.removeItem(at: stageDir) }

        do {
            for (leaf, url) in sources {
                try FileManager.default.copyItem(at: url, to: stageDir.appendingPathComponent(leaf))
            }
        } catch {
            let message = String(localized: "Staging failed: \(error.localizedDescription)")
            lines.append("✗ " + message)
            return SilenceOutcome(action: action, ok: false, state: .unknown, detail: [], lines: lines, summary: message)
        }

        let ok = writeDir(source: stageDir.path, pairingPath: pairingPath, lines: &lines)
        let summary = ok
            ? String(localized: "✅ \(title) finished")
            : String(localized: "✗ \(title) failed")
        lines.append(summary)

        return SilenceOutcome(
            action: action,
            ok: ok,
            state: ok ? (group == .silent ? .silent : .original) : .unknown,
            detail: [],
            lines: lines,
            summary: summary
        )
    }

    // MARK: - FFI

    static func readHash(pairingPath: String, leaf: String) -> Result<DeviceFile, SilenceFailure> {
        var size: UInt64 = 0
        var sha: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { p in
            targetDir.withCString { d in
                leaf.withCString { l in
                    al_exploit_read_file_hash(p, d, l, alLogBridge, nil, &size, &sha, &outError)
                }
            }
        }
        defer {
            if let s = sha { al_string_free(s) }
            if let e = outError { al_string_free(e) }
        }
        if rc != 0 {
            let message = outError.map { String(cString: $0) }
                ?? String(localized: "Read failed (rc=\(String(describing: rc)))")
            return .failure(SilenceFailure(message: message))
        }
        guard let s = sha else {
            return .failure(SilenceFailure(message: String(localized: "The device returned nothing")))
        }
        return .success(DeviceFile(size: size, digest: String(cString: s)))
    }

    static func writeDir(source: String, pairingPath: String, lines: inout [String]) -> Bool {
        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            source.withCString { s in
                targetDir.withCString { t in
                    al_exploit_write_dir(p, s, t, alLogBridge, nil, &outError)
                }
            }
        }
        if let e = outError {
            lines.append("✗ " + String(cString: e))
            SilenceLog.shared.append("✗ " + String(cString: e))
            al_string_free(e)
        }
        return rc == 0
    }
}
