//
// macSubtitleOCRError.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

enum macSubtitleOCRError: Error {
    case fileReadError(_ string: String)
    case fileCreationError
    case fileWriteError
    case ffmpegError(_ string: String)
    case invalidInputFile(_ string: String)
    case invalidRLE(_ string: String)
    case invalidODSDataLength(length: Int)
    case invalidPDSDataLength(length: Int)
    case invalidODSDimensions(_ string: String)
    /// The MKV track's blocks are packed (compressed or encrypted) in a way the reader can't undo.
    case unsupportedPacking(_ method: String)
}

/// Plain sentences for the errors that reach a person: the reader's own details stay in the log,
/// where `String(describing:)` still shows them.
extension macSubtitleOCRError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedPacking:
            return "These subtitles are packed in a way Driftcast can't read."
        case .fileReadError, .fileCreationError, .fileWriteError, .ffmpegError:
            return "The subtitles couldn't be read from the file."
        case .invalidInputFile, .invalidRLE, .invalidODSDataLength, .invalidPDSDataLength, .invalidODSDimensions:
            return "The subtitles are damaged or aren't in a form Driftcast can read."
        }
    }
}
