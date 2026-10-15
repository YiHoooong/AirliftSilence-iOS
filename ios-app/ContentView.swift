import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    /// The shared instance, not a fresh one: a Shortcut run and this screen
    /// have to show the same status.
    @ObservedObject private var vm = SilenceViewModel.shared
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

    /// `airliftsilence://check`, `airliftsilence://silence`,
    /// `airliftsilence://restore` — for a Shortcut the user writes by hand, or
    /// any other launcher that can only open a URL.
    private func handle(_ url: URL) {
        guard url.scheme == SilenceEngine.urlScheme else { return }
        let name = (url.host ?? url.path.replacingOccurrences(of: "/", with: "")).lowercased()
        guard let action = SilenceAction(rawValue: name) else {
            vm.log.append(String(localized: "Unknown action in URL: \(url.absoluteString)"))
            return
        }
        vm.request(action)
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
            // File URLs also arrive through AppDelegate.application(_:open:),
            // which is the only entry point that fires on a cold launch.
            .onOpenURL { url in
                if url.isFileURL {
                    vm.adoptPairingFile(at: url)
                } else {
                    handle(url)
                }
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
                Text("iOS plays a tone into the call when recording starts and stops")
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
                Label("Silence the announcements", systemImage: "speaker.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 12) {
                Button {
                    vm.check()
                } label: {
                    Label("Check", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    vm.restore()
                } label: {
                    Label("Restore the originals", systemImage: "arrow.uturn.backward")
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
                // LocalizedStringKey explicitly: a ternary of two literals can
                // otherwise bind to the non-localizing Text(String) overload.
                Text(LocalizedStringKey(vm.pairingReady ? "Pairing file ready" : "Pairing required"))
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            Text(LocalizedStringKey(vm.pairingReady
                 ? "A pairing file was found, so every action is available."
                 : "The exploit needs a pairing file. Pair this iPhone with itself below, or share an existing pairing file into this app."))
                .font(.caption)
                .foregroundColor(.secondary)

            if let pin = pairing.pairingPIN {
                Text("PIN: \(pin)")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundColor(.blue)
                Text("Type it in Settings › Privacy & Security › Developer Mode › Pair with App")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if pairing.running {
                Text("Pairing… \(pairing.pairingStatus)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    if pairing.running {
                        pairing.softCancel()
                    } else {
                        Task { await runPairing() }
                    }
                } label: {
                    Text(LocalizedStringKey(pairing.running ? "Cancel" : "Start pairing"))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("Re-check") { vm.refreshPairingState() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                if LocalDevVPN.isInstalled {
                    Button("Open LocalDevVPN") { LocalDevVPN.open() }
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
                    Label("Import pairing file", systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                // Pairing records are easy to lose — a re-signed build gets a
                // fresh container — so hand the user a way to get a copy out.
                if let url = vm.pairingFileURL {
                    ShareLink(item: url) {
                        Label("Export pairing file", systemImage: "square.and.arrow.up")
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
                if let url = urls.first { vm.adoptPairingFile(at: url) }
            case .failure(let error):
                vm.log.append(String(localized: "Import failed: \(error.localizedDescription)"))
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
            vm.log.append(String(localized: "✅ Paired: \(path)"))
            vm.check()
        } catch {
            vm.log.append(String(localized: "✗ Pairing failed: \(error.localizedDescription)"))
            vm.refreshPairingState()
        }
    }

    // MARK: tunnel

    private var tunnelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loopback tunnel address")
                .font(.subheadline.weight(.medium))
            TextField("10.7.0.1", text: $vm.deviceIP)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onSubmit { vm.saveDeviceIP() }
            Text("LocalDevVPN has to be running in loopback mode. 10.7.0.1 by default; try 10.7.0.2 or 10.7.0.3 if it will not connect.")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("⚠️ Never enter 127.0.0.1: remotepairingdeviced refuses the control channel and drops into a state where every connection fails, until you toggle Developer Mode off and on again.")
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
                    Text("Run log")
                    Spacer()
                    Text(LocalizedStringKey(showLog ? "Hide" : "Show"))
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
