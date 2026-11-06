import AppKit
import SwiftUI
import TypoCore

struct PrivacyPage: View {
    @Environment(AppModel.self) private var model
    @State private var newWord = ""
    @State private var confirmErase = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "What stays on this Mac", icon: "lock.shield") {
                    fact("network.slash", "No network access. The app is sandboxed without the network permission, so it cannot send anything anywhere.")
                    fact("lock.fill", "Everything it learns is encrypted with AES-256-GCM. The key is in your login Keychain and never leaves this Mac.")
                    fact("text.badge.xmark", "No running text is stored. Only the word you are typing and the one before it are held in memory.")
                    fact("number", "Names and other words outside the dictionary are saved only as salted hashes.")
                    fact("eye.slash", "Password fields, blocked apps and Off mode are never read.")
                    Divider()
                    HStack {
                        Text(model.dataFile.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Show in Finder", systemImage: "folder") { model.revealDataFile() }
                            .controlSize(.small)
                    }
                    if let note = model.storageNote {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                blockedApps

                Card(title: "Protected words", icon: "hand.raised") {
                    Text("Never corrected. Saved hashed, so they cannot be listed back. \(model.snapshot.protectedCount) so far.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Word to protect", text: $newWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addWord)
                        Button("Protect", systemImage: "plus", action: addWord)
                            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .frame(maxWidth: 420)
                }

                Card(title: "Reset", icon: "trash") {
                    HStack {
                        Button("Clear activity log") { model.clearLog() }
                        Button("Erase everything learned", role: .destructive) { confirmErase = true }
                    }
                    Text("Erasing keeps your settings and blocked apps.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .confirmationDialog("Erase everything it learned?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { model.eraseLearning() }
        } message: {
            Text("Your mistake patterns, vocabulary and activity are deleted. This cannot be undone.")
        }
    }

    private var blockedApps: some View {
        let blocked = model.snapshot.settings.blockedApps
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !blocked.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
            .sorted { $0.1 < $1.1 }
        return Card(title: "Blocked apps", icon: "eye.slash") {
            Text("Keystrokes in these apps are ignored completely.").font(.callout).foregroundStyle(.secondary)
            ForEach(blocked, id: \.self) { id in
                HStack {
                    AppName(bundleID: id)
                    Spacer()
                    Button { model.unblock(id) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop blocking \(id)")
                }
            }
            Menu("Block a running app") {
                ForEach(running, id: \.0) { id, name in
                    Button(name) { model.block(id) }
                }
            }
            .fixedSize()
        }
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.brand)
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        model.protect(word)
        newWord = ""
    }
}

private struct AppName: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
            if url != nil {
                Text(bundleID).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
