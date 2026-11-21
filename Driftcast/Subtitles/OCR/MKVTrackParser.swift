//
// MKVTrackParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/22/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

/// Pulls PGS and VobSub tracks out of a Matroska file, rewrapped as a .sup stream and as a .sub stream
/// with its index, which is what the picture readers take.
///
/// `tracks` lists the file's picture tracks in the order their track entries appear, the same order
/// ffprobe numbers them in, with a track that has no blocks kept as an empty placeholder. The list used
/// to be built from a dictionary, so with two picture tracks the n-th entry was whichever the run's
/// hash order put there, and English could be read as Spanish and cached as English.
class MKVTrackParser: MKVFileHandler {
    // MARK: - Properties

    private(set) var tracks: [MKVTrack] = []

    /// The file's tick in nanoseconds, from its Info element.
    private var timestampScale: UInt64 = 1_000_000

    /// The most of one block, or one inflated block, held in memory. A PGS display set is well under a
    /// megabyte and a VobSub picture under 64 KB, so anything near this is damage.
    private static let blockLimit = 32 << 20

    /// How a track's blocks were packed by the muxer (Matroska's ContentEncodings).
    enum Packing {
        case zlib
        case headerStripping(Data)
        case unsupported(String)
    }

    struct ContentEncoding {
        var order: UInt64 = 0
        /// Bit 1: the blocks. Bit 2: CodecPrivate.
        var scope: UInt64 = 1
        var packing: Packing = .zlib
    }

    struct TrackEntry {
        var number = 0
        var codecID = ""
        var language: String?
        var codecPrivate: Data?
        var encodings: [ContentEncoding] = []
    }

    private struct TrackBuffer {
        var data = Data()
        var indexLines: [String] = []
    }

    // MARK: - Functions

    /// Reads the track entries and the blocks of every track whose codec is in `codecs`, or with
    /// `position`, only of the one at that place among them (the rest are listed empty). Reading one
    /// track no longer holds every picture track of the film in memory at once.
    ///
    /// Throws for a track whose blocks are packed in a way this can't undo, so the caller can fall back
    /// to burning the subtitle in, and throws `CancellationError` when its task is canceled mid-file.
    func parseTracks(for codecs: [String], onlyAt position: Int? = nil) throws {
        tracks = []
        let segment = try findSegment()

        var entries: [TrackEntry]?
        var firstCluster: UInt64?
        seek(to: segment.start)
        while let element = try nextElement(before: segment.end) {
            if element.id == EBML.cluster {
                firstCluster = element.headerStart
                break
            }
            if element.id == EBML.tracksID, entries == nil {
                entries = try readTrackEntries(element)
            } else if element.id == EBML.info {
                try readInfo(element)
            }
            guard element.sizeKnown else { break }
            seek(to: element.end)
        }
        guard let entries else {
            throw macSubtitleOCRError.invalidInputFile("MKV tracks element not found in file")
        }

        let pictureTracks = entries.filter { codecs.contains($0.codecID) }
        let wanted: [TrackEntry]
        if let position {
            wanted = pictureTracks.indices.contains(position) ? [pictureTracks[position]] : []
        } else {
            wanted = pictureTracks
        }
        for entry in wanted {
            try Self.checkPacking(of: entry)
        }

        var buffers: [Int: TrackBuffer] = [:]
        if let firstCluster, !wanted.isEmpty {
            let byNumber = Dictionary(wanted.map { ($0.number, $0) }) { first, _ in first }
            try readClusters(from: firstCluster, segmentEnd: segment.end, wanted: byNumber, into: &buffers)
        }

        tracks = pictureTracks.map { entry in
            let buffer = buffers[entry.number] ?? TrackBuffer()
            return MKVTrack(
                trackNumber: entry.number,
                codecID: entry.codecID,
                trackData: buffer.data,
                idxData: entry.codecID == "S_VOBSUB" ? Self.indexText(for: entry, lines: buffer.indexLines) : nil,
                language: entry.language)
        }
    }

