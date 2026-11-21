//
// ODS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

/// One PGS object (a subtitle picture), possibly sent in several fragments.
struct ODS {
    // MARK: - Properties

    private(set) var objectWidth: Int = 0
    private(set) var objectHeight: Int = 0
    /// Set by the fragment that carries the "last in sequence" flag.
    private(set) var isComplete = false
    private var encodedImageData: Data = .init()

    // MARK: - Lifecycle

    // ODS structure (simplified), from the segment's data:
    //   2 bytes: Object ID (read by the caller)
    //   1 byte: Version number (unused by us)
    //   1 byte: Sequence flag (0x80: first fragment, 0x40: last fragment; both in a one-fragment object)
    //   First fragment only:
    //     3 bytes: Object data length (unused by us)
    //     2 bytes: Object width
    //     2 bytes: Object height
    //   Rest: Image data (run-length encoded, RLE)

    /// The first fragment of an object.
    init(_ buffer: UnsafeRawBufferPointer, _ offset: Int, _ segmentLength: Int) throws {
        guard segmentLength >= 11, offset >= 0, offset + segmentLength <= buffer.count else {
            throw macSubtitleOCRError.invalidODSDataLength(length: segmentLength)
        }
        objectWidth = Int(buffer[offset + 7]) << 8 | Int(buffer[offset + 8])
        objectHeight = Int(buffer[offset + 9]) << 8 | Int(buffer[offset + 10])
        encodedImageData.append(contentsOf: buffer[(offset + 11) ..< (offset + segmentLength)])
        isComplete = buffer[offset + 3] & 0x40 != 0
    }

    /// A later fragment of the same object. Only the first carries a size; a middle fragment (flag
    /// 0x00) used to be read as a first one, its image bytes taken for a width and height.
    mutating func appendSegment(_ buffer: UnsafeRawBufferPointer, _ offset: Int, _ segmentLength: Int) throws {
        guard segmentLength >= 4, offset >= 0, offset + segmentLength <= buffer.count else {
            throw macSubtitleOCRError.invalidODSDataLength(length: segmentLength)
        }
        encodedImageData.append(contentsOf: buffer[(offset + 4) ..< (offset + segmentLength)])
        if buffer[offset + 3] & 0x40 != 0 {
            isComplete = true
        }
    }

    /// Decodes the run-length encoded (RLE) image data
    func decodeRLEData() throws -> Data {
        let rleImageData = RLEData(data: encodedImageData, width: objectWidth, height: objectHeight)
        return try rleImageData.decodePGS()
    }
}
