//
// MKVFileHandler.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/12/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

/// Walks the elements of a Matroska file without reading more of it than it has to.
///
/// Every element is bounded twice: by the parent it sits in and by the end of the file. A file that
/// is still being copied, or was cut short, therefore ends the walk where its data ends instead of
/// sending it round the same spot forever, and reads go through the throwing FileHandle calls so a
/// drive that goes away mid-read is an error rather than an Objective-C exception that ends the app.
class MKVFileHandler {
    // MARK: - Properties

    let fileHandle: FileHandle
    let endOfFile: UInt64
    let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "MKV")

    /// Where the next read starts.
    private(set) var position: UInt64 = 0

    /// Bytes read ahead for small reads. A film's audio comes in hundreds of thousands of small blocks,
    /// and reading each one's header with calls of its own spent most of the walk in the kernel.
    private var readAhead = Data()
    private var readAheadStart: UInt64 = 0
    private static let readAheadSize = 64 * 1024

    /// One element: where its data starts and ends. `end` is clamped to the parent and the file,
    /// so an element claiming more than is there covers only what is.
    struct Element {
        let id: UInt32
        let headerStart: UInt64
        let start: UInt64
        let end: UInt64
        let sizeKnown: Bool
    }

    // MARK: - Lifecycle

    init(filePath: String) throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw macSubtitleOCRError.fileReadError("File does not exist at path: \(filePath)")
        }
        do {
            fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
            endOfFile = try fileHandle.seekToEnd()
        } catch {
            throw macSubtitleOCRError.fileReadError("Failed to open file: \(filePath)")
        }
    }

    deinit {
        try? fileHandle.close()
    }

    // MARK: - Functions

    func seek(to offset: UInt64) {
        position = min(offset, endOfFile)
    }

    /// Up to `count` bytes from the current position, fewer at the end of the file.
    func read(_ count: Int) throws -> Data {
        guard count > 0, position < endOfFile else { return Data() }
        let wanted = min(count, Int(clamping: endOfFile - position))
        let data: Data
        if wanted <= 4096 {
            let aheadEnd = readAheadStart + UInt64(readAhead.count)
            if position < readAheadStart || position + UInt64(wanted) > aheadEnd {
                try fileHandle.seek(toOffset: position)
                readAhead = try fileHandle.read(upToCount: Self.readAheadSize) ?? Data()
                readAheadStart = position
            }
            let from = Int(position - readAheadStart)
            data = readAhead.subdata(in: from ..< min(from + wanted, readAhead.count))
        } else {
            try fileHandle.seek(toOffset: position)
            data = try fileHandle.read(upToCount: wanted) ?? Data()
        }
        position += UInt64(data.count)
        return data
    }

    /// The bytes of an element's data, or nil if it is larger than `limit` (damage, or nothing a
    /// subtitle reader needs to hold in memory).
    func readData(of element: Element, limit: Int) throws -> Data? {
        let length = element.end - element.start
        guard length <= UInt64(limit) else { return nil }
        seek(to: element.start)
        return try read(Int(length))
    }

    /// The element whose header starts at the current position, if a whole header fits before `limit`.
    /// Leaves the position at the start of its data.
    func nextElement(before limit: UInt64) throws -> Element? {
        let headerStart = position
        let bound = min(limit, endOfFile)
        guard headerStart < bound else { return nil }
        let bytes = try read(Int(min(UInt64(EBMLParser.maximumHeaderLength), bound - headerStart)))
        guard let header = EBMLParser.readHeader(bytes) else {
            seek(to: headerStart)
            return nil
        }
        let start = headerStart + UInt64(header.length)
        guard start <= bound else {
            seek(to: headerStart)
            return nil
        }
        let end: UInt64
        if let size = header.size {
            let (sum, overflow) = start.addingReportingOverflow(size)
            end = overflow ? bound : min(sum, bound)
        } else {
            end = bound
        }
        seek(to: start)
        return Element(id: header.id, headerStart: headerStart, start: start, end: end, sizeKnown: header.size != nil)
    }
}
