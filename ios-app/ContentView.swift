import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = SilenceViewModel()
    @ObservedObject private var pairing = PairingController.shared
    @State private var showLog = false
    @State private var showImporter = false

    /// Pairing files come from other sideloaders, which do not agree on an
    /// extension. `.plist` covers an exported record; the rest are the names
    /// SideStore / LiveContainer / Jitterbug use.
    private static let pairingTypes: [UTType] = {
        var types: [UTType] = [.propertyList, .data]
        for ext in ["mobiledevicepairing", "mobilepairing", "plist"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) {
                types.append(t)
            }
        }
        return types
    }()

    /// Adopt a pairing file the user handed us, whether it came from the
    /// document picker or from "Open in AirliftSilence". A URL from outside the
    /// sandbox needs security-scoped access before it can be read.
    private func adopt(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let adopted = PairingController.syncCanonicalPairingFile(from: url.path)
        vm.refreshPairingState()
        if vm.pairingReady {
            vm.log.append("已导入配对文件：\((adopted as NSString).lastPathComponent)")
        } else {
            vm.log.append("该文件读不出内容，可能不是有效的配对记录：\(url.lastPathComponent)")
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if !vm.detail.isEmpty { detailCard }
                    actionButtons
                    pairingCard
                    tunnelCard
                    logCard
                }
                .padding()
            }
            .navigationTitle(AppIdentity.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { vm.check() }
            // Counterpart to the export button: Info.plist already advertises
            // that this app opens plists, so adopt one when it is handed to us
            // ("Open in AirliftSilence") instead of silently doing nothing.
            .onOpenURL { url in
                guard url.isFileURL else { return }
                adopt(url)
            }
        }
    }

    // MARK: status

    private var statusCard: some View {
        VStack(spacing: 10) {
            Image(systemName: vm.state.symbol)
                .font(.system(size: 52))
                .foregroundColor(stateColor(vm.state))
            Text(vm.state.label)
                .font(.title2.weight(.semibold))
            if vm.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(vm.stage).foregroundColor(.secondary)
                }
                .font(.subheadline)
            } else {
                Text("iOS 会把录音开始/结束时的提示音播给通话双方")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(vm.detail, id: \.self) { line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(line.hasPrefix("✗") ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func stateColor(_ state: SilenceState) -> Color {
        switch state {
        case .unknown: return .gray
        case .silent: return .green
        case .original: return .red
        case .mixed: return .orange
        }
    }

    // MARK: actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                vm.silence()
            } label: {
                Label("去除提示音", systemImage: "speaker.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 12) {
                Button {
                    vm.check()
                } label: {
                    Label("检测", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    vm.restore()
                } label: {
                    Label("恢复原版", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .disabled(vm.busy || !vm.pairingReady)
        .opacity((vm.busy || !vm.pairingReady) ? 0.5 : 1)
    }

    // MARK: pairing

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: vm.pairingReady ? "checkmark.seal.fill" : "person.badge.key")
                    .foregroundColor(vm.pairingReady ? .green : .orange)
                Text(vm.pairingReady ? "配对文件已就绪" : "需要先配对")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            Text(vm.pairingReady
                 ? "已找到配对文件，可以执行操作。"
                 : "本机跑这个漏洞需要一份配对文件。可以点下面按钮让手机给自己配对，或者把现成的配对文件分享进来。")
                .font(.caption)
                .foregroundColor(.secondary)

            if let pin = pairing.pairingPIN {
                Text("PIN：\(pin)")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundColor(.blue)
                Text("到 设置 › 隐私与安全性 › 开发者模式 › 与 App 配对，输入上面的 PIN")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if pairing.running {
                Text("配对中…\(pairing.pairingStatus)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button(pairing.running ? "取消" : "开始配对") {
                    if pairing.running {
                        pairing.softCancel()
                    } else {
                        Task { await runPairing() }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("重新检查") { vm.refreshPairingState() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                if LocalDevVPN.isInstalled {
                    Button("打开 LocalDevVPN") { LocalDevVPN.open() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }

            // Import and export side by side. Importing through a picker is more
            // dependable than the document route: it needs no Info.plist
            // registration and no app restart, and it works for the pairing-file
            // extensions other sideloaders use.
            HStack(spacing: 10) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入配对文件", systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                // Pairing records are easy to lose — a re-signed build gets a
                // fresh container — so hand the user a way to get a copy out.
                if let url = vm.pairingFileURL {
                    ShareLink(item: url) {
                        Label("导出配对文件", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.pairingTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { adopt(url) }
            case .failure(let error):
                vm.log.append("导入失败：\(error.localizedDescription)")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func runPairing() async {
        do {
            let path = try await PairingController.shared.startAndWait()
            vm.refreshPairingState()
            vm.log.append("✅ 配对完成：\(path)")
            vm.check()
        } catch {
            vm.log.append("✗ 配对失败：\(error.localizedDescription)")
            vm.refreshPairingState()
        }
    }

    // MARK: tunnel

    private var tunnelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("回环隧道地址")
                .font(.subheadline.weight(.medium))
            TextField("10.7.0.1", text: $vm.deviceIP)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onSubmit { vm.saveDeviceIP() }
            Text("需要开着 LocalDevVPN（回环模式）。默认 10.7.0.1，连不上可以试 10.7.0.2 / 10.7.0.3。")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("⚠️ 不要填 127.0.0.1：会让 remotepairingdeviced 拒绝控制通道并进入丢弃状态，之后所有连接都会失败，只能靠关掉再打开开发者模式恢复。")
                .font(.caption2)
                .foregroundColor(.orange)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showLog.toggle() }
            } label: {
                HStack {
                    Image(systemName: "text.alignleft")
                    Text("运行日志")
                    Spacer()
                    Text(showLog ? "收起" : "展开")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showLog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(vm.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - LocalDevVPN helper

enum LocalDevVPN {
    private static let url = URL(string: "localdevvpn://")!

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(url)
    }

    static func open() {
        UIApplication.shared.open(url)
    }
}
