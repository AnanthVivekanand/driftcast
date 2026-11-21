//
// PGS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

/// Reads a PGS (Blu-ray) subtitle stream into pictures with their times.
///
/// The stream is a run of display sets, each a presentation composition (when, and which objects
/// where), palettes, objects and an end segment. It is read one display set at a time: whatever comes
/// on screen at a composition's time stays until the next composition. The reader used to assume one
/// object per set and skip a fixed 13 bytes after it for the end segment, so a set with two objects
/// (a top line and a bottom line, or a sign over dialogue) put it in the middle of the second one, and
/// it read headers out of image data from there on. Every header is now checked for its "PG" mark, and a
/// picture that can't be decoded costs that picture, not the film.
struct PGS {
    // MARK: - Properties

    private(set) var subtitles = [Subtitle]()
    private let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "PGS")
    private let pgsHeaderLength = 13

    /// Video dimensions from the most recent presentation composition segment.
    private var videoWidth = 0
    private var videoHeight = 0

    /// The largest object accepted whatever the composition says: a 4K picture's worth.
    private static let maximumObjectSide = 4096

    /// Where a composition puts one object, and the part of it shown when it is cropped.
    private struct Placement {
        var objectID: Int
        var x: Int
        var y: Int
        var crop: (x: Int, y: Int, width: Int, height: Int)?
    }

    private struct Composition {
        var time: TimeInterval
        var paletteID: Int
        var placements: [Placement]
    }

    // MARK: - Lifecycle

    init(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            try parseData(buffer)
        }
    }

    init(_ buffer: UnsafeRawBufferPointer) throws {
        try parseData(buffer)
    }

    // MARK: - Methods

    private mutating func parseData(_ buffer: UnsafeRawBufferPointer) throws {
        guard buffer.count > pgsHeaderLength else {
            logger.debug("Found empty PGS buffer, skipping track")
            return
        }
        var offset = 0
        var palettes: [Int: PDS] = [:]
        var objects: [Int: ODS] = [:]
        var composition: Composition?
        /// The picture on screen, until the next composition ends it.
        var shown: Subtitle?

        while offset + pgsHeaderLength <= buffer.count {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard buffer[offset] == 0x50, buffer[offset + 1] == 0x47 else {
                // Not a segment header: find the next one rather than reading headers out of image data.
                guard let next = nextHeader(in: buffer, after: offset) else { break }
                logger.warning("PGS: no segment header at \(offset), resuming at \(next)")
                offset = next
                continue
            }
            let time = segmentTime(buffer, offset)
            let segmentType = buffer[offset + 10]
            let segmentLength = Int(buffer[offset + 11]) << 8 | Int(buffer[offset + 12])
            let start = offset + pgsHeaderLength
            guard start + segmentLength <= buffer.count else {
                logger.warning("Segment of length \(segmentLength) extends past the end of the stream, abandoning remaining segments")
                break
            }
            offset = start + segmentLength

            switch segmentType {
            case 0x16: // Presentation composition
                guard segmentLength >= 11 else { continue }
                // Whatever was on screen goes off when the next composition takes effect.
                if let shown, shown.endTimestamp == nil {
                    shown.endTimestamp = time
                }
                videoWidth = Int(buffer[start]) << 8 | Int(buffer[start + 1])
                videoHeight = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                if buffer[start + 7] & 0x80 != 0 {
                    // Epoch start: objects and palettes from before are gone.
                    objects.removeAll()
                    palettes.removeAll()
                }
                composition = Composition(time: time, paletteID: Int(buffer[start + 9]),
                                          placements: placements(buffer, start, segmentLength))
            case 0x14: // Palette
                guard segmentLength >= 2 else { continue }
                do {
                    palettes[Int(buffer[start])] = try PDS(buffer, start, segmentLength)
                } catch {
                    logger.warning("PGS: skipping a palette: \(String(describing: error))")
                }
            case 0x15: // Object, or a fragment of one
                guard segmentLength >= 4 else { continue }
                let id = Int(buffer[start]) << 8 | Int(buffer[start + 1])
                do {
                    if buffer[start + 3] & 0x80 != 0 {
                        objects[id] = try ODS(buffer, start, segmentLength)
                    } else {
                        try objects[id]?.appendSegment(buffer, start, segmentLength)
                    }
                } catch {
                    objects[id] = nil
                    logger.warning("PGS: skipping object \(id): \(String(describing: error))")
                }
            case 0x80: // End of display set
                defer { composition = nil }
                guard let current = composition, !current.placements.isEmpty else { continue }
                guard let palette = palettes[current.paletteID] ?? palettes.values.first else { continue }
                do {
                    guard let subtitle = try picture(for: current, objects: objects, palette: palette) else { continue }
                    if let shown, shown.endTimestamp == current.time, shown.imageData == subtitle.imageData,
                       shown.imageWidth == subtitle.imageWidth {
                        // The same picture again (a palette change in a fade, or a set repeated for
                        // seeking): one cue, drawn with the more opaque of the two palettes.
                        shown.endTimestamp = nil
                        if opacity(subtitle.imagePalette) > opacity(shown.imagePalette) {
                            shown.imagePalette = subtitle.imagePalette
                        }
                        continue
                    }
                    subtitles.append(subtitle)
                    shown = subtitle
                } catch {
                    logger.warning("PGS: skipping the picture at \(current.time): \(String(describing: error))")
                }
            case 0x17: // Window
                break
            default:
                logger.warning("Unknown segment type: \(segmentType.hex()), skipping...")
            }
        }
    }

    /// The composition objects of a presentation composition segment at `start`.
    private func placements(_ buffer: UnsafeRawBufferPointer, _ start: Int, _ length: Int) -> [Placement] {
        let end = start + length
        let count = Int(buffer[start + 10])
        var placements: [Placement] = []
        var index = start + 11
        for _ in 0 ..< count {
            guard index + 8 <= end else { break }
            func u16(_ at: Int) -> Int { Int(buffer[at]) << 8 | Int(buffer[at + 1]) }
            var placement = Placement(objectID: u16(index), x: u16(index + 4), y: u16(index + 6))
            let cropped = buffer[index + 3] & 0x40 != 0
            index += 8
            if cropped {
                guard index + 8 <= end else { break }
                placement.crop = (u16(index), u16(index + 2), u16(index + 4), u16(index + 6))
                index += 8
            }
            placements.append(placement)
        }
        return placements
    }

    /// The picture a composition shows: its one object, or several drawn together where the composition
    /// places them, so a top and a bottom line are read as one subtitle. Nil when none of its objects
    /// has arrived.
    private func picture(for composition: Composition, objects: [Int: ODS], palette: PDS) throws -> Subtitle? {
        var pieces: [(x: Int, y: Int, width: Int, height: Int, pixels: Data)] = []
        for placement in composition.placements {
            guard let object = objects[placement.objectID] else { continue }
            try checkObjectDimensions(of: object)
            let width = object.objectWidth, height = object.objectHeight
            var pixels = try object.decodeRLEData()
            guard width > 0, height > 0, pixels.count >= width * height else { continue }
            var piece = (x: placement.x, y: placement.y, width: width, height: height, pixels: pixels)
            if let crop = placement.crop {
                let x0 = min(max(crop.x, 0), width), y0 = min(max(crop.y, 0), height)
                let w = min(crop.width, width - x0), h = min(crop.height, height - y0)
                guard w > 0, h > 0 else { continue }
                var cropped = Data(capacity: w * h)
                for row in y0 ..< y0 + h {
                    cropped.append(pixels[(row * width + x0) ..< (row * width + x0 + w)])
                }
                pixels = cropped
                piece = (placement.x, placement.y, w, h, pixels)
            }
            pieces.append(piece)
        }
        guard let first = pieces.first else { return nil }

        var width = first.width, height = first.height, image = first.pixels
        if pieces.count > 1, let clear = transparentIndex(in: palette.palette) {
            let left = pieces.map(\.x).min()!, top = pieces.map(\.y).min()!
            let right = pieces.map { $0.x + $0.width }.max()!, bottom = pieces.map { $0.y + $0.height }.max()!
            let canvasWidth = right - left, canvasHeight = bottom - top
            if canvasWidth <= Self.maximumObjectSide, canvasHeight <= Self.maximumObjectSide {
                var canvas = [UInt8](repeating: clear, count: canvasWidth * canvasHeight)
                for piece in pieces {
                    let bytes = [UInt8](piece.pixels)
                    for row in 0 ..< piece.height {
                        let target = (piece.y - top + row) * canvasWidth + (piece.x - left)
                        canvas.replaceSubrange(target ..< target + piece.width,
                                               with: bytes[(row * piece.width) ..< ((row + 1) * piece.width)])
                    }
                }
                width = canvasWidth
                height = canvasHeight
                image = Data(canvas)
            }
        }
        return Subtitle(
            index: subtitles.count + 1,
            startTimestamp: composition.time,
            imageWidth: width,
            imageHeight: height,
            imageData: image,
            imagePalette: palette.palette,
            numberOfColors: 256)
    }

    /// A palette entry that is fully transparent, to fill the space between objects with.
    private func transparentIndex(in palette: [UInt8]) -> UInt8? {
        let candidates = [255] + Array(0 ..< 255)
        return candidates.first { 4 * $0 + 3 < palette.count && palette[4 * $0 + 3] == 0 }.map { UInt8($0) }
    }

    private func opacity(_ palette: [UInt8]?) -> Int {
        guard let palette else { return 0 }
        return stride(from: 3, to: palette.count, by: 4).reduce(0) { $0 + Int(palette[$1]) }
    }

    /// Rejects an object that is too large to belong to the video it is composited onto.
    ///
    /// Decoding fills a buffer of `objectWidth * objectHeight`, both of which are 16 bit fields, so an
    /// object claiming dimensions the video cannot hold would reserve far more memory than the stream
    /// could ever describe. Empty objects are left to the placeholder path that already handles them.
    private func checkObjectDimensions(of ods: ODS) throws {
        guard ods.objectWidth <= Self.maximumObjectSide, ods.objectHeight <= Self.maximumObjectSide else {
            throw macSubtitleOCRError.invalidODSDimensions(
                "Object of \(ods.objectWidth)x\(ods.objectHeight) is larger than any video")
        }
        guard videoWidth > 0, videoHeight > 0 else { return }
        guard ods.objectWidth <= videoWidth, ods.objectHeight <= videoHeight else {
            throw macSubtitleOCRError.invalidODSDimensions(
                "Object of \(ods.objectWidth)x\(ods.objectHeight) does not fit the " +
                    "\(videoWidth)x\(videoHeight) video")
        }
    }

    /// The presentation time of the segment header at `offset`, which the caller has checked is whole.
    private func segmentTime(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> TimeInterval {
        let ticks = (2 ..< 6).reduce(UInt32(0)) { $0 << 8 | UInt32(buffer[offset + $1]) }
        return TimeInterval(ticks) / 90000
    }

    /// The next place after `offset` that starts like a segment header: "PG" and a known segment type.
    private func nextHeader(in buffer: UnsafeRawBufferPointer, after offset: Int) -> Int? {
        var index = offset + 1
        while index + pgsHeaderLength <= buffer.count {
            if buffer[index] == 0x50, buffer[index + 1] == 0x47, [0x14, 0x15, 0x16, 0x17, 0x80].contains(buffer[index + 10]) {
                return index
            }
            index += 1
        }
        return nil
    }
}
