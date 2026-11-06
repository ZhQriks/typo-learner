import SwiftUI
import TypoCore

struct KeyboardPage: View {
    @Environment(AppModel.self) private var model
    @State private var lang = Lang.en

    private let keySize: CGFloat = 46
    private let gap: CGFloat = 6

    var body: some View {
        let rows = Keyboard.rows[lang] ?? []
        let counts = model.snapshot.keyErrors
        let peak = rows.joined().map { counts[$0] ?? 0 }.max() ?? 0
        let patterns = model.snapshot.patterns.filter { $0.lang == lang }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Layout", selection: $lang) {
                    Text("English").tag(Lang.en)
                    Text("Russian").tag(Lang.ru)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Card(title: "Where your mistakes happen", icon: "keyboard") {
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            HStack(spacing: gap) {
                                ForEach(row, id: \.self) { key in
                                    keyCell(key, count: counts[key] ?? 0, peak: peak)
                                }
                            }
                            .padding(.leading, Keyboard.rowOffsets[index] * (keySize + gap))
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Fewer").font(.caption).foregroundStyle(.secondary)
                        LinearGradient(colors: [Color.brand.opacity(0.06), Color.brand.opacity(0.9)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 140, height: 8)
                            .clipShape(Capsule())
                        Text("More").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                    Text("Counts every key involved in a mistake you or the app fixed: the key you hit and the one you meant.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "Your most common slips", icon: "chart.bar") {
                    if patterns.isEmpty {
                        Text("Nothing learned for this layout yet.").foregroundStyle(.secondary)
                    } else {
                        let top = patterns.first?.count ?? 1
                        ForEach(patterns.prefix(15)) { row in
                            HStack {
                                Text(row.label).frame(width: 180, alignment: .leading)
                                ProgressView(value: Double(row.count), total: Double(top))
                                    .accessibilityHidden(true)
                                Text("\(row.count)").monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func keyCell(_ key: Character, count: Int, peak: Int) -> some View {
        let heat = peak > 0 ? Double(count) / Double(peak) : 0
        return VStack(spacing: 1) {
            Text(String(key).uppercased()).font(.system(size: 15, weight: .semibold))
            Text(count > 0 ? "\(count)" : " ").font(.system(size: 10)).monospacedDigit()
        }
        .foregroundStyle(heat > 0.55 ? Color.white : Color.primary)
        .frame(width: keySize, height: keySize)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.brand.opacity(0.06 + 0.84 * heat)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Key \(String(key)), \(count) mistakes")
    }
}
