//
// SRT.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct SRT {
    // MARK: - Properties

    private var subtitles: [Subtitle]

    // MARK: - Lifecycle

    init(subtitles: [Subtitle]) {
        self.subtitles = subtitles
    }

    // MARK: - Functions

    /// The SRT text, as `write(toFileAt:)` would write it.
    func encoded() -> String {
        encodeSRT()
    }

    /// Writes the SRT object to the file at the given URL
    func write(toFileAt url: URL) {
        let srtContent = encodeSRT()
        do {
            try srtContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to write SRT content to file: \(error.localizedDescription)", to: &stderr)
        }
    }

    // MARK: - Methods

    /// Encodes the SRT object into SRT format and returns it as a string.
    ///
    /// Cues are written in time order and numbered from 1 by their place in the file. Their own
    /// numbers can't be used to find the next cue: the caller drops blank cues first, and after the
    /// first gap `subtitles[index]` pointed one cue too far.
    private func encodeSRT() -> String {
        let timed = subtitles.filter { $0.startTimestamp != nil && $0.text != nil }
            .enumerated().sorted { ($0.element.startTimestamp!, $0.offset) < ($1.element.startTimestamp!, $1.offset) }
            .map(\.element)
        var srtContent = ""

        for (position, subtitle) in timed.enumerated() {
            let start = subtitle.startTimestamp!
            let end = endTimestamp(of: subtitle, next: position + 1 < timed.count ? timed[position + 1] : nil)

            srtContent += "\(position + 1)\n"
            srtContent += "\(start.srtTimestamp) --> \(end.srtTimestamp)\n"
            srtContent += "\(subtitle.text!)\n\n"
        }

        return srtContent
    }

    /// When a cue goes off: its own end if the picture had one, else 5 seconds on; either way not after
    /// the next cue starts. The 5 second cap used to apply to real ends too, so a line the disc holds
    /// for 7 seconds went off at 5.
    private func endTimestamp(of subtitle: Subtitle, next: Subtitle?) -> TimeInterval {
        let start = subtitle.startTimestamp!
        var end = subtitle.endTimestamp.flatMap { $0 > start ? $0 : nil } ?? start + 5
        if let nextStart = next?.startTimestamp, nextStart > start {
            end = min(end, max(start, nextStart - 0.1))
        }
        return end
    }
}
