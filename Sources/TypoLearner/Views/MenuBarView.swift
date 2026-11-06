import SwiftUI
import TypoCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Typo Learner").font(.headline)
                Spacer()
                status
            }

            if case let .failed(message) = model.phase {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            if model.phase == .ready, model.needsPermission {
                PermissionCallout()
            }

            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.phase != .ready)
            Text(model.mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(alignment: .top) {
                StatTile(value: "\(model.snapshot.today.words)", label: "Words today")
                StatTile(value: "\(model.snapshot.today.suggested + model.snapshot.today.applied)", label: "Typos caught")
                StatTile(value: percent(model.snapshot.total.accuracy), label: "Accuracy")
            }

            if let last = model.snapshot.log.first {
                HStack {
                    CorrectionText(before: nil, typed: last.typed, suggestion: last.suggestion)
                        .font(.callout)
                    Spacer()
                    StatusTag(status: last.status)
                }
            }

            Divider()

            VStack(spacing: 2) {
                MenuRow(title: "Undo last fix", icon: "arrow.uturn.backward", shortcut: "⌃⌥Z") { model.undo() }
                    .disabled(model.mode != .active)
                MenuRow(title: "Open Dashboard", icon: "macwindow") {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                }
                MenuRow(title: "Quit", icon: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 310)
        .modifier(LiveViewer())
    }

    @ViewBuilder private var status: some View {
        let (text, color): (String, Color) = switch model.phase {
        case .loading: ("Loading", .secondary)
        case .failed: ("Error", .red)
        case .ready where !model.canListen: ("No permission", .orange)
        case .ready where model.mode == .off: ("Off", .secondary)
        case .ready: (model.listening ? "Listening" : "Starting", model.listening ? .green : .secondary)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Full-width menu item with a hover highlight.
struct MenuRow: View {
    let title: String
    let icon: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