    // MARK: - Header

    private func findSegment() throws -> Element {
        seek(to: 0)
        guard let header = try nextElement(before: endOfFile), header.id == EBML.ebmlHeader, header.sizeKnown else {
            throw macSubtitleOCRError.invalidInputFile("The file isn't a Matroska file.")
        }
        seek(to: header.end)
        while let element = try nextElement(before: endOfFile) {
            if element.id == EBML.segmentID {
                return element
            }
            guard element.sizeKnown else { break }
            seek(to: element.end)
        }
        throw macSubtitleOCRError.invalidInputFile("MKV segment element not found in file")
    }

    private func readInfo(_ info: Element) throws {
        guard let data = try readData(of: info, limit: 1 << 20) else { return }
        for (id, value) in EBMLParser.children(data) where id == EBML.timestampScale {
            if let scale = EBMLParser.readUnsigned(value), scale > 0 {
                timestampScale = scale
            }
        }
    }

    private func readTrackEntries(_ tracksElement: Element) throws -> [TrackEntry] {
        guard let data = try readData(of: tracksElement, limit: 16 << 20) else {
            throw macSubtitleOCRError.invalidInputFile("The MKV track list is too large to be real.")
        }
        var entries: [TrackEntry] = []
        for (id, entryData) in EBMLParser.children(data) where id == EBML.trackEntryID {
            var entry = TrackEntry()
            var language: String?
            var languageBCP47: String?
            for (field, value) in EBMLParser.children(entryData) {
                switch field {
                case EBML.trackNumberID:
                    entry.number = Int(clamping: EBMLParser.readUnsigned(value) ?? 0)
                case EBML.codecID:
                    entry.codecID = Self.text(value)
                case EBML.language:
                    language = Self.text(value)
                case EBML.languageBCP47:
                    languageBCP47 = Self.text(value)
                case EBML.codecPrivate:
                    entry.codecPrivate = value
                case EBML.contentEncodings:
                    entry.encodings = Self.readEncodings(value)
                default:
                    break
                }
            }
            entry.language = [languageBCP47, language].compactMap { $0 }.first { !$0.isEmpty }
            if entry.number > 0 {
                entries.append(entry)
            }
        }
        return entries
    }

    private static func readEncodings(_ data: Data) -> [ContentEncoding] {
        var encodings: [ContentEncoding] = []
        for (id, encodingData) in EBMLParser.children(data) where id == EBML.contentEncoding {
            var encoding = ContentEncoding()
            var type: UInt64 = 0
            var compression: Data?
            for (field, value) in EBMLParser.children(encodingData) {
                switch field {
                case EBML.contentEncodingOrder: encoding.order = EBMLParser.readUnsigned(value) ?? 0
                case EBML.contentEncodingScope: encoding.scope = EBMLParser.readUnsigned(value) ?? 1
                case EBML.contentEncodingType: type = EBMLParser.readUnsigned(value) ?? 0
                case EBML.contentCompression: compression = value
                default: break
                }
            }
            if type != 0 {
                encoding.packing = .unsupported("encrypted")
            } else {
                var algorithm: UInt64 = 0
                var settings = Data()
                for (field, value) in EBMLParser.children(compression ?? Data()) {
                    if field == EBML.contentCompAlgo { algorithm = EBMLParser.readUnsigned(value) ?? 0 }
                    if field == EBML.contentCompSettings { settings = value }
                }
                switch algorithm {
                case 0: encoding.packing = .zlib
                case 3: encoding.packing = .headerStripping(settings)
                case 1: encoding.packing = .unsupported("bzip2")
                case 2: encoding.packing = .unsupported("LZO")
                default: encoding.packing = .unsupported("method \(algorithm)")
                }
            }
            encodings.append(encoding)
        }
        // Undone from the highest order down, as the Matroska specification says.
        return encodings.sorted { $0.order > $1.order }
    }

