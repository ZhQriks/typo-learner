import Charts
import SwiftUI
import TypoCore

struct DashboardView: View {
    enum Page: String, CaseIterable, Identifiable {
        case overview, activity, keyboard, learned, privacy
        var id: Self { self }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .activity: return "Activity"
            case .keyboard: return "Keyboard"
            case .learned: return "Learned"
            case .privacy: return "Privacy"
            }
        }

        var icon: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .activity: return "list.bullet.rectangle"
            case .keyboard: return "keyboard"
            case .learned: return "brain"
            case .privacy: return "lock.shield"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var page: Page? = .overview

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch page ?? .overview {
                case .overview: OverviewPage()
                case .activity: ActivityPage()
                case .keyboard: KeyboardPage()
                case .learned: LearnedPage()
                case .privacy: PrivacyPage()
                }
            }
            .navigationTitle((page ?? .overview).title)
        }
        .frame(minWidth: 860, minHeight: 580)
        .modifier(LiveViewer())
    }
}

struct OverviewPage: View {
    @Environment(AppModel.self) private var model
    /// Slider position while dragging; saved once on release, so dragging does not redraw everything.
    @State private var threshold: Double?

    private var s: Snapshot { model.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.phase == .ready, model.needsPermission {
                    PermissionCallout()
                }
                readiness
                HStack(spacing: 12) {
                    Card { StatTile(value: s.total.words.formatted(), label: "Words typed") }
                    Card { StatTile(value: (s.total.suggested + s.total.applied).formatted(), label: "Typos caught") }
                    Card { StatTile(value: percent(s.total.accuracy), label: "Accuracy", caption: "\(s.total.judged) judged") }
                    Card { StatTile(value: s.totalErrors.formatted(), label: "Your mistakes learned") }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    caughtChart
                    accuracyChart
                }
                .fixedSize(horizontal: false, vertical: true)
                confidence
                prediction
                performance
            }
            .padding(24)
        }
    }

    private var readiness: some View {
        let judged = s.total.judged
        let accuracy = s.total.accuracy ?? 0
        let ready = judged >= 30 && accuracy >= 0.95
        return Card(title: "Mode: \(s.settings.mode.title)", icon: ready ? "checkmark.seal" : "eye") {
            Text(s.settings.mode.explanation).foregroundStyle(.secondary)
            if s.settings.mode != .active {
                if ready {
                    Text("Accuracy is \(percent(accuracy)) over \(judged) judged suggestions. Safe to switch on fixing.")
                    Button("Switch to Active") { model.setMode(.active) }
                        .buttonStyle(.borderedProminent)
                } else {
                    ProgressView(value: Double(min(judged, 30)), total: 30) {
                        Text("Readiness for Active: \(min(judged, 30)) of 30 judged suggestions, needs 95% right")
                            .font(.callout)
                    }
                    Text("Suggestions get judged when you fix a typo yourself, even before finishing the word, or when you mark them in Activity.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct DayBar: Identifiable {
        let id: String
        let date: Date
        let kind: String
        let count: Int
    }

    private var caughtChart: some View {
        let bars = s.days.flatMap { p in [
            DayBar(id: p.day + "f", date: p.date, kind: "Fixed", count: p.stat.applied),
            DayBar(id: p.day + "s", date: p.date, kind: "Would fix", count: p.stat.suggested),
        ] }
        return Card(title: "Typos caught per day", icon: "chart.bar") {
            if s.days.isEmpty {
                emptyChart
            } else {
                Chart(bars) {
                    BarMark(x: .value("Day", $0.date, unit: .day), y: .value("Typos", $0.count))
                        .foregroundStyle(by: .value("Kind", $0.kind))
                }
                .chartForegroundStyleScale(["Fixed": Color.brand, "Would fix": Color.brand.opacity(0.4)])
                .chartXAxis { dayAxis }
                .frame(height: 180)
            }
        }
    }

    private var accuracyChart: some View {
        let points = s.days.compactMap { p in p.stat.accuracy.map { (p.date, $0 * 100) } }
        return Card(title: "Accuracy per day", icon: "checkmark.seal") {
            if points.isEmpty {
                emptyChart
            } else {
                Chart(points, id: \.0) {
                    LineMark(x: .value("Day", $0.0, unit: .day), y: .value("Accuracy", $0.1))
                        .foregroundStyle(Color.green)
                    PointMark(x: .value("Day", $0.0, unit: .day), y: .value("Accuracy", $0.1))
                        .foregroundStyle(Color.green)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(format: Decimal.FormatStyle.Percent.percent.scale(1)) }
                .chartXAxis { dayAxis }
                .frame(height: 180)
            }
        }
    }

    private var dayAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: 7)) {
            AxisGridLine()
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
        }
    }

    private var emptyChart: some View {
        Text("No data yet. Keep typing as usual.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var confidence: some View {
        Card(title: "Confidence needed", icon: "gauge.with.dots.needle.33percent") {
            HStack {
                Slider(
                    value: Binding(get: { threshold ?? s.settings.threshold }, set: { threshold = ($0 * 100).rounded() / 100 }),
                    in: 0.80...0.99
                ) {
                    Text("Confidence needed")
                } minimumValueLabel: {
                    Text("80%")
                } maximumValueLabel: {
                    Text("99%")
                } onEditingChanged: { editing in
                    guard !editing, let threshold else { return }
                    model.setThreshold(threshold)
                    self.threshold = nil
                }
                .labelsHidden()
                Text(percent(threshold ?? s.settings.threshold))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(width: 56, alignment: .trailing)
            }
            Text("Higher means fewer fixes and fewer wrong ones. One real word is swapped for another only when you have made that swap yourself twice, and it needs 99%.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var prediction: some View {
        let t = s.total
        func rate(_ part: Int, _ whole: Int) -> Double? { whole > 0 ? Double(part) / Double(whole) : nil }
        return Card(title: "Word prediction (silent test)", icon: "text.cursor") {
            HStack(alignment: .top) {
                StatTile(value: percent(rate(t.nextTop3, t.predicted)), label: "Next word in its top 3")
                StatTile(value: percent(rate(t.nextTop1, t.predicted)), label: "Next word exactly")
                StatTile(value: percent(rate(t.completionSaved, t.letters)), label: "Letters completion would save")
            }
            Text("Nothing is shown or typed yet. At every word it guesses quietly from your own phrases and counts how often it would have been right, so you can see when prediction is worth turning on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var performance: some View {
        Card(title: "Performance", icon: "gauge.with.dots.needle.33percent") {
            HStack(alignment: .top) {
                StatTile(value: String(format: "%.1f%%", model.perf.cpuPercent), label: "CPU now")
                StatTile(value: String(format: "%.0f MB", model.perf.memoryMB), label: "Memory")
                StatTile(
                    value: model.perf.microsPerKey.map { String(format: "%.0f µs", $0) } ?? "–",
                    label: "Per keystroke"
                )
            }
            Text("Measured live while this window is open. The tap only listens, so it can never slow your typing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
