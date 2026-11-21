import Foundation

/// The two short lines under "Connected to …" in the casting picture: what the file is, and
/// what Driftcast is doing to it on the way to the device. They answer "why does this look
/// soft?" and "why is the fan on?" from across the room, without opening anything.
struct CastingDetails: Equatable {
    /// "4K Dolby Vision · HEVC · Dolby Digital+ 5.1"
    var file: String
    /// "Playing as is", "Repackaged, no quality loss" or "Converting to 1080p H.264", then the
    /// subtitle that is on: "Playing as is · English subtitles".
    var doing: String

    /// Nil while there is no plan yet (the video is still being read), or one with neither
    /// picture nor sound to name.
    init?(plan: StreamPlan?) {
        guard let plan else { return nil }
        var parts: [String] = []
        if let v = plan.video {
            parts.append(([v.resolutionName] + (v.hdrName.map { [$0] } ?? [])).joined(separator: " "))
            parts.append(Codecs.videoName(v.codec))
        }
        if let a = plan.audio { parts.append("\(a.codecName) \(Codecs.channelName(a.channels))") }
        guard !parts.isEmpty else { return nil }
        file = parts.joined(separator: " · ")
        doing = ([Self.action(plan)] + (Self.subtitles(plan).map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// What happens to the picture and the sound between the file and the device.
    static func action(_ plan: StreamPlan) -> String {
        var sound: String?
        if case .encode(let codec, let channels, _) = plan.audioAction {
            sound = "\(Codecs.audioName(codec.rawValue)) \(Codecs.channelName(channels))"
        }
        // A speaker gets no picture.
        if plan.isAudioOnly { return sound.map { "Sound only, converted to \($0)" } ?? "Sound only" }
        if case .transcode(let height, _, _) = plan.videoAction {
            // Named as the rows name a file: a wide film converted to 1920x800 is 1080p, not 800p.
            var converted = plan.video
            if let size = plan.outputVideoSize {
                converted?.width = Int(size.width)
                converted?.height = Int(size.height)
            }
            return "Converting to \(converted?.resolutionName ?? "\(height)p") H.264"
        }
        if let sound { return plan.video == nil ? "Converting to \(sound)" : "Picture as is, sound converted to \(sound)" }
        return plan.mode == .direct ? "Playing as is" : "Repackaged, no quality loss"
    }

    /// "English subtitles", or "Subtitles on" when their language isn't known; nil with none on.
    static func subtitles(_ plan: StreamPlan) -> String? {
        guard let on = plan.textSubtitle ?? plan.burnSubtitle else { return nil }
        return Lang.name(on.language).map { "\($0) subtitles" } ?? "Subtitles on"
    }
}
