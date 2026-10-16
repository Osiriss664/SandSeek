import AppKit
import SwiftUI

/// Short hints for using the app, and what our own tests on a Mac found.
/// Plain text only: nothing here changes a setting.
struct TipsScreen: View {
    private let tips: [(title: String, text: String)] = [
        ("Quick answer or Thorough?",
         "Use Quick answer for simple facts: a capital, a date, one number. Use Thorough when you compare things or need several numbers. It reads more pages and takes longer."),
        ("Which model server?",
         "In our tests, Ollama (experimental) with a small model was faster for quick look-ups. TUFF with a bigger model was slower, but read more and gave fuller answers to hard questions."),
        ("One model server at a time",
         "On a Mac with 16 GB of memory, run only one model server at a time, and close the TUFF app while you research. Two models at once fill the memory and slow everything down."),
        ("Check the numbers",
         "Look at the sources and the Figure check list under the answer. A listed number is not always wrong, but check it on the source page."),
        ("If the answer may be incomplete",
         "Ask it again with Thorough, or split it into two smaller questions."),
    ]

    private let findings: [(title: String, text: String)] = [
        ("Ollama with Gemma 4 12B",
         "Answered five test questions in about 8.5 minutes in total. The quickest simple question took about 35 seconds, the others up to 3 minutes. All simple answers were right. On the hard comparison question it stopped early and left part of the answer open. It used almost all of the Mac's 16 GB of memory."),
        ("TUFF with Qwen 3.6 35B",
         "Needed about 18.5 minutes for the same five questions; simple questions took about 2 to 3 minutes. All answers were right, and it gave the only complete answer to the hard question, with 11 sources. It ran out of steps twice and listed more numbers in the Figure check, mostly rounded ones. It appeared to leave much more memory free, though the measurement does not fully count the model."),
        ("Models on TUFF, without web search",
         "In a chat test without the web, Qwen 3.6 35B and Ornith 9B both scored 16 of 18 points; Ornith 9B was about twice as fast. Ornith 35B scored lower (13 of 18). All three made up place names when asked from memory, so check facts."),
        ("In short",
         "Ollama with a small model for quick look-ups, TUFF with a bigger model for deeper research."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(
                    title: "Tips",
                    subtitle: "A few hints for good answers, and what our own tests found.")
                TipsList(icon: "lightbulb", title: "Tips", note: nil, items: tips)
                TipsList(
                    icon: "chart.bar",
                    title: "Our experience",
                    note: "From our own tests on a Mac with an M5 chip and 16 GB of memory, October 2026. One run per question, so treat these as rough guides, not a benchmark. The number after a model's name is its size; bigger models usually need more memory.",
                    items: findings)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One card: a title, an optional note under it, and short titled paragraphs.
private struct TipsList: View {
    let icon: String
    let title: String
    let note: String?
    let items: [(title: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).font(.headline)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.semibold))
                    Text(item.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cardStyle()
    }
}
