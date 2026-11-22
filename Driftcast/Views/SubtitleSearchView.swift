import SwiftUI

struct SubtitleSearchView: View {
    let item: MediaItem
    @EnvironmentObject private var player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.subtitleLanguage) private var language = "en"
    @State private var query = ""
    /// "Season 1, Episode 2" for an episode of a show, shown beside the title: the search is
    /// narrowed to it, and the title box alone didn't say so (the user's request, 2026-11-21).
    /// Nil for a film.
    @State private var episodeLabel: String?
    @State private var results: [OpenSubtitlesClient.Result] = []
    @State private var selection: OpenSubtitlesClient.Result.ID?
    @State private var busy = false
    @State private var message: String?
    /// The yellow line above the results when none was made for this video (`OpenSubtitlesClient.notice`).
    @State private var notice: String?
    /// The search or download under way, so Cancel can stop it.
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Find Subtitles Online").font(.title3.weight(.semibold))
                Text("Pick one and Use: it downloads and comes on.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Title", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                if let episodeLabel {
                    Text(episodeLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help("The search is narrowed to this episode, read from the file's name.")
                }
                Picker("Language", selection: $language) {
                    ForEach(Lang.common, id: \.self) { code in
                        Text(Lang.name(code) ?? code).tag(code)
                    }
                    // The Mac's own language may not be in the list (Norwegian is "nb", or Czech);
                    // without its row the pop-up showed nothing at all.
                    if !Lang.common.contains(language), !language.isEmpty {
                        Text(Lang.name(language) ?? language).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button("Search") { search() }.disabled(busy)
            }
            if let notice {
                // Above the list, where it is read before a result is picked; under it, it
                // was read after, if at all (the user's request, 2026-11-21).
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.yellow.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1))
            }
            resultsTable
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Cancel") {
                    work?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                // Only once there is something to use; a button that can't do anything yet is just confusing.
                if !results.isEmpty {
                    Button("Use") { download() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection == nil || busy)
                        .help("Downloads the selected subtitle and turns it on")
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 480)
        .task {
            // "Movie.Name.2019.1080p.BluRay.x264-GRP" -> "Movie Name 2019", or the title the
            // person corrected in the details panel.
            let title = await MetadataLookup.shared.title(for: item.url)
            query = title.searchQuery
            episodeLabel = title.isEpisode ? title.episodeLabel : nil
            search()
        }
        // The sheet is for the video it was opened for. When another one takes its place (the next
        // episode starts, or the details panel follows playback), its title and results no longer
        // fit, and Use would save this video's subtitle under the other's name and turn it on there.
        .onChange(of: item.url) { _ in dismiss() }
    }

    private var resultsTable: some View {
        Table(results, selection: $selection) {
            TableColumn("Release") { r in
                HStack(spacing: 6) {
                    if r.isMatch { MatchTag(exact: r.hashMatch) }
                    if r.isClose { CloseTag() }
                    if r.foreignPartsOnly { ForcedTag() }
                    Text(r.name)
                        .fontWeight(r.isMatch ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(r.name)
                }
            }
            TableColumn("Language") { r in Text(Lang.name(r.language) ?? r.language) }
                .width(90)
            TableColumn("Downloads") { r in Text("\(r.downloads)").monospacedDigit() }
                .width(80)
        }
        .contextMenu(forSelectionType: OpenSubtitlesClient.Result.ID.self) { _ in } primaryAction: { _ in download() }
        .frame(minHeight: 260)
    }

    /// What the last download said about the day's allowance, for the line under the results.
    private var quotaNote: String? {
        guard let quota = OpenSubtitlesClient.quota else { return nil }
        return quota.remaining == 1 ? "1 download left today." : "\(quota.remaining) downloads left today."
    }

    private func search() {
        // Return pressed twice would run two searches, and the slower one would win.
        guard !busy else { return }
        let q = query, lang = language
        busy = true
        message = nil
        notice = nil
        work = Task {
            defer { busy = false }
            do {
                let client = try OpenSubtitlesClient.fromSettings()
                let title = await MetadataLookup.shared.title(for: item.url)
                let hash = await Task.detached { OpenSubtitlesClient.movieHash(for: item.url) }.value
                var found = try await client.search(query: q, languages: lang, movieHash: hash, season: title.season, episode: title.episode,
                                                    videoName: item.baseName)
                if found.isEmpty, hash != nil {
                    found = try await client.search(query: q, languages: lang, movieHash: nil, season: title.season, episode: title.episode,
                                                    videoName: item.baseName)
                }
                results = found
                notice = OpenSubtitlesClient.notice(of: found)
                selection = found.first?.id
                message = found.isEmpty ? "No subtitles found." : OpenSubtitlesClient.summary(of: found)
                if let quotaNote, let shown = message { message = "\(shown) \(quotaNote)" }
            } catch let failure as OpenSubtitlesClient.Failure where failure.isKeyRefused {
                // Nothing the person can do about it here, so no talk of keys: say it failed, and log why.
                guard !Task.isCancelled else { return }
                ErrorLog.record("Subtitle search", item.url.lastPathComponent, error: failure)
                results = []
                message = "OpenSubtitles isn't answering Driftcast right now. Try again later, or check for an update."
            } catch {
                guard !Task.isCancelled else { return }
                ErrorLog.record("Subtitle search", item.url.lastPathComponent, error: error)
                message = error.localizedDescription
            }
        }
    }

    private func download() {
        // A second double-click while the first downloads would spend another of the day's downloads.
        guard !busy, let id = selection, let result = results.first(where: { $0.id == id }) else { return }
        busy = true
        message = "Downloading…"
        work = Task {
            defer { busy = false }
            do {
                let client = try OpenSubtitlesClient.fromSettings()
                let file = try await client.download(result, for: item.url)
                // Canceled while it downloaded: the file is kept (choosing it again won't download it
                // twice) but it isn't attached or turned on, and the video doesn't reload.
                guard !Task.isCancelled else { return }
                player.addSubtitleFile(file, to: item)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                ErrorLog.record("Subtitle download", item.url.lastPathComponent, error: error)
                message = error.localizedDescription
            }
        }
    }
}

/// The gray "FORCED" beside a subtitle that covers only the parts in another language (signs and
/// foreign dialogue), not the whole film.
private struct ForcedTag: View {
    var body: some View {
        Text("FORCED")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
            .fixedSize()
            .help("Only the parts in another language, such as signs and foreign dialogue, not the whole film.")
    }
}

/// The blue "CLOSE" beside a subtitle that isn't for this release but was taken from the same
/// kind of source (both Blu-ray, both DVD), which is what mostly decides the timing.
private struct CloseTag: View {
    var body: some View {
        Text("CLOSE")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.blue.opacity(0.18)))
            .fixedSize()
            .help("Not made for this exact video, but its name is close to it (the same kind of source, or much the same words), so it is likely in sync.")
    }
}

/// The green "MATCH" beside a subtitle made for this video: from this exact file ("EXACT"), or
/// for the same release (same group and source), so it should be in sync.
private struct MatchTag: View {
    let exact: Bool

    var body: some View {
        Text(exact ? "EXACT" : "MATCH")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.green)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.green.opacity(0.18)))
            .fixedSize()
            .help(exact ? "Made from this exact file, so it will be in sync."
                        : "Made for the same release as this video (same group and source), so it should be in sync.")
    }
}
