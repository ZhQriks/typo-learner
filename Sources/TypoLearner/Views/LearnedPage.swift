import SwiftUI
import TypoCore

struct LearnedPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Card { StatTile(value: s.pairs.count.formatted(), label: "Typo pairs seen", caption: "top 100 shown") }
                Card { StatTile(value: s.vocabulary.formatted(), label: "Dictionary words you use") }
                Card { StatTile(value: s.yourWords.formatted(), label: "Your own words", caption: "names, slang; hashed") }
                Card { StatTile(value: s.protectedCount.formatted(), label: "Protected words") }
            }
            .fixedSize(horizontal: false, vertical: true)

            Text("Each pair gets stronger every time you fix it yourself or confirm it, and backs off hard after one undo.")
                .font(.callout).foregroundStyle(.secondary)

            if s.pairs.isEmpty {
                ContentUnavailableView(
                    "Nothing learned yet",
                    systemImage: "brain",
                    description: Text("Fix a typo with Backspace as you normally would and it shows up here.")
                )
            } else {
                Table(s.pairs) {
                    TableColumn("Typo") { Text($0.typed).strikethrough().foregroundStyle(.red) }
                    TableColumn("Meant") { Text($0.intended).fontWeight(.semibold).foregroundStyle(.green) }
                    TableColumn("You fixed") { Text("\($0.stat.fixedByYou)").monospacedDigit() }
                    TableColumn("Auto-fixed") { Text("\($0.stat.applied)").monospacedDigit() }
                    TableColumn("Confirmed") { Text("\($0.stat.confirmed)").monospacedDigit() }
                    TableColumn("Rejected") {
                        Text("\($0.stat.rejected)").monospacedDigit()
                            .foregroundStyle($0.stat.rejected > 0 ? Color.red : Color.primary)
                    }
                }
            }
        }
        .padding(24)
    }
}
