// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research

import Foundation
import XCTest
@testable import libtruehda

final class NativeMasterReaderTests: XCTestCase {
    private func externalFixture(named variable: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("Set \(variable) to run this external-fixture test")
        }
        let url = URL(fileURLWithPath: path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    func testIABPositionCodesMapST2098UnitCubeToADMCoordinates() throws {
        XCTAssertEqual(
            try IABPositionConverter.admPosition(
                iabX: 32_767, iabY: 32_767, iabZ: 0
            ),
            ADMPosition(x: -1, y: 1, z: 0)
        )
        XCTAssertEqual(
            try IABPositionConverter.admPosition(
                iabX: 49_151, iabY: 49_151, iabZ: 0
            ),
            ADMPosition(x: 0, y: 0, z: 0)
        )
        XCTAssertEqual(
            try IABPositionConverter.admPosition(
                iabX: 65_535, iabY: 65_535, iabZ: 65_535
            ),
            ADMPosition(x: 1, y: -1, z: 1)
        )
        let midpoint = try IABPositionConverter.admPosition(
            iabX: 49_151, iabY: 49_151, iabZ: 32_768
        )
        XCTAssertEqual(midpoint.z, 0.5, accuracy: 1.0 / 65_535.0)
    }

    func testIABPositionCodesRejectValuesOutsideST2098Range() {
        XCTAssertThrowsError(
            try IABPositionConverter.admPosition(
                iabX: 32_766, iabY: 32_767, iabZ: 0
            )
        )
        XCTAssertThrowsError(
            try IABPositionConverter.admPosition(
                iabX: 32_767, iabY: 65_536, iabZ: 0
            )
        )
        XCTAssertThrowsError(
            try IABPositionConverter.admPosition(
                iabX: 32_767, iabY: 32_767, iabZ: 65_536
            )
        )
    }

    func testCAFReaderDecodesLittleEndian24BitPCM() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turehda-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data("caff\u{0}\u{1}\u{0}\u{0}desc".utf8)
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 32])
        data.append(contentsOf: [
            0x40, 0xE7, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, // 48 kHz
            0x6C, 0x70, 0x63, 0x6D,                             // lpcm
            0x00, 0x00, 0x00, 0x02,                             // little-endian
            0x00, 0x00, 0x00, 0x03,                             // bytes/packet
            0x00, 0x00, 0x00, 0x01,                             // frames/packet
            0x00, 0x00, 0x00, 0x01,                             // channels
            0x00, 0x00, 0x00, 0x18                              // bits/sample
        ])
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 10])
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: [0x00, 0x00, 0x40, 0x00, 0x00, 0xC0])
        try data.write(to: url)

        let reader = try CAFFileReader(url: url)
        let block = try reader.readFrames(maxCount: 2)
        XCTAssertEqual(reader.format.isBigEndian, false)
        XCTAssertEqual(block.samples, [0x0040_0000, -0x0040_0000])
    }

    func testDAMFCAFReaderMapsPackedChannelsAndMetadata() throws {
        let url = try externalFixture(named: "SWIFT_TRUEHD_DAMF_INPUT")
        let reader = try NativeMasterReader.open(url: url)
        XCTAssertEqual(reader.format.sampleRate, 48_000)
        XCTAssertEqual(reader.admMetadata?.channels.count, reader.format.channelCount)
        XCTAssertEqual(reader.format.bitsPerSample, 24)
        XCTAssertGreaterThan(reader.frameCount, 0)
        let metadata = try XCTUnwrap(reader.admMetadata)
        XCTAssertGreaterThanOrEqual(metadata.programmeStartSeconds ?? 0, 0)
        XCTAssertEqual(Set(metadata.channels.map(\.channelFormatID)).count, reader.format.channelCount)
        XCTAssertTrue(metadata.channels.contains(where: \.isPresent))
        let block = try reader.readFrames(maxCount: 40)
        XCTAssertEqual(block.frameCount, 40)
        XCTAssertEqual(block.samples.count, 40 * reader.format.channelCount)
    }

    func testDAMFReaderPreservesSparsePhysicalChannelIDs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turehda-sparse-damf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = directory.appendingPathComponent("Sparse.atmos")
        let audioURL = directory.appendingPathComponent("Sparse.atmos.audio")
        let metadataURL = directory.appendingPathComponent("PhysicalSlots.atmos.metadata")
        let bed: [(String, Int)] = [
            ("L", 2), ("R", 0), ("C", 5), ("LFE", 1), ("Lss", 7),
            ("Rss", 4), ("Lrs", 9), ("Rrs", 3), ("Lts", 11), ("Rts", 6)
        ]
        let bedLines = bed.map { "          - channel: \($0.0)\n            ID: \($0.1)" }
            .joined(separator: "\n")
        try """
        version: 0.5.1
        presentations:
          - type: home
            audio: Sparse.atmos.audio
            metadata: PhysicalSlots.atmos.metadata
            ffoa: 0
            fps: 24
            bedInstances:
              - channels:
        \(bedLines)
            objects:
              - ID: 12
              - ID: 15
        """.write(to: manifestURL, atomically: true, encoding: .utf8)
        try """
        sampleRate: 48000
        events:
          - ID: 12
            samplePos: 0
            active: true
            pos: [-0.5, 0.75, 0.25]
          - ID: 15
            samplePos: 0
            active: true
            pos: [0.5, -0.75, 0.5]
          - ID: 12
            samplePos: 32
            pos: [-0.25, 0.25, 0.75]
          - ID: 15
            pos: [0.25, -0.25, 0.75]
        """.write(to: metadataURL, atomically: true, encoding: .utf8)

        var caf = Data("caff\u{0}\u{1}\u{0}\u{0}desc".utf8)
        caf.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 32])
        caf.append(contentsOf: [
            0x40, 0xE7, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x6C, 0x70, 0x63, 0x6D,
            0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x30,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x10,
            0x00, 0x00, 0x00, 0x18
        ])
        caf.append("data".data(using: .ascii)!)
        caf.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 52])
        caf.append(contentsOf: [0, 0, 0, 0])
        var frame = [UInt8](repeating: 0, count: 48)
        frame[12 * 3] = 0x34
        frame[12 * 3 + 1] = 0x12
        caf.append(contentsOf: frame)
        try caf.write(to: audioURL)

        let reader = try NativeMasterReader.open(url: manifestURL)
        let metadata = try XCTUnwrap(reader.admMetadata)
        XCTAssertEqual(reader.format.channelCount, 16)
        XCTAssertEqual(metadata.channels.count, 16)
        XCTAssertEqual(metadata.channels[2].channelFormatID, "AC_00011001")
        XCTAssertTrue(metadata.channels[12].isObject)
        XCTAssertTrue(metadata.channels[12].isPresent)
        XCTAssertFalse(metadata.channels[13].isPresent)
        XCTAssertTrue(metadata.channels[15].isObject)
        XCTAssertEqual(metadata.channels[15].position(at: 0), ADMPosition(x: 0.5, y: -0.75, z: 0.5))
        XCTAssertEqual(
            metadata.channels[15].position(at: 16),
            ADMPosition(x: 0.5, y: -0.75, z: 0.5),
            "A zero-ramp DAMF event must hold until the next position event"
        )
        XCTAssertEqual(
            metadata.channels[15].position(at: 32),
            ADMPosition(x: 0.25, y: -0.25, z: 0.75)
        )
        let block = try reader.readFrames(maxCount: 1)
        XCTAssertEqual(block.samples[12], 0x1234)
        XCTAssertEqual(block.samples[13], 0)
    }

    func testDAMFReaderMapsPackedPersistentIDsBeyondCAFChannelCount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turehda-packed-damf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = directory.appendingPathComponent("Packed.atmos")
        let audioURL = directory.appendingPathComponent("Packed.atmos.audio")
        let metadataURL = directory.appendingPathComponent("Packed.atmos.metadata")
        let bedLabels = ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs", "Lts", "Rts"]
        let bedLines = bedLabels.enumerated().map {
            "          - channel: \($0.element)\n            ID: \($0.offset)"
        }.joined(separator: "\n")
        try """
        version: 0.5.1
        presentations:
          - type: home
            audio: Packed.atmos.audio
            metadata: Packed.atmos.metadata
            ffoa: 0
            fps: 24
            bedInstances:
              - channels:
        \(bedLines)
            objects:
              - ID: 84
              - ID: 101
        """.write(to: manifestURL, atomically: true, encoding: .utf8)
        try """
        sampleRate: 48000
        events:
          - ID: 84
            samplePos: 0
            active: true
            pos: [-0.5, 0.75, 0.25]
            size: 0.25
          - ID: 101
            samplePos: 0
            active: true
            pos: [0.5, -0.75, 0.5]
          - ID: 84
            samplePos: 1
            pos: [-0.5, 0.75, 0.25]
          - ID: 84
            samplePos: 2
            size: 0.5
        """.write(to: metadataURL, atomically: true, encoding: .utf8)

        var caf = Data("caff\u{0}\u{1}\u{0}\u{0}desc".utf8)
        caf.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 32])
        caf.append(contentsOf: [
            0x40, 0xE7, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x6C, 0x70, 0x63, 0x6D,
            0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x24,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x0C,
            0x00, 0x00, 0x00, 0x18
        ])
        caf.append("data".data(using: .ascii)!)
        caf.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 40])
        caf.append(contentsOf: [0, 0, 0, 0])
        var frame = [UInt8](repeating: 0, count: 36)
        frame[10 * 3] = 0x34
        frame[10 * 3 + 1] = 0x12
        frame[11 * 3] = 0x78
        frame[11 * 3 + 1] = 0x56
        caf.append(contentsOf: frame)
        try caf.write(to: audioURL)

        let reader = try NativeMasterReader.open(url: manifestURL)
        let metadata = try XCTUnwrap(reader.admMetadata)
        XCTAssertEqual(reader.format.channelCount, 12)
        XCTAssertEqual(metadata.channels.count, 12)
        XCTAssertTrue(metadata.channels[10].isObject)
        XCTAssertEqual(metadata.channels[10].channelFormatID, "AC_00030055")
        XCTAssertEqual(metadata.channels[10].position(at: 0), ADMPosition(x: -0.5, y: 0.75, z: 0.25))
        XCTAssertEqual(metadata.channels[10].spread(at: 0), 0.25)
        XCTAssertEqual(metadata.channels[10].spread(at: 1), 0.25)
        XCTAssertEqual(metadata.channels[10].spread(at: 2), 0.5)
        XCTAssertEqual(metadata.channels[10].position(at: 2), ADMPosition(x: -0.5, y: 0.75, z: 0.25))
        XCTAssertTrue(metadata.channels[11].isObject)
        XCTAssertEqual(metadata.channels[11].channelFormatID, "AC_00030066")
        XCTAssertEqual(metadata.channels[11].position(at: 0), ADMPosition(x: 0.5, y: -0.75, z: 0.5))
        let block = try reader.readFrames(maxCount: 1)
        XCTAssertEqual(block.samples[10], 0x1234)
        XCTAssertEqual(block.samples[11], 0x5678)
    }

    func testIABSpreadModesPreserveFollowingPanSubBlocks() throws {
        func plex(_ value: Int) -> [UInt8] {
            value < 255 ? [UInt8(value)] : [255, UInt8(value >> 8), UInt8(value & 255)]
        }
        func element(_ id: Int, _ payload: [UInt8]) -> [UInt8] {
            plex(id) + plex(payload.count) + payload
        }
        var object = BitWriter()
        object.write(1, count: 8) // Metadata ID.
        object.write(1, count: 8) // Audio data ID.
        object.write(0, count: 1) // Unconditional object.
        object.write(0, count: 1)
        for block in 0..<8 {
            if block > 0 { object.write(block < 3 ? 1 : 0, count: 1) }
            guard block < 3 else { continue }
            object.write(0, count: 2) // Unity gain.
            object.write(1, count: 3) // Required reserved value.
            object.write(block == 2 ? 57_343 : 49_151, count: 16)
            object.write(49_151, count: 16)
            object.write(32_768, count: 16)
            object.write(0, count: 1) // No snap.
            object.write(0, count: 1) // No zone gains.
            object.write(UInt64(block), count: 2)
            if block == 0 { object.write(127, count: 8) }
            if block == 2 { object.write(1_024, count: 12) }
            object.write(0, count: 4)
            object.write(2, count: 2) // Explicit decorrelation follows.
            object.write(64, count: 8)
        }
        var pcm = [UInt8](repeating: 0, count: 6_001)
        pcm[0] = 1
        pcm[1] = 0x39
        pcm[2] = 0x30
        let payload = [UInt8(1), 0x10, 16, 2]
            + element(0x40, object.paddedBytes() + [0, 0]) + element(0x400, pcm)
        let ia = element(8, payload)
        func u32(_ value: Int) -> [UInt8] {
            [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
             UInt8((value >> 8) & 255), UInt8(value & 255)]
        }
        let frame = [UInt8(1), 0, 0, 0, 0, 2] + u32(ia.count) + ia
        let key: [UInt8] = [0x06,0x0E,0x2B,0x34,0x01,0x02,0x01,0x01,
                            0x0D,0x01,0x03,0x01,0x16,0x01,0x0D,0x01]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turehda-iab-spread-\(UUID().uuidString).mxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(key + [0x84] + u32(frame.count) + frame).write(to: url)
        let reader = try NativeMasterReader.open(url: url)
        let channel = try XCTUnwrap(reader.admMetadata).channels[10]
        XCTAssertEqual(channel.spread(at: 0), 127.0 / 255, accuracy: 0.000_001)
        XCTAssertEqual(channel.spread(at: 250), 0)
        XCTAssertEqual(channel.spread(at: 500), 1_024.0 / 4_095, accuracy: 0.000_001)
        XCTAssertEqual(channel.position(at: 500).x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try reader.readFrames(maxCount: 1).samples[10], 12_345)
    }

    func testMXFIABReaderIndexesFramesAndReadsPCM() throws {
        let url = try externalFixture(named: "SWIFT_TRUEHD_IAB_INPUT")
        let reader = try NativeMasterReader.open(url: url)
        XCTAssertEqual(reader.sourceFrameRate, .fps24)
        XCTAssertEqual(reader.format.sampleRate, 48_000)
        XCTAssertEqual(reader.format.channelCount, 128)
        XCTAssertGreaterThan(reader.frameCount, 0)
        XCTAssertEqual(reader.admMetadata?.channels.count, 128)
        let iabChannels = try XCTUnwrap(reader.admMetadata).channels
        let definedObjects = iabChannels.enumerated().filter {
            $0.element.isObject && !$0.element.blocks.isEmpty
        }
        XCTAssertGreaterThan(definedObjects.count, 0)
        let block = try reader.readFrames(maxCount: 2_000)
        var peaks = [Int32](repeating: 0, count: 128)
        for frame in 0..<block.frameCount {
            for channel in 0..<128 {
                peaks[channel] = max(peaks[channel], abs(block.samples[frame * 128 + channel]))
            }
        }
        XCTAssertEqual(block.frameCount, 2_000)
        XCTAssertEqual(block.samples.count, 2_000 * 128)
        let activeSources = peaks.enumerated().filter { $0.element > 0 }.map(\.offset)
        XCTAssertFalse(activeSources.isEmpty)

        let coder = try AtmosSpatialCoder(
            metadata: try XCTUnwrap(reader.admMetadata),
            sourceChannelCount: 128,
            elementBitDepth: 20
        )
        let encoded = coder.encode(
            source: block.samples,
            frameCount: block.frameCount,
            sourceStartFrame: 0
        )
        let activeElements = (0..<16).filter { element in
            (0..<block.frameCount).contains { frame in
                encoded.samples[frame * 16 + element] != 0
            }
        }
        XCTAssertEqual(encoded.samples.count, block.frameCount * 16)
        XCTAssertFalse(activeElements.isEmpty)
    }
}
