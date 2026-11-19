import AVFoundation
import Foundation

/// A silent copy of the video for the small window while it plays on a TV. It reads the same
/// stream from Driftcast's server and follows the TV's position, so the window shows the film
/// under the "Connected to" overlay rather than a still. It never takes AirPlay itself and
/// makes no sound.
@MainActor
final class CastingMirror: ObservableObject {
    let player = AVPlayer()
    /// False until the copy can show a picture; the overlay shows the poster until then.
    @Published private(set) var hasPicture = false

    private var url: URL?
    private var statusObservation: NSKeyValueObservation?
    private var lastSeek = Date.distantPast

    /// Further apart than this and the copy jumps to where the TV is.
    static let maxDrift = 1.5
    /// A jump takes a moment to land, so the copy isn't moved again straight away.
    static let settleSeconds = 3.0

    init() {
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    /// Plays `url` at `time` (the TV's clock), playing or paused as the TV is.
    func follow(url: URL, time: Double, playing: Bool) {
        if url != self.url {
            self.url = url
            hasPicture = false
            let item = AVPlayerItem(url: url)
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let ready = item.status == .readyToPlay
                // Only for the stream still playing: this can arrive after a stop or a change.
                DispatchQueue.main.async {
                    guard let self, self.player.currentItem === item else { return }
                    self.hasPicture = ready
                }
            }
            player.replaceCurrentItem(with: item)
            seek(to: time)
        } else if player.currentItem?.status == .readyToPlay, Date().timeIntervalSince(lastSeek) > Self.settleSeconds {
            let now = player.currentTime().seconds
            if !now.isFinite || abs(now - time) > Self.maxDrift { seek(to: time) }
        }
        if playing {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    private func seek(to time: Double) {
        lastSeek = Date()
        player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        guard url != nil else { return }
        url = nil
        hasPicture = false
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
