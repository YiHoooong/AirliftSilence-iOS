import AppIntents
import Foundation

// MARK: - The action parameter

/// Makes `SilenceAction` a pickable menu in the Shortcuts app instead of a
/// string the user has to type.
extension SilenceAction: AppEnum {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Announcement action")
    }

    static var caseDisplayRepresentations: [SilenceAction: DisplayRepresentation] {
        [
            .check: DisplayRepresentation(title: "Check"),
            .silence: DisplayRepresentation(title: "Silence the announcements"),
            .restore: DisplayRepresentation(title: "Restore the originals"),
        ]
    }
}

// MARK: - Shared entry point

/// Every intent goes through the view model rather than the engine directly, so
/// a Shortcut and the screen share one queue and one status — the device only
/// tolerates one exploit session at a time.
private enum ShortcutRunner {
    static func run(_ action: SilenceAction) async -> SilenceOutcome {
        await SilenceViewModel.shared.run(action)
    }
}

// MARK: - Intents

/// Check, silence, or restore. This is the flexible one: a Shortcut can pass a
/// different action per run, and the app's own Shortcuts show up in Shortcuts.
struct AirliftSilenceIntent: AppIntent {

    static var title: LocalizedStringResource { "Call-recording announcement" }

    static var description: IntentDescription? {
        IntentDescription(
            "Checks, silences, or restores the announcement iOS plays into a recorded call. Needs a pairing file and the LocalDevVPN loopback tunnel."
        )
    }

    /// A run is a long device-side session, so the app has to be in the
    /// foreground: a background intent gets cut off after a few seconds and the
    /// tunnel is torn down mid-transfer. (`openAppWhenRun` is deprecated in
    /// iOS 26 in favour of `supportedModes`, which iOS 18 — this app's floor —
    /// does not have.)
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Action", default: .check)
    var action: SilenceAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) for call recording")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let outcome = await ShortcutRunner.run(action)
        return .result(value: outcome.summary, dialog: "\(outcome.summary)")
    }
}

/// One-tap silencing, with no parameter menu to walk through.
struct SilenceAnnouncementsIntent: AppIntent {

    static var title: LocalizedStringResource { "Silence the call-recording announcements" }

    static var description: IntentDescription? {
        IntentDescription("Replaces the recording start/stop announcements with silent files.")
    }

    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let outcome = await ShortcutRunner.run(.silence)
        return .result(value: outcome.summary, dialog: "\(outcome.summary)")
    }
}

/// Puts Apple's own files back.
struct RestoreAnnouncementsIntent: AppIntent {

    static var title: LocalizedStringResource { "Restore the call-recording announcements" }

    static var description: IntentDescription? {
        IntentDescription("Restores the original recording start/stop announcements.")
    }

    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let outcome = await ShortcutRunner.run(.restore)
        return .result(value: outcome.summary, dialog: "\(outcome.summary)")
    }
}

// MARK: - Siri / Spotlight phrases

/// Makes the actions show up in the Shortcuts app and in Spotlight without the
/// user adding them first. Every phrase has to contain `\(.applicationName)`.
struct AirliftSilenceShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AirliftSilenceIntent(),
            phrases: [
                "\(.applicationName) 检查通话录音提示音",
                "Check the call-recording announcement in \(.applicationName)",
            ],
            shortTitle: "Call-recording announcement",
            systemImageName: "waveform.badge.magnifyingglass"
        )
        AppShortcut(
            intent: SilenceAnnouncementsIntent(),
            phrases: [
                "\(.applicationName) 去掉通话录音提示音",
                "Silence the call-recording announcement with \(.applicationName)",
            ],
            shortTitle: "Silence announcements",
            systemImageName: "speaker.slash.fill"
        )
        AppShortcut(
            intent: RestoreAnnouncementsIntent(),
            phrases: [
                "\(.applicationName) 恢复通话录音提示音",
                "Restore the call-recording announcement with \(.applicationName)",
            ],
            shortTitle: "Restore announcements",
            systemImageName: "arrow.uturn.backward"
        )
    }
}
