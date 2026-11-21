//
// EBML.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

enum EBML {
    static let attachments: UInt32 = 0x1941_A469
    static let block: UInt32 = 0xA1
    static let blockGroup: UInt32 = 0xA0
    static let chapters: UInt32 = 0x1043_A770
    static let cluster: UInt32 = 0x1F43_B675
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompression: UInt32 = 0x5034
    static let contentCompSettings: UInt32 = 0x4255
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingOrder: UInt32 = 0x5031
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentEncryption: UInt32 = 0x5035
    static let cues: UInt32 = 0x1C53_BB6B
    static let ebmlHeader: UInt32 = 0x1A45_DFA3
    static let info: UInt32 = 0x1549_A966
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let seekHead: UInt32 = 0x114D_9B74
    static let segmentID: UInt32 = 0x1853_8067
    static let simpleBlock: UInt32 = 0xA3
    static let tags: UInt32 = 0x1254_C367
    static let timestamp: UInt32 = 0xE7
    static let timestampScale: UInt32 = 0x2A_D7B1
    static let tracksID: UInt32 = 0x1654_AE6B
    static let trackEntryID: UInt32 = 0xAE
    static let trackTypeID: UInt32 = 0x83
    static let trackNumberID: UInt32 = 0xD7

    /// Elements that only ever sit directly in the Segment. Inside a Cluster of unknown size, meeting
    /// one of these is how the Cluster is known to have ended.
    static let topLevel: Set<UInt32> = [attachments, chapters, cluster, cues, ebmlHeader, info, seekHead,
                                        segmentID, tags, tracksID]
}
