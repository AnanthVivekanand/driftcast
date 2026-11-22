import SwiftUI

/// A green mark beside "No closed captions" when OpenSubtitles has subtitles for the video
/// (`OnlineSubtitleLookup`), with a bubble that offers them. The bubble opens by itself the
/// first time they are found for a video, and again whenever the mark is clicked (the user's
/// request, 2026-11-21). Nothing shows when Settings say "I don't care about subtitles".
struct FoundSubtitlesBadge: View {
    let item: MediaItem
    let language: String
    /// Whether this mark may open the bubble by itself. Only one place does, once a video: the
    /// video window for the video playing, the details panel for one only selected.
    var announces = true
    /// The full search; the window it opens over depends on where the mark is.
    var seeAll: () -> Void

    @ObservedObject private var online = OnlineSubtitleLookup.shared
    @EnvironmentObject private var player: PlaybackController
    @AppStorage(Prefs.hideSubtitleNotices) private var hideNotices = false
    @State private var open = false

    private var best: OpenSubtitlesClient.Result? { online.offer(for: item.url, language: language) }

    var body: some View {
        if !hideNotices, let best {
            let match = OnlineSubtitleLookup.Match(best)
            Button { open.toggle() } label: {
                // The mark with words, in a pill: what was found and how good a match it is.
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.bubble.fill")
                    Text(match.found)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(match.color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(match.color.opacity(0.16)))
                .overlay(Capsule().strokeBorder(match.color.opacity(0.45), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Click to add them, or see everything OpenSubtitles has for this video")
            .accessibilityLabel(match.found)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                FoundSubtitlesBubble(item: item, language: language, close: { open = false },
                                     seeAll: { open = false; seeAll() })
                    .environmentObject(player)
            }
            .onAppear {
                guard announces, online.firstAnnouncement(for: item.url, language: language) else { return }
                // After the window has settled, or the bubble points at where the mark was.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { open = true }
            }
        }
    }
}

/// What the bubble says. An exact match (made from this very file) is simply offered; any
/// other says how near it is, and the full search is a click away. The same words make the
/// details panel's card (`inCard`), which has no Not Now and doesn't take the Return key.
struct FoundSubtitlesBubble: View {
    let item: MediaItem
    let language: String
    var close: () -> Void = {}
    var seeAll: () -> Void
    var inCard = false

    @ObservedObject private var online = OnlineSubtitleLookup.shared
    @EnvironmentObject private var player: PlaybackController
    @State private var error: String?

    private var state: OnlineSubtitleLookup.State? { online.state(for: item.url, language: language) }
    private var best: OpenSubtitlesClient.Result? { online.offer(for: item.url, language: language) }
    private var downloading: Bool { if case .downloading = state { return true } else { return false } }
    /// "movie" or "show", as the user put it.
    private var kind: String { MediaTitle.parse(fileName: item.baseName).isEpisode ? "show" : "movie" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.bubble.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(best.map { OnlineSubtitleLookup.Match($0).color } ?? .green)
                VStack(alignment: .leading, spacing: 4) {
                    if let best { MatchTagView(match: OnlineSubtitleLookup.Match(best)) }
                    if let best, best.hashMatch {
                        Text("Found subtitles for this \(kind).").font(.headline)
                        Text("Would you like to add them?").font(.callout)
                    } else {
                        Text("Found \(Lang.name(language) ?? language) subtitles for this \(kind) online.")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let best {
                            Text(OnlineSubtitleLookup.describe(best))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button(downloading ? "Adding…" : "Add Them") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(inCard ? nil : .defaultAction)
                    .disabled(best == nil || downloading)
                    .help("Downloads them from OpenSubtitles and adds them to the video")
                if !inCard { Button("Not Now") { close() } }
                Spacer(minLength: 12)
                Button { seeAll() } label: {
                    Text("See all on OpenSubtitles…")
                        .underline()
                        .foregroundStyle(Color(nsColor: .linkColor))
                }
                .buttonStyle(.plain)
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(inCard ? 0 : 16)
        .frame(width: inCard ? nil : 380, alignment: .leading)
    }

    private func add() {
        error = nil
        let video = item
        Task {
            let (file, failure) = await online.download(for: video, language: language)
            if let file {
                player.addSubtitleFile(file, to: video)
                close()
            } else if let failure {
                error = failure.localizedDescription
            }
        }
    }
}

extension OnlineSubtitleLookup.Match {
    /// Green when it should be in sync, blue when likely, orange when it may well not be.
    var color: Color {
        switch self {
        case .exact, .sameRelease: return .green
        case .close: return .blue
        case .titleOnly: return .orange
        }
    }
}

/// The match's tag in the bubble, in the style of the search window's EXACT, MATCH and CLOSE.
struct MatchTagView: View {
    let match: OnlineSubtitleLookup.Match

    var body: some View {
        Text(match.tag)
            .font(.caption2.weight(.bold))
            .foregroundStyle(match.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(match.color.opacity(0.18)))
            .fixedSize()
    }
}

/// The details panel's card for subtitles found online: the bubble's words and buttons in a
/// box of their own, tinted by how good the match is, above the Closed Captions section, so
/// the offer stands apart from the video's own captions (the user's request, 2026-11-21).
struct OnlineSubtitlesCard: View {
    let item: MediaItem
    /// The subtitle language when the video has none in it; nil shows nothing.
    let language: String?
    var seeAll: () -> Void

    @ObservedObject private var online = OnlineSubtitleLookup.shared

    private var best: OpenSubtitlesClient.Result? { language.flatMap { online.offer(for: item.url, language: $0) } }

    var body: some View {
        if let language, let best {
            let color = OnlineSubtitleLookup.Match(best).color
            FoundSubtitlesBubble(item: item, language: language, seeAll: seeAll, inCard: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.4), lineWidth: 1))
        }
    }
}
