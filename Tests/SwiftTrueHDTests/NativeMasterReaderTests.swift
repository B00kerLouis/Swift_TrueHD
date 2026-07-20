// SPDX-License-Identifier: AGPL-3.0-only

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
