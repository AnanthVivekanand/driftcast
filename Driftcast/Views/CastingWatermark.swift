import SwiftUI

/// Covers the picture while the video is on another device: over the video a gray veil, or
/// before there is any picture the film's poster, dimmed, with who it is playing on across it
/// and, under that, what the file is and what is being done to it.
struct CastingWatermark: View {
    let deviceName: String
    let artwork: NSImage?
    var overVideo = false
    /// Nil until the video has been read and planned: "Streaming video…" stands in.
    var details: CastingDetails? = nil

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack {
                if overVideo {
                    Color(white: 0.18).opacity(0.55)
                } else {
                    Color.black
                }
                if let artwork, !overVideo {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: height)
                        .clipped()
                        .opacity(0.28)
                }
                // The big gray streaming mark, with the words laid across it.
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: min(height * 0.62, geometry.size.width * 0.34)))
                    .foregroundStyle(Color.gray.opacity(0.42))
                VStack(spacing: height * 0.035) {
                    Text("Connected to \(deviceName)")
                        .font(.system(size: height * 0.1, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.4)
                    if let details {
                        // Two short lines, each kept to one: the file, then what happens to it.
                        VStack(spacing: height * 0.012) {
                            Text(details.file)
                            Text(details.doing)
                        }
                        .font(.system(size: height * 0.046, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .opacity(0.85)
                    } else {
                        Text("Streaming video\u{2026}")
                            .font(.system(size: height * 0.05))
                            .opacity(0.8)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                .padding(24)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where the video is and how long is left of it, large in the lower left corner of the casting
/// picture: "14:08 (22m, 14s left)", the time in white and what is left in yellow (the
/// user's layout and colors, 2026-11-20). The window is across the room from whoever is
/// watching the TV, so it is sized by the picture like the words above it.
struct CastingTimeLabel: View {
    let time: TimeLeft

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            (Text(time.stamp).foregroundColor(.white)
                + Text(time.left.map { " (\($0))" } ?? "").foregroundColor(.yellow))
                .font(.system(size: height * 0.085, weight: .bold))
                .monospacedDigit()   // the digits change every second; the line must not shift
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .shadow(color: .black.opacity(0.75), radius: 6, y: 2)
                .padding(.horizontal, height * 0.05)
                .padding(.bottom, height * 0.035)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(time.left.map { "\(time.stamp), \($0)" } ?? time.stamp)
    }
}
