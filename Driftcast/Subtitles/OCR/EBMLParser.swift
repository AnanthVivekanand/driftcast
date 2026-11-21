//
// EBMLParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

/// Reads EBML's variable-length numbers out of bytes already in memory.
///
/// Nothing here trusts the bytes. A file cut short, or a region of it that is damaged, used to send
/// the reader round the same element forever or trap on a conversion; every read is now checked and
/// answers nil instead, and the caller stops at the first element it can't make sense of.
enum EBMLParser {
    /// An element's header: its ID, the size of its data (nil when the muxer wrote "unknown", as a
    /// recording or a pipe does for the Segment and its Clusters), and how many bytes the header took.
    struct Header {
        let id: UInt32
        let size: UInt64?
        let length: Int
    }

    /// The longest header there can be: a 4 byte ID and an 8 byte size.
    static let maximumHeaderLength = 12

    /// A variable-length integer at `index`, with its length marker kept (IDs) or removed (sizes and
    /// numbers). Nil when the bytes run out or the first byte is zero, which no valid number starts with.
    static func readVINT(_ bytes: Data, at index: Int, keepMarker: Bool) -> (value: UInt64, length: Int)? {
        guard index >= 0, index < bytes.count else { return nil }
        let first = bytes[bytes.startIndex + index]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard index + length <= bytes.count else { return nil }
        var value = UInt64(keepMarker ? first : first & (0xFF >> length))
        for offset in 1 ..< length {
            value = value << 8 | UInt64(bytes[bytes.startIndex + index + offset])
        }
        return (value, length)
    }

    /// The element header at the start of `bytes`, or nil if they don't hold a whole one.
    /// IDs are at most 4 bytes long; anything longer is damage, not an element.
    static func readHeader(_ bytes: Data) -> Header? {
        guard let (id, idLength) = readVINT(bytes, at: 0, keepMarker: true), idLength <= 4,
              let (size, sizeLength) = readVINT(bytes, at: idLength, keepMarker: false)
        else { return nil }
        // All data bits set means the size is unknown.
        let unknown = size == (UInt64(1) << (7 * UInt64(sizeLength))) - 1
        return Header(id: UInt32(truncatingIfNeeded: id), size: unknown ? nil : size, length: idLength + sizeLength)
    }

    /// The elements directly inside `bytes` (a parent's data), in order. Stops at the first header that
    /// doesn't fit or leaves its size open; an element claiming more than is left gets what is left.
    static func children(_ bytes: Data) -> [(id: UInt32, data: Data)] {
        let bytes = Data(bytes)
        var found: [(id: UInt32, data: Data)] = []
        var index = 0
        while index < bytes.count,
              let header = readHeader(bytes.subdata(in: index ..< min(index + maximumHeaderLength, bytes.count))),
              let size = header.size {
            let start = index + header.length
            guard start <= bytes.count else { break }
            let end = start + Int(min(size, UInt64(bytes.count - start)))
            found.append((header.id, bytes.subdata(in: start ..< end)))
            index = end
        }
        return found
    }

    /// An unsigned integer element's value. EBML allows up to 8 bytes; more is damage.
    static func readUnsigned(_ bytes: Data) -> UInt64? {
        guard bytes.count <= 8 else { return nil }
        return bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
