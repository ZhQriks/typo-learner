import AppKit
import SwiftUI
import TypoCore

extension Color {
    /// Violet accent, lighter in dark mode for contrast.
    static let brand = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1)
            : NSColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 1)
    })
}

extension Mode {
    var title: String {
        switch self {
        case .off: return "Off"
        case .shadow: return "Shadow"
        case .active: return "Active"
        }
    }

    var explanation: String {
        switch self {
        case .off: return "Not listening. No keystroke is read."
        case .shadow: return "Learning and logging what it would fix. Your text is never touched."
        case .active: return "Fixing confident typos. Press ⌃⌥Z, or Backspace right after a fix, to undo it."
        }
    }
}

extension LogEntry.Status {
    var title: String {
        switch self {
        case .suggested: return "To review"
        case .applied: return "Fixed"
        case .undone: return "Undone"
        case .right: return "Right"
        case .wrong: return "Wrong"
        case .selfFixed: return "You fixed it"
        case .differed: return "Different fix"
        }
    }

    var color: Color {
        switch self {
        case .suggested: return .orange
        case .applied, .right, .selfFixed: return .green
        case .undone, .wrong, .differed: return .red
        }
    }
}

func percent(_ value: Double?) -> String {
    value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
}

struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: icon ?? "circle")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct StatusTag: View {
    let status: LogEntry.Status

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(status.color)
            .background(Capsule().fill(status.color.opacity(0.14)))
    }
}

/// "typo → fix", the typo struck through in red and the fix in green.
struct CorrectionText: View {
    let before: String?
    let typed: String
    let suggestion: String

    var body: some View {
        HStack(spacing: 6) {
            if let before {
                Text(before).foregroundStyle(.secondary)
            }
            Text(typed).strikethrough().foregroundStyle(.red)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text(suggestion).fontWeight(.semibold).foregroundStyle(.green)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(typed), corrected to \(suggestion)")
    }
}

/// Counts open windows so live numbers refresh only while someone looks.
struct LiveViewer: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onAppear { model.viewers += 1 }
            .onDisappear { model.viewers -= 1 }
    }
}

struct PermissionCallout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permission needed", systemImage: "hand.raised")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            if !model.canListen {
                Text("Input Monitoring lets it see keystrokes. Without it nothing works.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Input Monitoring") {
                    model.requestPermissions()
                    model.openPrivacySettings("Privacy_ListenEvent")
                }
            }
            if !model.canType {
                Text("Accessibility lets it type fixes. Only needed for Active mode.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility") {
                    model.requestPermissions()
                    model.openPrivacySettings("Privacy_Accessibility")
                }
            }
        }
        .controlSize(.small)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }
}
