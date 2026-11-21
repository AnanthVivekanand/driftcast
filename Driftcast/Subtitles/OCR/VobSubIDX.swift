//
// VobSubIDX.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/4/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

struct VobSubIDX {
    // MARK: - Properties

    private(set) var timestamps: [TimeInterval] = []
    private(set) var offsets: [UInt64] = []
    private(set) var palette: [UInt8] = []
    private(set) var language: String?

    // MARK: - Lifecycle

    init(_ url: URL) throws {
        do {
            let idxData = try String(contentsOf: url, encoding: .utf8)
            try parseIdxFile(idxData: idxData)
        } catch {
            throw macSubtitleOCRError.fileReadError("Failed to parse IDX file: \(error)")
        }
    }

    init(_ idxData: String) throws {
        do {
            try parseIdxFile(idxData: idxData)
        } catch {
            throw macSubtitleOCRError.fileReadError("Failed to parse IDX file: \(error)")
        }
    }

    // MARK: - Methods

    /// Reads the palette and, for one language, each picture's time and place in the .sub.
    ///
    /// Lines are split on any line break, so an index written on Windows (CRLF, the usual kind) is read
    /// rather than taken as one long line with nothing in it. An index can hold several languages, each
    /// an `id:` section with its own timestamps; only the one `langidx:` names (or the first) is read,
    /// where every section used to be merged into one track read in the last section's language.
    private mutating func parseIdxFile(idxData: String) throws {
        let lines = idxData.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var chosenIndex: Int?
        for line in lines where line.hasPrefix("langidx:") {
            chosenIndex = Int(line.dropFirst("langidx:".count).trimmingCharacters(in: .whitespaces))
        }
        let sections = lines.compactMap(Self.parseLanguageLine)
        let chosen = sections.first { $0.index == chosenIndex } ?? sections.first

        // Timestamps before any `id:` line count only when the index has no sections at all.
        var inChosenSection = chosen == nil
        for line in lines {
            if line.hasPrefix("palette:") {
                palette = parsePalette(line: line)
            } else if let section = Self.parseLanguageLine(line) {
                inChosenSection = section.index == chosen?.index
                if inChosenSection {
                    language = section.language
                }
            } else if inChosenSection, line.hasPrefix("timestamp:"),
                      let timestamp = extractTimestamp(from: line), let offset = extractOffset(from: line) {
                offsets.append(offset)
                timestamps.append(timestamp)
            }
        }
    }

    /// "id: en, index: 0" as ("en", 0). A bare "id:" has no language and is read as index 0's.
    private static func parseLanguageLine(_ line: String) -> (language: String?, index: Int)? {
        guard line.hasPrefix("id:") else { return nil }
        let fields = line.dropFirst("id:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let code = fields.first.flatMap { $0.isEmpty ? nil : $0 }
        let index = fields.dropFirst().first { $0.hasPrefix("index:") }
            .flatMap { Int($0.dropFirst("index:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return (code, index)
    }

    /// Extract timestamp from a line starting with "timestamp:"
    private func extractTimestamp(from line: String) -> TimeInterval? {
        guard line.starts(with: "timestamp:") else { return nil }

        // Split line by " " to get timestamp part
        let components = line.split(separator: " ")
        guard components.count > 1 else { return nil }

        let timestampString = String(components[1].dropLast())
        return convertTimestampToTimeInterval(timestampString)
    }

    /// Extract file offset from a line starting with "filepos:"
    private func extractOffset(from line: String) -> UInt64? {
        guard let fileposRange = line.range(of: "filepos:") else { return nil }

        let offsetString = line[fileposRange.upperBound...].trimmingCharacters(in: .whitespaces)
        return UInt64(offsetString, radix: 16) // Convert hex string to UInt64
    }

    /// Convert "hh:mm:ss:ms" timestamp string to TimeInterval (seconds)
    private func convertTimestampToTimeInterval(_ timestamp: String) -> TimeInterval? {
        let components = timestamp.split(separator: ":")

        guard components.count == 4,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]),
              let milliseconds = Double(components[3])
        else {
            return nil
        }

        return (hours * 3600) + (minutes * 60) + seconds + (milliseconds / 1000)
    }

    /// Function to parse the palette from the line
    private func parsePalette(line: String) -> [UInt8] {
        let paletteString = line.replacingOccurrences(of: "palette: ", with: "")
        return paletteString.split(separator: ", ").compactMap { String($0).hexToBytes }.flatMap(\.self)
    }
}
