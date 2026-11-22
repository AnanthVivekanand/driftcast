import SwiftUI

/// The details panel beside the playlist: poster, plot, people and ratings for the selected
/// (or playing) video, then what is in the file and how it would be sent to the current device.
struct DetailsView: View {
    /// The video a Details window is about (`DetailsWindow`). The panel beside the playlist
    /// has none and follows the selection.
    var pinned: MediaItem? = nil
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: Library
    @AppStorage(Prefs.onlineDetails) private var onlineDetails = true
    @AppStorage(Prefs.showDetails) private var showDetails = true
    @AppStorage(Prefs.hideSubtitleNotices) private var hideNotices = false
    /// Where the panel is scrolled, for the floating arrow.
    @State private var scroll = ScrollPosition()
    /// Until when the panel keeps to its foot after "Show" on the captions line (see
    /// `scrollToCaptions`).
    @State private var captionsWantedUntil = Date.distantPast
    /// The language captions should be in (Settings > Subtitles); the crossed-out mark reports its absence.
    @AppStorage(Prefs.subtitleLanguage) private var captionLanguage = ""
    /// The OpenSubtitles sheet, opened from the captions line or the section.
    @State private var searching = false
    @State private var details: MovieDetails?
    @State private var poster: NSImage?
    /// True when `poster` is a picture taken from the video file itself, no poster having
    /// been found online.
    @State private var posterIsCapture = false
    @State private var still: NSImage?
    /// True when an episode's picture was asked for and didn't come.
    @State private var stillLoadFailed = false
    @State private var info: MediaInfo?
    @State private var infoError: String?
    @State private var looking = false
    @State private var parsed: MediaTitle?
    @State private var correcting = false
    @State private var correctionTitle = ""
    @State private var correctionYear = ""
    /// The captions the file and its folder hold, found once when the file has been read (and
    /// again when a subtitle file is attached). Worked out on every redraw, the folder was
    /// listed from the disk each time the panel drew.
    @State private var fileChoices: [SubtitleChoice] = []

    private var item: MediaItem? { pinned ?? player.infoItem ?? player.nowPlaying }

    /// Whether the panel still shows `item`. What a lookup brings back after another video was
    /// picked belongs to the old one, and isn't written over the new one's details.
    private func isShowing(_ item: MediaItem) -> Bool { !Task.isCancelled && self.item?.url == item.url }

    /// The library's copy of the panel's video, which carries subtitle files attached later.
    private func current(_ item: MediaItem) -> MediaItem {
        library.playlists.lazy.flatMap(\.items).first { $0.url == item.url } ?? item
    }

    /// The captions the video has: the player's list while it plays (files added during
    /// playback show up), else what the file and its neighbors hold.
    private var captionChoices: [SubtitleChoice] {
        guard let item else { return [] }
        if player.nowPlaying?.url == item.url { return player.subtitleChoices }
        return fileChoices
    }
    private var captionsProbing: Bool { info == nil && infoError == nil && player.nowPlaying?.url != item?.url }
    /// Nothing at all in the Settings language (a forced track in it counts as something).
    private var captionsMissing: Bool {
        !captionsProbing && !captionLanguage.isEmpty && !SubtitleChoice.hasAny(captionChoices, in: captionLanguage)
    }

    var body: some View {
        VStack(spacing: 0) {
            if pinned == nil { panelHeader }
            content
        }
    }

