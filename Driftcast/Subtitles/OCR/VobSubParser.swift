//
// VobSubParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/4/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

/// Reads one DVD subtitle picture out of a .sub stream.
///
/// The picture (a subpicture unit) is spread over the payloads of one or more MPEG program stream
/// packets; it is gathered whole first and then read, every offset checked against what was gathered.
/// A .sub that was cut short or belongs to another .idx used to be read wherever its offsets pointed,
/// which ran off the end of the data or force-unwrapped a value that was never found. Now such a
/// picture throws and the caller skips just that one.
struct VobSubParser {
    // MARK: - Properties

    let subtitle: Subtitle
    private let masterPalette: [UInt8]

    /// How far past its first packet a picture is looked for. A picture is at most 64 KB, and packets
    /// of other languages can sit between its own, but nothing real is spread over a megabyte.
    private static let searchLimit = 1 << 20

    // MARK: - Lifecycle

    /// `timestamp` is the picture's time from the index, which every player goes by: a rip of several
    /// VOB files restarts the packets' own clock at each file, while the index keeps counting.
    init(index: Int, buffer: UnsafeRawBufferPointer, timestamp: TimeInterval, offset: UInt64,
         nextOffset: UInt64, idxPalette: [UInt8]) throws {
        guard idxPalette.count >= 48 else {
            throw macSubtitleOCRError.invalidInputFile("The VobSub index has no 16 color palette.")
        }
        subtitle = Subtitle(index: index, startTimestamp: timestamp, imageData: .init(), numberOfColors: 16)
        masterPalette = idxPalette
        guard offset < UInt64(buffer.count) else {
            throw macSubtitleOCRError.invalidInputFile("VobSub picture \(index) starts past the end of the .sub file.")
        }
        let unit = try Self.gatherSubpictureUnit(buffer, from: Int(offset))
        try readSubpictureUnit(unit, timestamp: timestamp)
        try decodeImage()
        try decodePalette()
    }

    // MARK: - Methods