    private static func checkPacking(of entry: TrackEntry) throws {
        for encoding in entry.encodings where encoding.scope & 3 != 0 {
            if case .unsupported(let method) = encoding.packing {
                throw macSubtitleOCRError.unsupportedPacking(method)
            }
        }
    }

    /// Undoes the track's packing for data in `scope` (1 for blocks, 2 for CodecPrivate).
    private static func unpack(_ data: Data, for entry: TrackEntry, scope: UInt64) throws -> Data {
        var data = data
        for encoding in entry.encodings where encoding.scope & scope != 0 {
            switch encoding.packing {
            case .zlib:
                data = try zlibInflate(data, limit: blockLimit)
            case .headerStripping(let header):
                data = header + data
            case .unsupported(let method):
                throw macSubtitleOCRError.unsupportedPacking(method)
            }
        }
        return data
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }

    /// The VobSub index for a track: the header lines from CodecPrivate (palette, size), one language
    /// section, and the time and place of each picture.
    private static func indexText(for entry: TrackEntry, lines: [String]) -> String {
        let header = entry.codecPrivate.flatMap { try? unpack($0, for: entry, scope: 2) }.map(text) ?? ""
        let kept = header.split(whereSeparator: \.isNewline).filter { line in
            !["id:", "langidx:", "timestamp:", "#"].contains { line.hasPrefix($0) }
        }
        let language = String((entry.language ?? "und").unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init))
        return (["# VobSub index file, v7 (do not modify this line!)"] + kept.map(String.init)
            + ["langidx: 0", "id: \(language.isEmpty ? "und" : language), index: 0"] + lines)
            .joined(separator: "\n") + "\n"
    }

    // MARK: - Clusters

    private func readClusters(from start: UInt64, segmentEnd: UInt64, wanted: [Int: TrackEntry],
                              into buffers: inout [Int: TrackBuffer]) throws {
        seek(to: start)
        while let element = try nextElement(before: segmentEnd) {
            if Task.isCancelled {
                throw CancellationError()
            }
            if element.id == EBML.cluster {
                try readCluster(element, wanted: wanted, into: &buffers)
            } else if element.sizeKnown {
                seek(to: element.end)
            } else {
                // Only a Segment or a Cluster may leave its size open; anything else is damage.
                break
            }
        }
    }

    /// Reads one cluster's blocks and leaves the position where the next top-level element starts. A
    /// cluster of unknown size ends where the next cluster (or any other top-level element) begins.
    private func readCluster(_ cluster: Element, wanted: [Int: TrackEntry],
                             into buffers: inout [Int: TrackBuffer]) throws {
        var clusterTime: UInt64 = 0
        seek(to: cluster.start)
        while let child = try nextElement(before: cluster.end) {
            if !cluster.sizeKnown, EBML.topLevel.contains(child.id) {
                seek(to: child.headerStart)
                return
            }
            switch child.id {
            case EBML.timestamp:
                clusterTime = try readData(of: child, limit: 8).flatMap(EBMLParser.readUnsigned) ?? 0
            case EBML.simpleBlock:
                try readBlock(child, clusterTime: clusterTime, wanted: wanted, into: &buffers)
            case EBML.blockGroup:
                seek(to: child.start)
                while let part = try nextElement(before: child.end) {
                    if part.id == EBML.block {
                        try readBlock(part, clusterTime: clusterTime, wanted: wanted, into: &buffers)
                    }
                    guard part.sizeKnown else { break }
                    seek(to: part.end)
                }
            default:
                break
            }
            guard child.sizeKnown else { break }
            seek(to: child.end)
        }
        // A damaged child ends the cluster early; a cluster of known size is stepped over whole.
        seek(to: cluster.sizeKnown ? cluster.end : endOfFile)
    }

    private func readBlock(_ block: Element, clusterTime: UInt64, wanted: [Int: TrackEntry],
                           into buffers: inout [Int: TrackBuffer]) throws {
        seek(to: block.start)
        let head = try read(Int(min(12, block.end - block.start)))
        guard let (number, numberLength) = EBMLParser.readVINT(head, at: 0, keepMarker: false),
              numberLength + 3 <= head.count,
              let entry = wanted[Int(clamping: number)]
        else { return }
        let byte = { (index: Int) in head[head.startIndex + index] }
        let relative = Int16(bitPattern: UInt16(byte(numberLength)) << 8 | UInt16(byte(numberLength + 1)))
        let flags = byte(numberLength + 2)
        guard flags & 0x06 == 0 else {
            logger.warning("Skipping a laced subtitle block on track \(entry.number)")
            return
        }
        let frameStart = block.start + UInt64(numberLength + 3)
        guard block.end - frameStart <= UInt64(Self.blockLimit) else { return }
        seek(to: frameStart)
        let frame: Data
        do {
            frame = try Self.unpack(read(Int(block.end - frameStart)), for: entry, scope: 1)
        } catch let error as macSubtitleOCRError {
            // One damaged block costs one picture, not the track.
            logger.warning("Skipping a subtitle block on track \(entry.number): \(String(describing: error))")
            return
        }
        let pts = absolutePTS(cluster: clusterTime, block: relative, timestampScale: timestampScale)
        if entry.codecID == "S_HDMV/PGS" {
            Self.appendPGS(frame, pts: pts, to: &buffers[entry.number, default: TrackBuffer()])
        } else if entry.codecID == "S_VOBSUB" {
            Self.appendVobSub(frame, pts: pts, to: &buffers[entry.number, default: TrackBuffer()])
        }
    }

    /// Matroska keeps a PGS segment's type, size and data but drops its 13 byte "PG" header; this puts
    /// the header back. A segment cut short at the end of the block is left out rather than passed on
    /// with a size that runs past its data.
    private static func appendPGS(_ frame: Data, pts: UInt64, to buffer: inout TrackBuffer) {
        let header = Data([0x50, 0x47] + encodePTSForPGS(pts) + [0x00, 0x00, 0x00, 0x00])
        let bytes = [UInt8](frame)
        var offset = 0
        while offset + 3 <= bytes.count {
            let size = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            guard offset + 3 + size <= bytes.count else { break }
            buffer.data.append(header)
            buffer.data.append(contentsOf: bytes[offset ..< offset + 3 + size])
            offset += 3 + size
        }
    }

    /// Matroska keeps a VobSub picture as the bare subpicture unit; this wraps it in the MPEG program
    /// stream packs a .sub file holds and notes its time and place for the index.
    private static func appendVobSub(_ frame: Data, pts: UInt64, to buffer: inout TrackBuffer) {
        guard !frame.isEmpty else { return }
        buffer.indexLines.append("timestamp: \(vobSubIndexTime(pts)), filepos: \(String(format: "%09X", buffer.data.count))")
        var remaining = frame[...]
        var first = true
        while !remaining.isEmpty {
            // A 2048 byte pack: 14 bytes of pack header, 6 of PES start code and length, then the PES
            // header (9 bytes with the time on the first pack, 4 without) and the payload.
            let room = first ? 2019 : 2024
            let payload = remaining.prefix(room)
            remaining = remaining.dropFirst(payload.count)
            let pesHeader: [UInt8] = first
                ? [0x81, 0x80, 0x05] + encodePTSForVobSub(from: pts) + [0x20]
                : [0x81, 0x00, 0x00, 0x20]
            let pesLength = UInt16(pesHeader.count + payload.count)
            buffer.data.append(contentsOf: [0x00, 0x00, 0x01, 0xBA,             // Pack start code
                                            0x44, 0x00, 0x04, 0x00, 0x04, 0x01, // MPEG-2 system clock reference
                                            0x01, 0x89, 0xC3,                   // Multiplexer rate
                                            0xF8,                               // No stuffing
                                            0x00, 0x00, 0x01, 0xBD,             // Private stream 1
                                            UInt8(pesLength >> 8), UInt8(pesLength & 0xFF)])
            buffer.data.append(contentsOf: pesHeader)
            buffer.data.append(payload)
            first = false
        }
    }
}
