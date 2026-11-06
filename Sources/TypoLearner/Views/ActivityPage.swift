import SwiftUI
import TypoCore

struct ActivityPage: View {
    enum Filter: String, CaseIterable {
        case all = "All", review = "To review", fixed = "Fixed", rejected = "Undone or wrong"

        func includes(_ status: LogEntry.Status) -> Bool {
            switch self {
            case .all: return true
            case .review: return status == .suggested
            case .fixed: return [.applied, .right, .selfFixed].contains(status)
            case .rejected: return [.undone, .wrong].contains(status)
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var filter = Filter.all

    var body: some View {
        let entries = model.snapshot.log.filter { filter.includes($0.status) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Spacer()
                Text("Last 300 only. Each keeps just the typo and the word before it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "text.cursor",
                    description: Text("Typos it catches show up here. Mark them right or wrong to teach it faster.")
                )
            } else {
                List(entries) { ActivityRow(entry: $0) }
                    .listStyle(.inset)
            }
        }
    }
}

struct ActivityRow: View {
    let entry: LogEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                CorrectionText(before: entry.before, typed: entry.typed, suggestion: entry.suggestion)
                Text("\(entry.date.formatted(.relative(presentation: .named))) · \(percent(entry.confidence)) sure")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusTag(status: entry.status)
            if entry.status == .suggested {
                Button { model.mark(entry.id, right: true) } label: {
                    Label("Right", systemImage: "checkmark")
                }
                .help("It would have been right to fix this")
                Button { model.mark(entry.id, right: false) } label: {
                    Label("Wrong", systemImage: "xmark")
                }
                .help("Leave this word alone in future")
            } else if entry.status == .applied {
                Button { model.mark(entry.id, right: false) } label: {
                    Label("Wrong", systemImage: "xmark")
                }
                .help("This fix was wrong. It will not happen again.")
            }
        }
        .controlSize(.small)
        .padding(.vertical, 4)
    }
}
