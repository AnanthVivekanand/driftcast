import SwiftUI

/// Under a video's title in the details panel: the year, length and network on one line,
/// the genres on the next and, for an episode, its air date on a third, with the ratings
/// beside them at the right edge (the user's request, 2026-11-22; they had a row of their own
/// under the captions line). The year leads the first line in black, the rest being gray.
///
/// The genres keep to one line: a list too long for the room is cut short with "…" (the
/// user's call the same day; it wrapped, or pushed the ratings down). So the ratings stay
/// beside the text as long as the first line and the air date fit next to them. When those
/// don't (a film's IMDb, Rotten Tomatoes and Metacritic), the ratings go under the text, at
/// the right.
struct TitleFactsRow: View {
    /// "2008", or nil.
    let year: String?
    /// "1h 0m · AMC", or nil.
    let facts: String?
    /// "Drama, Crime, Thriller", or nil.
    let genres: String?
    let ratings: [MovieDetails.Rating]
    /// An episode's air date, "2002-11-03": a third line, "Aired 2002-11-03", under the genres
    /// (the user's placing, 2026-11-22; it was a row of its own further down).
    var aired: String? = nil

    var body: some View {
        if ratings.isEmpty {
            text(firstLineWraps: true)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    text(firstLineWraps: false)
                    badges
                }
                VStack(alignment: .leading, spacing: 8) {
                    text(firstLineWraps: true)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        badges
                    }
                }
            }
        }
    }

    private func text(firstLineWraps: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let year {
                line(Text(year).foregroundColor(.primary) + Text(facts.map { " · " + $0 } ?? "").foregroundColor(.secondary), wraps: firstLineWraps)
            } else if let facts {
                line(Text(facts).foregroundColor(.secondary), wraps: firstLineWraps)
            }
            if let genres {
                // One line, cut short with "…". Its ideal width is small on purpose: asked
                // how wide it would like to be, it would say the whole list, and the ratings
                // would be judged not to fit beside it.
                Text(genres)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(idealWidth: 40, maxWidth: .infinity, alignment: .leading)
                    .help(genres)
            }
            if let aired { line(Text("Aired \(aired)").foregroundColor(.secondary), wraps: false) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func line(_ words: Text, wraps: Bool) -> some View {
        let shown = words.font(.callout)
        if wraps {
            shown.fixedSize(horizontal: false, vertical: true)
        } else {
            shown.lineLimit(1).fixedSize()
        }
    }

    private var badges: some View {
        HStack(spacing: 10) {
            ForEach(ratings, id: \.source) { rating in
                VStack(spacing: 1) {
                    Text(rating.value).font(.callout.weight(.semibold)).monospacedDigit()
                    Text(rating.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .fixedSize()
    }
}
