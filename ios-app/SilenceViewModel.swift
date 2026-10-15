import Foundation
import SwiftUI
import UserNotifications

// MARK: - App identity

/// The app's single public name. Used for the home screen, the pairing host
/// advertised to Settings › Developer Mode, and the UI headings, so the device
/// never shows a different name than the app calls itself.
enum AppIdentity {
    static let name = "AirliftSilence"
}

// MARK: - Pairing PIN notification

/// The PIN has to be read while the user is inside Settings typing it, and the
/// app's own screen is not visible at that moment — so post it as a
/// notification as well.
enum PinNotifier {
    private static let identifier = "airlift-silence-pairing-pin"

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(pin: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Pairing code  \(pin)")
        content.body = String(localized: "Type it in Settings › Privacy & Security › Developer Mode › Pair with App")
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

// MARK: - View model

/// Screen state plus the one place a run is serialised.
///
/// There is exactly one instance because the Shortcuts intent and the screen
/// must show the same status, and because the device tolerates a single exploit
/// session at a time — see `run(_:)`.
@MainActor
final class SilenceViewModel: ObservableObject {

    static let shared = SilenceViewModel()

    @Published var log: [String] = []
    @Published var busy = false
    @Published var stage = ""
    @Published var state: SilenceState = .unknown
    @Published var detail: [String] = []
    @Published var deviceIP = SilenceEngine.defaultTargetHost
    @Published var pairingReady = false
    @Published var pairingName = ""
    /// The pairing file on disk, for the share sheet. Nil until one exists.
    @Published var pairingFileURL: URL?

    private var drainTimer: Timer?
    /// The tail of the run queue. A Shortcut and the view's automatic check can
    /// arrive at the same moment.
    private var chain: Task<SilenceOutcome, Never>?
    private var queued = 0

    private init() {
        deviceIP = SilenceEngine.storedTargetHost
        refreshPairingState()
    }

    // MARK: lifecycle

    func refreshPairingState() {
        let path = PairingController.pairingFilePath()
        // A zero-byte pairing file is what a failed pairing leaves behind, so
        // treat it as "not ready" rather than offering it for export.
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        pairingReady = size > 0
        pairingFileURL = pairingReady ? URL(fileURLWithPath: path) : nil
        pairingName = AppIdentity.name
    }

    func saveDeviceIP() {
        SilenceEngine.storedTargetHost = deviceIP
    }

    // MARK: runs

    /// Runs one action and waits for its outcome, so a Shortcut can use the
    /// result. Runs are serialised: the device only takes one exploit session at
    /// a time, and the screen's automatic check on appear is one too.
    @discardableResult
    func run(_ action: SilenceAction) async -> SilenceOutcome {
        let previous = chain
        queued += 1
        busy = true

        let task = Task { @MainActor in
            defer { self.finishQueuedRun() }
            _ = await previous?.value
            return await self.execute(action)
        }
        chain = task
        return await task.value
    }

    /// Fire-and-forget, for buttons and URL-scheme launches.
    func request(_ action: SilenceAction) {
        Task { await run(action) }
    }

    func check() { request(.check) }
    func silence() { request(.silence) }
    func restore() { request(.restore) }

    private func finishQueuedRun() {
        queued = max(0, queued - 1)
        if queued == 0 { busy = false }
    }

    private func execute(_ action: SilenceAction) async -> SilenceOutcome {
        stage = action.title
        append("── \(action.title) ──")

        // Resolved on the main actor before the job: PairingController is
        // @MainActor, so the background work must not call into it.
        SilenceEngine.applyTargetHost(deviceIP)
        let pairingPath = PairingController.pairingFilePath()
        startDraining()

        let outcome = await Task.detached(priority: .userInitiated) {
            SilenceEngine.run(action, pairingPath: pairingPath)
        }.value

        stopDraining()
        stage = ""
        for line in outcome.lines { append(line) }
        if !outcome.detail.isEmpty { detail = outcome.detail }
        state = outcome.state
        return outcome
    }

    // MARK: plumbing

    private func append(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func startDraining() {
        drainTimer?.invalidate()
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let new = SilenceLog.shared.drain()
                if !new.isEmpty { self.log.append(contentsOf: new) }
            }
        }
    }

    private func stopDraining() {
        drainTimer?.invalidate()
        drainTimer = nil
        log.append(contentsOf: SilenceLog.shared.drain())
    }
}
