import Foundation
import CryptoKit
import AirliftFFI

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
private let alLogBridge: ALLogCallback = { _, msg in
    guard let msg = msg else { return }
    SilenceLog.shared.append(String(cString: msg))
}

// MARK: - State

enum SilenceState {
    case unknown
    case silent
    case original
    case mixed

    var label: String {
        switch self {
        case .unknown: return "未检测"
        case .silent: return "已静音"
        case .original: return "原版（会响）"
        case .mixed: return "部分静音"
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

    var tint: String {
        switch self {
        case .unknown: return "gray"
        case .silent: return "green"
        case .original: return "red"
        case .mixed: return "orange"
        }
    }
}

// MARK: - View model

@MainActor
final class SilenceViewModel: ObservableObject {

    /// Both announcement files live here.
    static let targetDir = "/var/mobile/Library/CallServices/Greetings/default"
    /// Order matters only for the log; the write covers every file in the folder.
    static let leaves = ["StartDisclosureWithTone.m4a", "StopDisclosure.caf"]

    @Published var log: [String] = []
    @Published var busy = false
    @Published var stage = ""
    @Published var state: SilenceState = .unknown
    @Published var detail: [String] = []
    @Published var deviceIP = "10.7.0.1"
    @Published var pairingReady = false
    @Published var pairingName = ""

    private var drainTimer: Timer?
    /// Resolved on the main actor before each job — `PairingController` is
    /// `@MainActor`, so the background work must not call into it.
    private var currentPairingPath = ""

    // MARK: lifecycle

    init() {
        refreshPairingState()
        deviceIP = UserDefaults.standard.string(forKey: "silenceDeviceIP") ?? "10.7.0.1"
    }

    func refreshPairingState() {
        let path = PairingController.pairingFilePath()
        pairingReady = FileManager.default.fileExists(atPath: path)
        pairingName = PairingControllerHostName
    }

    func saveDeviceIP() {
        UserDefaults.standard.set(deviceIP, forKey: "silenceDeviceIP")
    }

    // MARK: plumbing

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

    /// Runs `body` off the main thread with the busy flag + log draining wired up.
    private func perform(_ title: String, _ body: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        stage = title
        log.append("── \(title) ──")
        applyTargetHost()
        currentPairingPath = PairingController.pairingFilePath()
        startDraining()

        DispatchQueue.global(qos: .userInitiated).async {
            body()
            DispatchQueue.main.async {
                self.stopDraining()
                self.busy = false
                self.stage = ""
            }
        }
    }

    private func applyTargetHost() {
        let ip = deviceIP.trimmingCharacters(in: .whitespaces)
        if ip.isEmpty {
            al_clear_target_hosts()
        } else {
            ip.withCString { _ = al_set_target_host($0) }
        }
    }

    private var pairingPath: String { currentPairingPath }

    // MARK: resources

    /// Directory holding the bundled replacement files ("silent" / "original").
    /// The Xcode project adds `Resources` as a folder reference, so the layout
    /// survives into the bundle; the flattened names are tried as a fallback.
    private func bundledDir(_ name: String) -> URL? {
        let fm = FileManager.default
        guard let res = Bundle.main.resourceURL else { return nil }
        let candidates = [
            res.appendingPathComponent("Resources/\(name)"),
            res.appendingPathComponent(name),
            res.appendingPathComponent("Resources").appendingPathComponent(name),
        ]
        for url in candidates where fm.fileExists(atPath: url.path) { return url }
        return nil
    }

    private func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: operations

    func check() {
        perform("检测") { [self] in
            var lines: [String] = []
            var tags: [String] = []

            for leaf in Self.leaves {
                switch readHash(leaf: leaf) {
                case .success(let size, let digest):
                    let silent = bundledDir("silent")
                        .flatMap { sha256(of: $0.appendingPathComponent(leaf)) }
                    let original = bundledDir("original")
                        .flatMap { sha256(of: $0.appendingPathComponent(leaf)) }
                    let tag: String
                    if digest == silent {
                        tag = "静音"
                    } else if digest == original {
                        tag = "原版"
                    } else {
                        tag = "未知版本"
                    }
                    tags.append(tag)
                    lines.append("\(leaf) — \(tag) · \(size) 字节 · \(digest.prefix(12))…")
                case .failure(let message):
                    lines.append("✗ \(leaf): \(message)")
                }
            }

            let finalLines = lines
            let finalTags = tags
            let failed = lines.contains { $0.hasPrefix("✗") }

            Task { @MainActor in
                self.detail = finalLines
                if failed {
                    self.state = .unknown
                } else if finalTags.allSatisfy({ $0 == "静音" }) {
                    self.state = .silent
                } else if finalTags.allSatisfy({ $0 == "原版" }) {
                    self.state = .original
                } else if finalTags.contains("静音") {
                    self.state = .mixed
                } else {
                    self.state = .unknown
                }
                self.log.append("检测结果：\(self.state.label)")
            }
        }
    }

    func silence() { write(bundled: "silent", title: "去除提示音") }
    func restore() { write(bundled: "original", title: "恢复原版") }

    private func write(bundled name: String, title: String) {
        guard let source = bundledDir(name) else {
            log.append("✗ 找不到内置资源目录 Resources/\(name)")
            return
        }
        perform(title) { [self] in
            // Stage a private copy so the exploit writes exactly these two files.
            let stageDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("silence_\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
                for leaf in Self.leaves {
                    let src = source.appendingPathComponent(leaf)
                    guard FileManager.default.fileExists(atPath: src.path) else {
                        SilenceLog.shared.append("✗ 缺少内置文件 \(leaf)")
                        return
                    }
                    try FileManager.default.copyItem(at: src, to: stageDir.appendingPathComponent(leaf))
                }
            } catch {
                SilenceLog.shared.append("✗ 暂存失败: \(error.localizedDescription)")
                return
            }
            defer { try? FileManager.default.removeItem(at: stageDir) }

            let ok = writeDir(source: stageDir.path, target: Self.targetDir)
            Task { @MainActor in
                self.log.append(ok ? "✅ \(title)完成" : "✗ \(title)失败")
                if ok { self.state = (name == "silent") ? .silent : .original }
            }
        }
    }

    // MARK: FFI

    private func readHash(leaf: String) -> Result<(UInt64, String), String> {
        var size: UInt64 = 0
        var sha: UnsafeMutablePointer<CChar>?
        var outError: UnsafeMutablePointer<CChar>?

        let rc = pairingPath.withCString { p in
            Self.targetDir.withCString { d in
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
            let message = outError.map { String(cString: $0) } ?? "读取失败（rc=\(rc)）"
            return .failure(message)
        }
        guard let s = sha else { return .failure("设备没有返回内容") }
        return .success((size, String(cString: s)))
    }

    private func writeDir(source: String, target: String) -> Bool {
        var outError: UnsafeMutablePointer<CChar>?
        let rc = pairingPath.withCString { p in
            source.withCString { s in
                target.withCString { t in
                    al_exploit_write_dir(p, s, t, alLogBridge, nil, &outError)
                }
            }
        }
        if let e = outError {
            let message = String(cString: e)
            SilenceLog.shared.append("✗ " + message)
            al_string_free(e)
        }
        return rc == 0
    }
}

// MARK: - Pairing host name

/// The on-device pairing host advertises itself under this name in
/// Settings › Privacy & Security › Developer Mode › Pair with App.
let PairingControllerHostName = "AirliftSilence"