    /// The panel's header, with the control that folds the panel away (the toolbar button and
    /// View > Show Details do the same). A Details window has its title bar instead.
    private var panelHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").font(.headline)
                Spacer()
                Button {
                    showDetails = false
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide Details (⌥⌘I)")
                .accessibilityLabel("Hide Details")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
        }
    }

    @ViewBuilder private var content: some View {
        if let item {
            ScrollViewReader { proxy in
                ScrollView {
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 14) {
                                artwork
                                heading(item)
                                if !hideNotices { captionsLine(proxy) }
                                captureBelow(item)
                                if let details {
                                    facts(details)
                                    // (Not when it has nothing to say, or it leaves a gap.)
                                    if details.isEpisode, details.episodeSynopsis?.isEmpty == false || details.synopsis != nil {
                                        episodeBlock(details)
                                    }
                                    if let synopsis = details.synopsis, !synopsis.isEmpty {
                                        Text(synopsis)
                                            .font(.callout)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                    attribution(details)
                                } else if looking {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Looking up details…").font(.callout).foregroundStyle(.secondary)
                                    }
                                } else if !onlineDetails {
                                    // Nothing said: the line pointing to Settings was taken out at
                                    // the user's word, 2026-11-20.
                                    EmptyView()
                                } else {
                                    Text("No details were found for this title.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                correctionButton
                                Divider()
                                FileInfoSection(item: item, info: info, error: infoError, choices: captionChoices)
                                actions(item)
                                if !hideNotices {
                                    OnlineSubtitlesCard(item: current(item),
                                                        language: captionsMissing ? captionLanguage : nil,
                                                        seeAll: { searching = true })
                                    SubtitleSection(item: current(item), choices: captionChoices,
                                                    audio: info.flatMap { PlaybackController.preferredAudio($0) },
                                                    probing: captionsProbing,
                                                    missingLanguage: captionsMissing ? captionLanguage : nil,
                                                    searching: $searching)
                                        .id("captions")
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("top")
                            // Room for the floating arrow under the last line, so at the foot
                            // it doesn't sit on the captions section.
                            Color.clear.frame(height: scroll.overflows ? 34 : 1).id("bottom")
                        }
                        .background(ScrollObserver { scroll = $0 })
                }
                .overlay(alignment: .bottom) { scrollArrow(proxy) }
                // The foot moved after "Show" was pressed: go with it.
                .onChange(of: scroll.height) { _ in
                    if Date() < captionsWantedUntil { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .sheet(isPresented: $searching) { SubtitleSearchView(item: current(item)) }
            .task(id: item.url) { await load(item) }
            .onChange(of: onlineDetails) { on in if on { Task { await load(item) } } }
            // A subtitle file attached to the video (downloaded, or chosen from the disk).
            .onChange(of: current(item).extraSubtitles) { _ in
                if let info { fileChoices = SubtitleChoice.available(for: current(item), info: info) }
            }
        } else {
            EmptyStateView(title: "No Video Selected", systemImage: "info.circle",
                           message: "Select a video to see its poster, plot, ratings and what's in the file.")
        }
    }

    // MARK: Pieces

    /// A floating arrow at the foot of the panel when the details run past the window: one
    /// click scrolls smoothly to the end, and from there back to the top. The window itself
    /// never has to grow.
    @ViewBuilder private func scrollArrow(_ proxy: ScrollViewProxy) -> some View {
        if scroll.overflows {
            let atBottom = scroll.atEnd
            Button {
                withAnimation(.easeInOut(duration: 0.8)) {
                    if atBottom { proxy.scrollTo("top", anchor: .top) } else { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            } label: {
                Image(systemName: atBottom ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
            .help(atBottom ? "Back to the top" : "Scroll down through the details")
            .accessibilityLabel(atBottom ? "Scroll to top" : "Scroll to bottom")
        }
    }

    /// One line under the title about closed captions, in the section's tint: which languages
    /// the video has, or just "No English captions" with the crossed-out mark when none is in
    /// the Settings language. "Show" (or the line itself) scrolls to the captions section.
    private func captionsLine(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            if captionsProbing {
                ProgressView().controlSize(.mini).frame(width: 20, height: 20)
            } else {
                CaptionsIcon(missing: captionsMissing, filled: !captionChoices.isEmpty)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(captionsText)
                    .font(.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if captionsMissing, let item {
                    // Under "No closed captions", on a line of its own (the user's layout,
                    // 2026-11-21), when OpenSubtitles has some. Its bubble opens by itself here
                    // only for a video that isn't playing; the video window has it then.
                    // (While casting, that window shows the casting controls, so it is here again.)
                    FoundSubtitlesBadge(item: current(item), language: captionLanguage,
                                        announces: player.nowPlaying?.url != item.url || player.remoteDeviceName != nil,
                                        seeAll: { searching = true })
                }
            }
            .layoutPriority(1)   // the text wraps; the button keeps its own width
            Spacer(minLength: 8)
            Button("Show") { scrollToCaptions(proxy) }
                .fixedSize()
        }
        .controlSize(.small)
        .padding(10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { scrollToCaptions(proxy) }
        .help("Closed captions for this video; click to jump to the captions section")
    }

    private var captionsText: String {
        if captionsProbing { return "Checking closed captions…" }
        let summary = SubtitleChoice.languageSummary(captionChoices)
        if captionChoices.isEmpty { return "No closed captions" }
        // Just the fact; the section below lists what the video does have.
        if captionsMissing { return "No \(Lang.name(captionLanguage) ?? captionLanguage) captions" }
        return "Closed Captions: \(summary)"
    }

    /// To the foot of the panel, where the captions section is, and kept there for a few
    /// seconds while the panel is still growing. Pressed soon after a video was picked, the
    /// scroll was aimed at the foot as it was then; the details, the poster and an episode's
    /// screenshot arrived after it and pushed the captions out of sight again (the user's
    /// report, 2026-11-21: "no longer scrolls to the bottom"; seen stopping at 85%).
    private func scrollToCaptions(_ proxy: ScrollViewProxy) {
        captionsWantedUntil = Date().addingTimeInterval(4)
        withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    @ViewBuilder private var artwork: some View {
        // An episode's own picture first, always (the user's call, 2026-11-20); it was further
        // down, with the episode's air date and synopsis. It is the one big picture: the
        // show's poster, which stood under it at full width, is small under the episode's
        // name (`posterBesideTitle`; two days later, the pair "looked a little weird").
        if let still {
            Image(nsImage: still)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4, y: 2)
        } else if awaitingStill {
            // Its place kept while it loads, so the panel doesn't jump when it arrives.
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).aspectRatio(16.0 / 9, contentMode: .fit)
        }
        if let poster {
            // (A film's picture taken from the file is further down: `captureBelow`. With an
            // episode's own picture, a poster is beside the title and a capture isn't needed.)
            if !capturePlacedBelow, !episodeHasPicture { picture(poster) }
        } else if episodeHasPicture {
            EmptyView()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: "film").font(.system(size: 36)).foregroundStyle(.secondary)
            }
            .frame(height: 150)
        }
    }

    private func picture(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 300)   // a portrait poster must leave the title and plot in view
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4, y: 2)
    }

    /// An episode's own picture is on its way.
    private var awaitingStill: Bool { still == nil && details?.episodeImageURL != nil && !stillLoadFailed }

    /// The top of the panel is, or is about to be, an episode's own picture.
    private var episodeHasPicture: Bool { still != nil || awaitingStill }

    /// The show's poster goes small, under the episode's name, when the episode's picture has the top.
    private var posterBesideTitle: Bool { episodeHasPicture && poster != nil && !posterIsCapture }

    /// Whether the video is a film and not an episode of a show: by what was found online,
    /// else by its name.
    private var isFilm: Bool {
        !(details?.isEpisode ?? parsed?.isEpisode ?? item?.parsedTitle.isEpisode ?? false)
    }

    /// A film with no poster shows a picture taken from the file. That one doesn't go at the
    /// top of the panel, where a poster would, but under the captions line (the user's call,
    /// 2026-11-22). A real poster, and anything for an episode, stays at the top.
    private var capturePlacedBelow: Bool { posterIsCapture && isFilm }

    @ViewBuilder private func captureBelow(_ item: MediaItem) -> some View {
        if capturePlacedBelow, let poster { picture(poster) }
    }

    /// The panel's heading: the film or show as it was found online. With nothing found, the
    /// name the person gave the video in the list, else the one its file gives.
    private func headingTitle(_ item: MediaItem) -> String {
        if let details {
            if details.isEpisode, let show = details.showTitle { return show }
            return details.title
        }
        if let given = item.givenName { return given }
        return parsed?.shownTitle ?? item.parsedTitle.shownTitle
    }

    private func heading(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headingTitle(item))
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let details, let label = details.episodeLabel {
                // The season and episode on one line and the episode's name under it. Joined
                // with a colon they broke in the middle of the name in a panel this narrow.
                Text(label)
                    .font(.headline)
                if let name = details.episodeTitle, !name.isEmpty {
                    Text(name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            let year = details?.year.map(String.init) ?? parsed?.year.map(String.init)
            let line = [
                details?.runtimeText ?? info.flatMap { $0.duration > 0 ? formatTime($0.duration) : nil },
                details?.certificate,
                details?.network,
            ].compactMap { $0 }
            // The year (in black), length and genres, with the ratings at the right edge beside them.
            let genres = details.flatMap { $0.genres.isEmpty ? nil : $0.genres.joined(separator: ", ") }
            // An episode's air date is the line under the genres (it was under the cast).
            let aired = details.flatMap { $0.isEpisode ? $0.airDate : nil }
            let hasFacts = year != nil || !line.isEmpty || genres != nil || aired != nil || details?.ratings.isEmpty == false
            // With an episode's picture at the top, the show's poster is here, small, under
            // the episode's name and beside the year and genres (the user's placing).
            HStack(alignment: .top, spacing: 10) {
                if posterBesideTitle, let poster {
                    Image(nsImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(radius: 2, y: 1)
                        .padding(.top, 4)
                }
                if hasFacts {
                    TitleFactsRow(year: year, facts: line.isEmpty ? nil : line.joined(separator: " · "), genres: genres,
                                  ratings: details?.ratings ?? [], aired: aired)
                        // Beside the poster, an empty line above the year (the user's
                        // request, 2026-11-22): flush with the poster's top it sat too high.
                        .padding(.top, posterBesideTitle ? 20 : 0)
                }
            }
            // An empty line between the episode's name and the poster's row (the user's
            // request, 2026-11-22).
            .padding(.top, posterBesideTitle ? 14 : 0)
        }
    }

    private func facts(_ details: MovieDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !details.directors.isEmpty { fact(details.directors.count == 1 ? "Director" : "Directors", details.directors.joined(separator: ", ")) }
            if !details.writers.isEmpty { fact(details.writers.count == 1 ? "Writer" : "Writers", details.writers.joined(separator: ", ")) }
            if !details.cast.isEmpty { fact("Starring", details.cast.joined(separator: ", ")) }
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(.callout.weight(.medium)).frame(width: 64, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func episodeBlock(_ details: MovieDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let synopsis = details.episodeSynopsis, !synopsis.isEmpty {
                Text(synopsis).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if details.synopsis != nil {
                Text("About the show").font(.callout.weight(.medium)).padding(.top, 4)
            }
        }
    }

    private func attribution(_ details: MovieDetails) -> some View {
        HStack(spacing: 4) {
            Text(details.source == "Wikipedia" ? "Details from Wikipedia and Wikidata" : "Details from \(details.source)")
            if let link = details.link {
                Link(details.link?.host?.contains("imdb") == true ? "IMDb page" : "Open page", destination: link)
            }
            if let item {
                Button("Refresh") { Task { await load(item, refresh: true) } }
                    .buttonStyle(.link)
                    .disabled(looking)
                    .help("Asks for this title's details again, in case they have changed or came back incomplete")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var correctionButton: some View {
        if onlineDetails, let item {
            Button(details == nil ? "Search by Title…" : "Not this title? Search again…") {
                correctionTitle = details?.title ?? parsed?.title ?? item.parsedTitle.title
                correctionYear = (details?.year ?? parsed?.year).map(String.init) ?? ""
                correcting = true
            }
            .controlSize(.small)
            .popover(isPresented: $correcting, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Search for the film or show by name").font(.headline)
                    TextField("Title", text: $correctionTitle).textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await correct(item) } }
                    TextField("Year (optional)", text: $correctionYear).textFieldStyle(.roundedBorder).frame(width: 140)
                    if parsed?.isEpisode == true, let label = parsed?.episodeLabel {
                        Text("\(label) stays as read from the file name.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Use File Name") {
                            Task {
                                await MetadataLookup.shared.setTitle(nil, for: item.url)
                                library.objectWillChange.send()   // the list shows the name too
                                correcting = false
                                await load(item)
                            }
                        }
                        Spacer()
                        Button("Cancel") { correcting = false }
                        Button("Search") { Task { await correct(item) } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(correctionTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(16)
                .frame(width: 320)
            }
        }
    }

    /// Show in Finder only; playing is the row's and the bar's job (the user asked for no Play here).
    private func actions(_ item: MediaItem) -> some View {
        HStack {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Spacer()
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    // MARK: Loading

    /// `refresh` is the Refresh button: the services are asked again, and what was shown
    /// stays until they answer (and if they don't).
    private func load(_ item: MediaItem, refresh: Bool = false) async {
        if !refresh {
            details = nil; poster = nil; posterIsCapture = false; still = nil; stillLoadFailed = false; info = nil; infoError = nil; fileChoices = []
            captionsWantedUntil = .distantPast   // another video: its panel starts at rest
        }
        let title = await MetadataLookup.shared.title(for: item.url)
        guard isShowing(item) else { return }
        parsed = title
        looking = onlineDetails
        async let probe: Void = refresh ? () : loadInfo(item)
        if !refresh, let cached = await MetadataLookup.shared.cached(for: item.url) {
            guard isShowing(item) else { return }
            details = cached
            await loadImages(cached, item: item)
        }
        if onlineDetails, details == nil || refresh {
            let found = await MetadataLookup.shared.details(for: item.url, refresh: refresh)
            guard isShowing(item) else { return }
            if found != nil || !refresh { details = found }
            if let found { await loadImages(found, item: item) }
        }
        guard isShowing(item) else { return }
        looking = false
        if poster == nil, let data = await Thumbnailer.shared.poster(for: item.url, duration: info?.duration ?? 0) {
            if isShowing(item), poster == nil { poster = NSImage(data: data); posterIsCapture = poster != nil }
        }
        await probe
    }

    private func loadInfo(_ item: MediaItem) async {
        do {
            let probed = try await MediaProbe.shared.probe(item.url)
            guard isShowing(item) else { return }
            info = probed
            fileChoices = SubtitleChoice.available(for: current(item), info: probed)
        } catch {
            if isShowing(item) { infoError = error.localizedDescription }
        }
    }

    private func loadImages(_ details: MovieDetails, item: MediaItem) async {
        if let url = details.posterURL, let data = await MetadataLookup.shared.artwork(url), let image = NSImage(data: data) {
            if isShowing(item) { poster = image; posterIsCapture = false }
        }
        if let url = details.episodeImageURL {
            if let data = await MetadataLookup.shared.artwork(url), let image = NSImage(data: data) {
                if isShowing(item) { still = image }
            } else if isShowing(item) {
                stillLoadFailed = true   // the poster takes the top again
            }
        }
    }

    private func correct(_ item: MediaItem) async {
        let title = correctionTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        var corrected = MediaTitle(title: title, year: Int(correctionYear.trimmingCharacters(in: .whitespaces)))
        corrected.season = parsed?.season
        corrected.episode = parsed?.episode
        await MetadataLookup.shared.setTitle(corrected, for: item.url)
        library.objectWillChange.send()   // the list shows the name too
        correcting = false
        details = nil; poster = nil; posterIsCapture = false; still = nil; stillLoadFailed = false
        parsed = corrected
        looking = true
        var found = await MetadataLookup.shared.details(for: corrected, refresh: true)
        if found == nil, corrected.year != nil {
            // The year box keeps the file name's year, which is often the part that was wrong.
            corrected.year = nil
            found = await MetadataLookup.shared.details(for: corrected, refresh: true)
            if found != nil {
                await MetadataLookup.shared.setTitle(corrected, for: item.url)
                if isShowing(item) { parsed = corrected }
            }
        }
        // Another video picked while the search ran: the title is corrected, and the panel
        // is left to the video it now shows.
        guard isShowing(item) else { return }
        details = found
        if let found { await loadImages(found, item: item) }
        looking = false
    }
}

/// Streams in a file and how each would be sent to the current output.
struct FileInfoSection: View {
    let item: MediaItem
    let info: MediaInfo?
    let error: String?
    /// The video's captions, as the panel found them.
    var choices: [SubtitleChoice] = []
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: Library

    /// "1.42 GB", from the disk.
    private var size: String? {
        (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    /// When the file arrived in its folder: "Nov 18, 2026 at 9:41 PM".
    private var added: String? {
        Library.dateAdded(item.url)?.formatted(date: .abbreviated, time: .shortened)
    }

    /// How far it has been watched, as the list's bar shows it.
    private var watchedText: String {
        if library.watched.contains(item.url.path) { return "Finished" }
        guard let p = library.progress[item.url.path] else { return "Not yet" }
        return "\(formatTime(p.position)) of \(formatTime(p.duration)) (\(Int((p.fraction * 100).rounded()))%)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File").font(.headline)
            Text(item.url.lastPathComponent)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(2)
            Text(item.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            if let info {
                row("Duration", formatTime(info.duration))
                row("Watched", watchedText)
                if let size { row("Size", size) }
                if let added { row("Added", added) }
                row("Container", MediaInfo.containerName(formatName: info.formatName, file: item.url))
                if let br = info.bitRate { row("Bit rate", String(format: "%.1f Mbps", Double(br) / 1_000_000)) }
                if let v = info.video { row("Video", videoLine(v)) }
                row(info.audio.count == 1 ? "Audio" : "Audio tracks", info.audio.isEmpty ? "None" : info.audio.map(\.label).joined(separator: "\n"))
                // Subtitles have their own section at the foot of the panel.
                // The heading naming the device ("On This Mac") was taken out at the user's
                // word, 2026-11-21; its line is kept blank, to set the notes apart from the rows.
                Text(" ").font(.callout.weight(.medium)).padding(.top, 4).accessibilityHidden(true)
                ForEach(planNotes(info), id: \.self) { note in
                    Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } else if let error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            } else if !item.exists {
                Text("The file couldn't be found. It may have been moved or deleted.").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(.callout.weight(.medium)).frame(width: 90, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    /// "HEVC Main 10, 3840 x 2160, 23.976 fps, HDR10".
    private func videoLine(_ v: MediaInfo.Video) -> String {
        var video = "\(Codecs.videoName(v.codec))\(v.profile.map { " \($0)" } ?? ""), \(v.width) x \(v.height)"
        if v.fps > 0 { video += String(format: ", %.5g fps", v.fps) }
        if let hdr = v.hdrName { video += ", \(hdr)" } else if v.bitDepth > 8 { video += ", \(v.bitDepth)-bit" }
        return video
    }

    private func planNotes(_ info: MediaInfo) -> [String] {
        let settings = EncoderSettings.current()
        let profile: DeviceProfile
        switch player.output {
        case .local: profile = .apple()
        case .cast(let d): profile = .chromecast(model: d.model, capabilities: d.capabilities, settings: settings)
        }
        let audio = PlaybackController.preferredAudio(info)
        let sub = PlaybackController.preferredSubtitle(choices, audio: audio)
        return StreamPlanner.plan(info: info, file: item.url, profile: profile, settings: settings,
                                  audioIndex: audio?.index, subtitle: sub,
                                  subtitleIsText: sub.map { $0.isPicture && Prefs.bool(Prefs.ocrSubtitles) && PictureSubtitleOCR.supports($0, media: item.url) } ?? false,
                                  options: player.options).notes
    }
}

/// The foot of the panel, in its own tint so it stands out: which closed captions the video
/// has (with the crossed-out mark when none is in the Settings language), a menu to pick one
/// and a button to turn it on (or start the video with it), then "Find Subtitles Online…" —
/// one step: search, pick, it downloads and comes on — beside "Add Subtitle File…".
struct SubtitleSection: View {
    /// The library's copy of the video, which carries subtitle files attached later.
    let item: MediaItem
    let choices: [SubtitleChoice]
    /// The sound track the video would start with, which decides whether captions come on by
    /// themselves ("only when the sound isn't in my language").
    var audio: MediaInfo.Audio? = nil
    /// True while the file is still being read; a file that can't be read shows "None" rather than a spinner.
    let probing: Bool
    /// The Settings language when the video has no full captions in it.
    let missingLanguage: String?
    @Binding var searching: Bool
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: Library
    /// What OpenSubtitles has for a video with no captions in the subtitle language, looked up
    /// by itself (the user's request, 2026-11-21).
    @ObservedObject private var online = OnlineSubtitleLookup.shared
    /// The menu's choice once the user has changed it; until then it mirrors what is on.
    @State private var pick: SubtitleChoice?
    @State private var userPicked = false

    private var current: MediaItem { item }
    private var isPlaying: Bool { player.nowPlaying?.url == item.url }
    /// What is on now, or for a video that isn't playing, what would come on when it is.
    private var active: SubtitleChoice? {
        if isPlaying { return player.subtitle }
        // By the sound track it would start with. With none given, every video's sound
        // counted as foreign, and the panel said captions would come on for films in the
        // Settings language, where they don't.
        return PlaybackController.preferredSubtitle(choices, audio: audio)
    }
    private var shown: SubtitleChoice? { userPicked ? pick : active }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let checking = probing && !isPlaying
            HStack(spacing: 8) {
                if checking {
                    ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                } else {
                    // Crossed out only when the video has no captions at all.
                    CaptionsIcon(missing: choices.isEmpty, filled: true)
                }
                Text("Closed Captions").font(.headline)
            }
            if !checking {
                if choices.isEmpty {
                    Text("Find them online or add a subtitle file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(SubtitleChoice.languageSummary(choices))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let missingLanguage {
                        HStack(spacing: 6) {
                            NoCaptionsIcon(size: 14)
                            Text("None in \(Lang.name(missingLanguage) ?? missingLanguage).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // A choice only when there is something to choose.
                    HStack(spacing: 8) {
                        trackMenu
                        Button(buttonTitle) { apply() }
                            .help(isPlaying
                                  ? (player.subtitle == nil ? "Turns the chosen captions on" : "Turns the captions off")
                                  : "Plays this video with the chosen captions")
                            .fixedSize()
                        // For a subtitle file added to the video (from OpenSubtitles or the
                        // disk) that isn't in sync: off alone left it attached for good.
                        if case .external(let file)? = shown, player.removableSubtitles(for: current).contains(file) {
                            Button("Remove") {
                                player.removeSubtitleFile(file, from: current)
                                userPicked = false
                            }
                            .fixedSize()
                            .help("Takes this subtitle file off the video, for one that isn't in sync. The file stays on your Mac.")
                        }
                    }
                    .controlSize(.small)
                }
            }
            if !checking { onlineFinding }
            // Ways to get captions, only when the video has none (the track menu offers them otherwise).
            if !checking, choices.isEmpty {
                // Each button at its full width: offered the space left over, the first one was
                // cut to "Find Subtitles Onli…" though the row had room (the user's report,
                // 2026-11-21).
                HStack(spacing: 8) {
                    Button("Find Subtitles Online…") { findOnline() }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .help("Searches OpenSubtitles for this video; pick a result and it downloads and comes on")
                    Button("Add Subtitle File…") { player.chooseSubtitleFile(for: current) }
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
        .task(id: lookupKey) {
            guard let language = missingLanguage, !probing else { return }
            // While it plays, its list is only known once the player has read the file.
            if isPlaying, player.info == nil { return }
            // A moment first, so arrowing down the list doesn't search for every row passed.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await online.look(for: current, language: language)
        }
        .onChange(of: item.url) { _ in userPicked = false }
        .onChange(of: choices) { now in
            // A track that is no longer there (the video changed) can't stay picked.
            if userPicked, let pick, !now.contains(pick) { userPicked = false }
        }
    }

    private var lookupKey: String { "\(item.url.path)|\(missingLanguage ?? "")|\(probing)|\(player.info == nil)" }

    private var onlineState: OnlineSubtitleLookup.State? {
        guard let language = missingLanguage, !probing else { return nil }
        return online.state(for: item.url, language: language)
    }

    /// The line about the lookup while it runs, or when it found nothing.
    @ViewBuilder private var onlineFinding: some View {
        if let state = onlineState {
            switch state {
            case .looking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking on OpenSubtitles…").font(.callout).foregroundStyle(.secondary)
                }
            case .nothing:
                Text("None on OpenSubtitles either.").font(.caption).foregroundStyle(.secondary)
            case .found, .downloading, .failed, .used:
                // Found: the card above this section offers it.
                EmptyView()
            }
        }
    }

    private var trackMenu: some View {
        Menu {
            Button { choose(nil) } label: {
                if shown == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            if !choices.isEmpty { Divider() }
            ForEach(choices) { choice in
                Button { choose(choice) } label: {
                    if choice == shown { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                }
            }
            Divider()
            if missingLanguage != nil { FoundSubtitleMenuItem(item: current) }
            Button("Find Subtitles Online…") { findOnline() }
            Button("Add Subtitle File…") { player.chooseSubtitleFile(for: current) }
            RemoveSubtitleMenu(item: current)
        } label: {
            Text(shown?.label ?? "Off").lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Closed captions for this video")
    }

    private var buttonTitle: String {
        guard isPlaying else { return "Play" }
        return player.subtitle == nil ? "Turn On" : "Turn Off"
    }

    /// While the video plays a choice applies at once; otherwise it waits for Play.
    private func choose(_ choice: SubtitleChoice?) {
        pick = choice
        userPicked = true
        if isPlaying {
            player.selectSubtitle(choice)
            userPicked = false
        }
    }

    /// The track "Turn On" picks when nothing is on: the last choice, else a full track in the
    /// Settings language, else the first one.
    private var trackToTurnOn: SubtitleChoice? {
        if let pick, choices.contains(pick) { return pick }
        let language = Prefs.string(Prefs.subtitleLanguage)
        return choices.first { Lang.matches($0.language, language) && !$0.isForced } ?? choices.first
    }

    private func findOnline() { searching = true }

    /// Toggles the playing video's captions, or starts this video with the chosen ones.
    private func apply() {
        if isPlaying {
            player.selectSubtitle(player.subtitle == nil ? trackToTurnOn : nil)
        } else {
            let queue = library.playlists.first { $0.items.contains { $0.url == item.url } }?.items ?? [current]
            let start: PlaybackController.SubtitleStart = userPicked ? (pick.map { .use($0) } ?? .off) : .automatic
            player.play(current, queue: queue, subtitle: start)
        }
        userPicked = false
    }
}
