import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.settingsTab) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            VideoSettings().tabItem { Label("Video", systemImage: "film") }.tag("video")
            AudioSettings().tabItem { Label("Audio", systemImage: "speaker.wave.3") }.tag("audio")
            SubtitleSettings().tabItem { Label("Subtitles", systemImage: "captions.bubble") }.tag("subtitles")
        }
        .frame(width: 520)
        // The License tab is gone; a remembered selection of it would show an empty pane.
        .onAppear { if tab == "licence" { tab = "general" } }
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.resumePlayback) private var resume = true
    @AppStorage(Prefs.autoUpdateCheck) private var autoUpdate = true
    @AppStorage(Prefs.onlineDetails) private var onlineDetails = true
    @AppStorage(Prefs.omdbKey) private var omdbKey = ""
    /// Changes when OMDb last refused the key or answered again, so the line under the key
    /// is drawn again; what it says is read from `OMDbClient.problem`.
    @AppStorage(OMDbClient.problemKey) private var omdbProblem = ""
    @AppStorage(Prefs.titleCard) private var titleCard = true
    @AppStorage(Prefs.watchedList) private var watchedList = true
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section {
                Toggle("Resume videos where you left off", isOn: $resume)
            }
            Section {
                Toggle("Look up posters and details online", isOn: $onlineDetails)
                TextField("OMDb API key (optional)", text: $omdbKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!onlineDetails)
                // What OMDb last said was wrong with this key, where it used to fail unseen
                // and the ratings just stayed missing.
                if !omdbProblem.isEmpty, let problem = OMDbClient.problem {
                    Label {
                        Text(OMDbClient.problemDate.map { "\(problem) (\($0.formatted(date: .abbreviated, time: .shortened)))" } ?? problem)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    .font(.callout)
                }
                Link("Get a free OMDb key", destination: OMDbClient.keyPage)
                // The paragraph that stood under this (where the details come from, what an
                // OMDb key adds, where the card is placed) was taken out at the user's word,
                // 2026-11-20; the description and the About window still say it.
                Toggle("Show poster when a movie starts", isOn: $titleCard)
            } header: {
                Text("Film and show details")
            }
            // Above Updates since 1.1.3 (the user's call, 2026-11-20).
            Section {
                Toggle("Keep a list of the videos you watch", isOn: $watchedList)
                Button("Export…") { WatchedList.exportCSV() }
            } footer: {
                Text("Each video you play is added to a list kept inside Driftcast's own data, not in your folders. Export, here or in the File menu, saves it as a spreadsheet wherever you choose.")
            }
            if Updater.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $autoUpdate)
                    LabeledContent {
                        Button("Check Now") { Updater.shared.checkNow() }
                            .disabled(updater.status == .checking)
                    } label: {
                        Text(Updater.lastCheckText(updater.lastCheck))
                        Text(updateWords)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The ffmpeg section (which copy is in use, Choose Folder…) and the paragraph under the
        // poster checkbox were taken out at the user's word, 2026-11-20. A folder chosen
        // before is still honored by `FFmpeg.tool`; only the way to pick one here is gone.
        // Measured off screen once these were gone: 571 points of content with Updates, so
        // the same room below it as the Video and Audio panes (about 55 points).
        .frame(height: Updater.isAvailable ? 627 : 517)
    }

    private var updateWords: String {
        switch updater.status {
        case .unknown: "Driftcast \(AppVersion.installed)"
        case .checking: "Checking for updates…"
        case .upToDate: "Driftcast \(AppVersion.installed) is the newest version"
        case .available(let release): "Version \(release.version) is available"
        case .failed: "The last check couldn't reach GitHub"
        }
    }

}