    /// The subpicture unit starting in the packet at `start`: the payloads of that packet and the ones
    /// after it with the same substream number, up to the unit's own size.
    private static func gatherSubpictureUnit(_ buffer: UnsafeRawBufferPointer, from start: Int) throws -> [UInt8] {
        func u16(_ at: Int) -> Int { Int(buffer[at]) << 8 | Int(buffer[at + 1]) }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) << 16 | UInt32(u16(at + 2)) }

        var payload: [UInt8] = []
        var unitSize: Int?
        var substream: UInt8?
        var position = start
        let limit = min(buffer.count, start + searchLimit)
        while position + 6 <= limit {
            let code = u32(position)
            if code == MPEG2PacketType.psPacket {
                // Pack header: 14 bytes plus stuffing for MPEG-2, 12 for MPEG-1.
                guard position + 14 <= limit else { break }
                if buffer[position + 4] & 0xF0 == 0x20 {
                    position += 12
                } else {
                    position += 14 + Int(buffer[position + 13] & 0x07)
                }
                continue
            }
            // Anything that isn't a start code means the offset pointed into the middle of something.
            guard code & 0xFFFF_FF00 == 0x0000_0100, code != 0x0000_01B9 else { break }
            let end = position + 6 + u16(position + 4)
            guard end <= buffer.count else { break }
            if code == MPEG2PacketType.pesPacket, position + 9 <= end {
                let dataStart = position + 9 + Int(buffer[position + 8])
                if dataStart < end {
                    let id = buffer[dataStart]
                    if substream == nil {
                        substream = id
                    }
                    if id == substream {
                        payload.append(contentsOf: buffer[(dataStart + 1) ..< end])
                    }
                }
            }
            position = end
            if unitSize == nil, payload.count >= 2 {
                unitSize = Int(payload[0]) << 8 | Int(payload[1])
            }
            if let unitSize, payload.count >= unitSize {
                break
            }
        }
        guard let unitSize, unitSize >= 4, payload.count >= unitSize else {
            throw macSubtitleOCRError.invalidInputFile("A VobSub picture is incomplete or isn't where the index says.")
        }
        return Array(payload.prefix(unitSize))
    }

    /// Reads the unit's control sequences: where the picture is, its colors, and when it comes on and
    /// goes off. Each sequence has a delay in units of 1024 ticks of the 90 kHz clock and points to the
    /// next; the last points to itself. The stop command is normally in the second sequence, which was
    /// never reached before, so every DVD subtitle lasted 5 seconds or until the next one.
    private func readSubpictureUnit(_ unit: [UInt8], timestamp: TimeInterval) throws {
        func u16(_ at: Int) -> Int { Int(unit[at]) << 8 | Int(unit[at + 1]) }

        let controlStart = u16(2)
        guard controlStart >= 4, controlStart + 4 <= unit.count else {
            throw macSubtitleOCRError.invalidInputFile("VobSub picture \(subtitle.index) has no control data.")
        }
        // Image data starts after the 4 byte size and control offset; field offsets below count from there.
        subtitle.imageData = Data(unit[4 ..< controlStart])

        var sequence = controlStart
        var visited = Set<Int>()
        var started = false
        while sequence + 4 <= unit.count, visited.insert(sequence).inserted {
            let delay = TimeInterval(u16(sequence)) * 1024 / 90000
            let next = u16(sequence + 2)
            var index = sequence + 4
            commands: while index < unit.count {
                let command = unit[index]
                index += 1
                switch command {
                case 0x00, 0x01: // Start display (forced or not)
                    if !started {
                        subtitle.startTimestamp = timestamp + delay
                        started = true
                    }
                case 0x02: // Stop display
                    // The longest delay there is stands for "until further notice" (ffmpeg writes it when
                    // it doesn't know the end); read literally it kept the last line up for 12 minutes.
                    if subtitle.endTimestamp == nil, u16(sequence) != 0xFFFF {
                        subtitle.endTimestamp = timestamp + delay
                    }
                case 0x03: // Palette: four 4 bit indexes into the index file's 16 colors
                    guard index + 2 <= unit.count else { break commands }
                    subtitle.imagePalette = [unit[index + 1] & 0x0F, unit[index + 1] >> 4,
                                             unit[index] & 0x0F, unit[index] >> 4]
                    index += 2
                case 0x04: // Alpha for the same four
                    guard index + 2 <= unit.count else { break commands }
                    // A fade sets it again in later sequences; the first is the one the picture is drawn with.
                    if subtitle.imageAlpha == nil {
                        subtitle.imageAlpha = [unit[index + 1] & 0x0F, unit[index + 1] >> 4,
                                               unit[index] & 0x0F, unit[index] >> 4]
                    }
                    index += 2
                case 0x05: // Display area
                    guard index + 6 <= unit.count else { break commands }
                    if subtitle.imageXOffset == nil {
                        let x1 = Int(unit[index]) << 4 | Int(unit[index + 1] >> 4)
                        let x2 = Int(unit[index + 1] & 0x0F) << 8 | Int(unit[index + 2])
                        let y1 = Int(unit[index + 3]) << 4 | Int(unit[index + 4] >> 4)
                        let y2 = Int(unit[index + 4] & 0x0F) << 8 | Int(unit[index + 5])
                        subtitle.imageXOffset = x1
                        subtitle.imageYOffset = y1
                        subtitle.imageWidth = x2 - x1 + 1
                        subtitle.imageHeight = y2 - y1 + 1
                    }
                    index += 6
                case 0x06: // Where the two interlaced fields' pixels start
                    guard index + 4 <= unit.count else { break commands }
                    if subtitle.evenOffset == nil {
                        subtitle.evenOffset = u16(index) - 4
                        subtitle.oddOffset = u16(index + 2) - 4
                    }
                    index += 4
                case 0x07: // Color and contrast changes within the picture, not used here
                    guard index + 2 <= unit.count else { break commands }
                    index += max(2, u16(index))
                default: // 0xFF ends the sequence, and anything unknown can't be stepped over
                    break commands
                }
            }
            guard next != sequence else { break }
            sequence = next
        }

        guard let width = subtitle.imageWidth, let height = subtitle.imageHeight,
              (1 ... 4096).contains(width), (1 ... 4096).contains(height),
              let even = subtitle.evenOffset, let odd = subtitle.oddOffset, even >= 0, odd >= 0
        else {
            throw macSubtitleOCRError.invalidInputFile("VobSub picture \(subtitle.index) has no usable size or position.")
        }
    }

    private func decodePalette() throws {
        guard let indexes = subtitle.imagePalette, indexes.count == 4,
              let alpha = subtitle.imageAlpha, alpha.count == 4
        else {
            throw macSubtitleOCRError.invalidInputFile("VobSub picture \(subtitle.index) has no colors.")
        }

        var palette = [UInt8](repeating: 0, count: 4 * 4)
        for i in 0 ..< 4 {
            // Indexes are 4 bit, and the palette was checked to hold all 16 colors.
            let color = 3 * Int(indexes[i])
            palette[4 * i] = masterPalette[color]
            palette[4 * i + 1] = masterPalette[color + 1]
            palette[4 * i + 2] = masterPalette[color + 2]
            palette[4 * i + 3] = alpha[i] * 0x11
        }

        subtitle.imagePalette = palette
    }

    private func decodeImage() throws {
        let rleData = RLEData(
            data: subtitle.imageData ?? Data(),
            width: subtitle.imageWidth ?? 0,
            height: subtitle.imageHeight ?? 0,
            evenOffset: subtitle.evenOffset ?? 0,
            oddOffset: subtitle.oddOffset ?? 0)
        subtitle.imageData = try rleData.decodeVobSub()
    }
}
