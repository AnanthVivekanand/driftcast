//
// MKVHelpers.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import zlib

/// Encode the absolute timestamp as 4 bytes in big-endian format for PGS.
/// PGS has only 32 bits of 90 kHz time (13 h 15 min); anything later is held at the last value.
func encodePTSForPGS(_ timestamp: UInt64) -> [UInt8] {
    withUnsafeBytes(of: UInt32(clamping: timestamp).bigEndian) { Array($0) }
}

func encodePTSForVobSub(from timestamp: UInt64) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: 5) // 5-byte buffer

    buffer[0] = (buffer[0] & 0xF1) | UInt8((timestamp >> 29) & 0x0E)
    buffer[1] = UInt8((timestamp >> 22) & 0xFF)
    buffer[2] = UInt8(((timestamp >> 14) & 0xFE) | 1)
    buffer[3] = UInt8((timestamp >> 7) & 0xFF)
    buffer[4] = UInt8((timestamp << 1) & 0xFF)
    return buffer
}

/// A 90 kHz time written the way a VobSub index writes one, `hh:mm:ss:mmm`.
func vobSubIndexTime(_ time: UInt64) -> String {
    let milliseconds = time / 90
    return String(format: "%02llu:%02llu:%02llu:%03llu", milliseconds / 3_600_000, milliseconds / 60000 % 60,
                  milliseconds / 1000 % 60, milliseconds % 1000)
}

/// The 90 kHz time of a block: its cluster's time plus the block's own offset, which is signed. A
/// muxer that stamps each cluster with a video keyframe's time gives a subtitle sorted just after that
/// frame a small negative offset; read as unsigned it put the cue 65.5 seconds late.
/// `timestampScale` is the file's tick in nanoseconds (a millisecond unless the file says otherwise).
/// Times before the start of the file are held at zero.
func absolutePTS(cluster: UInt64, block: Int16, timestampScale: UInt64) -> UInt64 {
    let ticks = Double(cluster) + Double(block)
    let pts = ticks * Double(timestampScale) * 90000 / 1_000_000_000
    guard pts.isFinite, pts > 0 else { return 0 }
    // 2^40 ticks of 90 kHz is over 140 days, past anything PGS or VobSub can carry anyway.
    return UInt64(min(pts.rounded(), Double(1 << 40)))
}

/// Inflates a zlib stream, the way Matroska stores a compressed block (mkvmerge's default for picture
/// subtitles). A stream without the two byte zlib header is read as raw DEFLATE. `limit` caps the
/// inflated size, so a damaged or hostile block can't fill memory.
func zlibInflate(_ input: Data, limit: Int) throws -> Data {
    guard !input.isEmpty else { return Data() }
    let first = input[input.startIndex]
    let second = input.count > 1 ? input[input.startIndex + 1] : 0
    let hasHeader = first & 0x0F == 8 && (UInt16(first) << 8 | UInt16(second)) % 31 == 0

    var stream = z_stream()
    guard inflateInit2_(&stream, hasHeader ? MAX_WBITS : -MAX_WBITS, ZLIB_VERSION,
                        Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else {
        throw macSubtitleOCRError.invalidInputFile("The subtitle's compressed data couldn't be unpacked.")
    }
    defer { inflateEnd(&stream) }

    var output = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    let status: Int32 = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(clamping: raw.count)
        var status = Z_OK
        // inflate answers Z_OK only while it makes progress, so this ends: at the stream's end, at
        // damage, or with Z_BUF_ERROR once the input runs out short of the end.
        repeat {
            status = chunk.withUnsafeMutableBufferPointer { buffer in
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            output.append(contentsOf: chunk[0 ..< chunk.count - Int(stream.avail_out)])
            guard output.count <= limit else {
                throw macSubtitleOCRError.invalidInputFile("A compressed subtitle block unpacks to more than \(limit) bytes.")
            }
        } while status == Z_OK
        return status
    }
    guard status == Z_STREAM_END else {
        throw macSubtitleOCRError.invalidInputFile("A compressed subtitle block is damaged (zlib status \(status)).")
    }
    return output
}