private struct VideoSettings: View {
    @AppStorage(Prefs.hardwareEncoding) private var hardware = true
    @AppStorage(Prefs.videoBitrate) private var bitrate = 12
    @AppStorage(Prefs.maxResolution) private var maxResolution = 2160
    @AppStorage(Prefs.forceTranscode) private var force = false
    @AppStorage(Prefs.castHEVC) private var castHEVC = EncoderSettings.CastHEVC.auto.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Convert on the GPU (VideoToolbox)", isOn: $hardware)
                Picker("Conversion quality", selection: $bitrate) {
                    Text("Low (6 Mbps)").tag(6)
                    Text("Medium (12 Mbps)").tag(12)
                    Text("High (20 Mbps)").tag(20)
                    Text("Very high (30 Mbps)").tag(30)
                }
                Picker("Maximum resolution", selection: $maxResolution) {
                    Text("4K").tag(2160)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                }
                Toggle("Always convert video", isOn: $force)
            } footer: {
                Text("Video the device can play is passed through untouched. Only incompatible video is converted to H.264, decoded, scaled and encoded on the GPU wherever the Mac can. 4K streams use twice the bit rate.")
            }
            Section {
                Picker("HEVC on Chromecast", selection: $castHEVC) {
                    Text("Automatic").tag(EncoderSettings.CastHEVC.auto.rawValue)
                    Text("Always").tag(EncoderSettings.CastHEVC.on.rawValue)
                    Text("Never").tag(EncoderSettings.CastHEVC.off.rawValue)
                }
            } footer: {
                Text("Automatic assumes Chromecast Ultra, Chromecast with Google TV and TVs with Chromecast built in can play HEVC and HDR.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

private struct AudioSettings: View {
    @AppStorage(Prefs.appleSurround) private var appleSurround = EncoderSettings.AppleSurround.eac3.rawValue
    @AppStorage(Prefs.castAudioCodec) private var castAudio = EncoderSettings.CastAudio.aac.rawValue
    @AppStorage(Prefs.castPassthrough) private var passthrough = false
    @AppStorage(Prefs.audioLanguage) private var language = "en"

    var body: some View {
        Form {
            Section {
                LanguagePicker(title: "Preferred audio language", selection: $language)
            }
            Section {
                Picker("Surround sound conversion", selection: $appleSurround) {
                    Text("Dolby Digital Plus 5.1").tag(EncoderSettings.AppleSurround.eac3.rawValue)
                    Text("Lossless FLAC (tvOS 14 or later)").tag(EncoderSettings.AppleSurround.flac.rawValue)
                    Text("Stereo AAC").tag(EncoderSettings.AppleSurround.stereo.rawValue)
                }
            } header: {
                Text("Apple TV and AirPlay")
            } footer: {
                Text("Dolby Digital, Dolby Digital Plus (including Atmos) and FLAC are passed through. DTS and TrueHD are converted using this setting.")
            }
            Section {
                Picker("Stereo codec", selection: $castAudio) {
                    Text("AAC").tag(EncoderSettings.CastAudio.aac.rawValue)
                    Text("Opus").tag(EncoderSettings.CastAudio.opus.rawValue)
                }
                Toggle("Pass through Dolby surround", isOn: $passthrough)
            } header: {
                Text("Chromecast")
            } footer: {
                Text("Turn on pass-through only if your Chromecast is connected to a receiver or TV that decodes Dolby Digital.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }
}

private struct SubtitleSettings: View {
    @AppStorage(Prefs.subtitleLanguage) private var language = "en"
    @AppStorage(Prefs.subtitleAuto) private var auto = SubtitleAuto.never.rawValue
    @AppStorage(Prefs.autoSearchSubtitles) private var autoSearch = false
    @AppStorage(Prefs.hideSubtitleNotices) private var hideNotices = false
    @AppStorage(Prefs.subtitleScale) private var scale = 1.0
    @AppStorage(Prefs.openSubtitlesKey) private var apiKey = ""
    @AppStorage(Prefs.ocrSubtitles) private var ocr = true
    @State private var keyHelp = false

    private var hasKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !OpenSubtitlesClient.builtInKey.isEmpty
    }

    var body: some View {
        Form {
            // First, because it decides whether the rest of the page matters: with it on, the
            // sections below are grayed out.
            Section {
                // The paragraph that stood under this (what the switch turns off) was taken
                // out at the user's word, 2026-11-20.
                Toggle("I don't care about subtitles", isOn: $hideNotices)
            }
            Section {
                LanguagePicker(title: "Closed caption language", selection: $language)
                    .dimmedWhenDisabled()
                Toggle("Always turn on closed captions", isOn: Binding(
                    get: { auto == SubtitleAuto.always.rawValue },
                    set: { auto = $0 ? SubtitleAuto.always.rawValue : SubtitleAuto.never.rawValue }))
                    .dimmedWhenDisabled()
                Toggle("Turn them on when the audio is in another language", isOn: Binding(
                    get: { auto == SubtitleAuto.foreign.rawValue },
                    set: { auto = $0 ? SubtitleAuto.foreign.rawValue : SubtitleAuto.never.rawValue }))
                    .dimmedWhenDisabled()
                    .disabled(auto == SubtitleAuto.always.rawValue)
                Toggle("Search OpenSubtitles when the video has none in this language", isOn: $autoSearch)
                    .dimmedWhenDisabled()
                    .disabled(auto == SubtitleAuto.never.rawValue || !hasKey)
            } footer: {
                Text(hasKey
                     ? "Nothing comes on by itself unless one of these is ticked. When the video has no captions in this language, OpenSubtitles can be asked for them as the video starts; that takes a few seconds and the best match is kept with the video."
                     : "Nothing comes on by itself unless one of these is ticked. Asking OpenSubtitles for missing ones needs the API key below.")
            }
            .disabled(hideNotices)
            Section {
                Toggle("Convert picture subtitles (PGS, VobSub) to text", isOn: $ocr)
                    .dimmedWhenDisabled()
                LabeledContent("Subtitle size") {
                    HStack {
                        Slider(value: $scale, in: SubtitleSize.range, step: SubtitleSize.step)
                        Text(SubtitleSize.label(scale)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .dimmedWhenDisabled()
                // The paragraph that stood under these two (what the conversion costs, where
                // the size applies) was taken out at the user's word, 2026-11-20.
            }
            .disabled(hideNotices)
            Section {
                TextField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .dimmedWhenDisabled()
                Button("How to get a free key…") { keyHelp = true }
                    .popover(isPresented: $keyHelp, arrowEdge: .bottom) { OpenSubtitlesKeyHelp() }
            } header: {
                Text("OpenSubtitles")
            } footer: {
                Text(OpenSubtitlesClient.builtInKey.isEmpty
                     ? "Searching for subtitles online needs a free key from OpenSubtitles. Subtitles that are already in the video, or in a file next to it, work without one."
                     : "Driftcast includes a key, so this can stay empty. Add your own only if you have an OpenSubtitles account with a higher download limit.")
            }
            .disabled(hideNotices)
        }
        .formStyle(.grouped)
        .frame(height: 611)   // 555 points of content, measured off screen; the window sizes to this
    }
}

/// In a grouped form macOS dims a disabled setting's control and leaves its title at full
/// strength, so a page that has been switched off doesn't look it. This grays the title too,
/// in the system's color for a control that can't be used.
private struct DimmedWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AnyShapeStyle(.foreground) : AnyShapeStyle(Color(nsColor: .disabledControlTextColor)))
    }
}

private extension View {
    /// Goes before the row's own `.disabled`, so that it sits inside what is disabled.
    func dimmedWhenDisabled() -> some View { modifier(DimmedWhenDisabled()) }
}

private struct LanguagePicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Lang.common, id: \.self) { code in
                Text(Lang.name(code) ?? code).tag(code)
            }
            if !Lang.common.contains(selection), !selection.isEmpty {
                Text(Lang.name(selection) ?? selection).tag(selection)
            }
        }
    }
}
