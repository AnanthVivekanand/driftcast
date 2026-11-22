import SwiftUI

/// Under a video's title in the details panel: the year, length and network on one line and
/// the genres on the next, with the ratings beside them at the right edge (the user's
/// request, 2026-11-22; they had a row of their own under the captions line).
///
/// The ratings sit beside the text when both fit. One rating stays there even when the text
/// has to wrap. Several that don't fit (a film's IMDb, Rotten Tomatoes and Metacritic) go
/// under the text instead.
struct TitleFactsRow: View {
    /// "2008 · 1h 0m · AMC", or nil.
    let facts: String?
    /// "Drama, Crime, Thriller", or nil.
    let genres: String?
    let ratings: [MovieDetails.Rating]

    private var hasText: Bool { facts != nil || genres != nil }

    var body: some View {
        if ratings.isEmpty {
            text(wraps: true)
        } else if !hasText {
            badges
        } else {
            ViewThatFits(in: .horizontal) {
                beside(wraps: false)
                if ratings.count == 1 {
                    beside(wraps: true)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        text(wraps: true)
                        badges
                    }
                }
            }
        }
    }

    private func beside(wraps: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            text(wraps: wraps)
            Spacer(minLength: 0)
            badges
        }
    }

    private func text(wraps: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let facts { line(facts, wraps: wraps) }
            if let genres { line(genres, wraps: wraps) }
        }
    }

    @ViewBuilder private func line(_ words: String, wraps: Bool) -> some View {
        let shown = Text(words).font(.callout).foregroundStyle(.secondary)
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
