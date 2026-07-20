// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import libtruehda

final class ADMAndAtmosMetadataTests: XCTestCase {
    func testCompleteNativeEvolutionAuditIfRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFT_TRUEHD_AUDIT_MLP"] else {
            throw XCTSkip("Set SWIFT_TRUEHD_AUDIT_MLP to audit every Evolution frame")
        }
        let file = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        var fileOffset = 0
        var accessUnitCount = 0
        var evolutionCount = 0

        while fileOffset < file.count {
            guard fileOffset + 4 <= file.count else {
                XCTFail("Truncated access-unit header at byte \(fileOffset)")
                return
            }
            let lengthInWords = (Int(file[fileOffset] & 0x0F) << 8)
                | Int(file[fileOffset + 1])
            let accessUnitByteCount = lengthInWords * 2
            guard accessUnitByteCount >= 4,
                  fileOffset + accessUnitByteCount <= file.count else {
                XCTFail("Invalid access-unit length at index \(accessUnitCount)")
                return
            }
            let accessUnit = Array(
                file[fileOffset..<(fileOffset + accessUnitByteCount)]
            )
            let hasMajorSync = accessUnit.count >= 36
                && accessUnit[4..<8].elementsEqual([0xF8, 0x72, 0x6F, 0xBA])
            let directoryOffset = hasMajorSync ? 36 : 4
            var directoryEnd = directoryOffset
            var finalSubstreamEnd = 0
            for substream in 0..<4 {
                guard directoryEnd + 1 < accessUnit.count else {
                    XCTFail("Truncated substream directory at AU \(accessUnitCount)")
                    return
                }
                let entry = (UInt16(accessUnit[directoryEnd]) << 8)
                    | UInt16(accessUnit[directoryEnd + 1])
                if substream == 3 { finalSubstreamEnd = Int(entry & 0x0FFF) * 2 }
                directoryEnd += entry & 0x8000 == 0 ? 2 : 4
            }

            var accessParity = UInt16(accessUnit[2]) << 8 | UInt16(accessUnit[3])
            accessParity ^= UInt16(lengthInWords)
            for byte in accessUnit[directoryOffset..<directoryEnd] {
                accessParity ^= UInt16(byte)
            }
            accessParity ^= accessParity >> 8
            accessParity ^= accessParity >> 4
            XCTAssertEqual(
                UInt16(accessUnit[0] >> 4),
                (accessParity & 0x0F) ^ 0x0F,
                "Access parity at AU \(accessUnitCount)"
            )

            let extraOffset = directoryEnd + finalSubstreamEnd
            if extraOffset < accessUnit.count {
                guard extraOffset + 5 <= accessUnit.count else {
                    XCTFail("Truncated wrapped Evolution data at AU \(accessUnitCount)")
                    return
                }
                let extraWords = (Int(accessUnit[extraOffset] & 0x0F) << 8)
                    | Int(accessUnit[extraOffset + 1])
                XCTAssertEqual(
                    extraOffset + 2 + extraWords * 2,
                    accessUnit.count,
                    "Extra-data length at AU \(accessUnitCount)"
                )
                var headerParity = accessUnit[extraOffset] ^ accessUnit[extraOffset + 1]
                headerParity ^= headerParity >> 4
                XCTAssertEqual(headerParity & 0x0F, 0x0F)
                let parityIndex = accessUnit.count - 1
                XCTAssertEqual(
                    accessUnit[(extraOffset + 2)..<parityIndex].reduce(UInt8(0), ^) ^ 0xA9,
                    accessUnit[parityIndex],
                    "Evolution parity at AU \(accessUnitCount)"
                )

                let evolutionLength = (Int(accessUnit[extraOffset + 2] & 0x0F) << 8)
                    | Int(accessUnit[extraOffset + 3])
                var canonicalEvolution = Array(
                    accessUnit[(extraOffset + 4)..<(extraOffset + 4 + evolutionLength)]
                )
                var evolution = TestBitReader(canonicalEvolution)
                evolution.skip(33)
                var oamdLength = 0
                while true {
                    let group = Int(evolution.read(8))
                    let continues = evolution.read(1) != 0
                    oamdLength += group
                    if !continues { break }
                    oamdLength = (oamdLength + 1) << 8
                }
                evolution.skip(oamdLength * 8)
                XCTAssertEqual(evolution.read(5), 0)
                XCTAssertEqual(evolution.read(2), 1)
                XCTAssertEqual(evolution.read(2), 0)
                let protectionOffset = evolution.position
                let protection = UInt8(evolution.read(8))
                for bit in protectionOffset..<(protectionOffset + 8) {
                    canonicalEvolution[bit / 8] &= ~(1 << UInt8(7 - bit % 8))
                }
                XCTAssertEqual(
                    AtmosMetadataWriter.primaryProtection(
                        accessUnitPrefix: Array(accessUnit[..<extraOffset]),
                        canonicalEvolution: canonicalEvolution
                    ),
                    protection,
                    "Evolution HMAC at AU \(accessUnitCount)"
                )
                evolutionCount += 1
            }

            fileOffset += accessUnitByteCount
            accessUnitCount += 1
        }
        XCTAssertEqual(fileOffset, file.count)
        XCTAssertEqual(accessUnitCount, 111_700)
        XCTAssertEqual(evolutionCount, 2_909)
    }

    func testADMChannelAssignmentAndCartesianPosition() throws {
        let xml = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <audioFormatExtended>
              <audioChannelFormat audioChannelFormatID="AC_00031001" typeDefinition="Objects">
                <audioBlockFormat audioBlockFormatID="AB_00031001_00000001"
                                  rtime="00:00:00.50000" duration="00:00:01.00000">
                  <cartesian>1</cartesian>
                  <position coordinate="X">-0.5</position>
                  <position coordinate="Y">0.75</position>
                  <position coordinate="Z">0.25</position>
                </audioBlockFormat>
              </audioChannelFormat>
            </audioFormatExtended>
            """.utf8
        )
        var chna = [UInt8](repeating: 0, count: 44)
        chna[0] = 1
        chna[2] = 1
        chna[4] = 1
        writeASCII("ATU_00000001", into: &chna, at: 6, length: 12)
        writeASCII("AT_00031001_01", into: &chna, at: 18, length: 14)
        writeASCII("AP_00031001", into: &chna, at: 32, length: 11)

        let metadata = try ADMMetadata.parse(
            xml: xml,
            channelAssignment: Data(chna),
            channelCount: 1,
            sampleRate: 48_000
        )
        XCTAssertEqual(metadata.channels[0].channelFormatID, "AC_00031001")
        XCTAssertTrue(metadata.channels[0].isObject)
        XCTAssertEqual(metadata.channels[0].blocks[0].startFrame, 24_000)
        XCTAssertEqual(
            metadata.channels[0].position(at: 24_000),
            ADMPosition(x: -0.5, y: 0.75, z: 0.25)
        )
    }

    func testAtmosExtraDataLengthsAndParity() {
        let positions = AtmosSpatialCoder.fixedElementPositions
            + Array(repeating: ADMPosition.centre, count: 8)
        let oamdByteCount = AtmosMetadataWriter.makeOAMDPayload(positions: positions).count
        let bytes = AtmosMetadataWriter.makeExtraData(positions: positions)

        XCTAssertEqual(bytes.count & 1, 0)
        let lengthInWords = (Int(bytes[0] & 0x0F) << 8) | Int(bytes[1])
        XCTAssertEqual(lengthInWords * 2, bytes.count - 2)

        var headerParity = bytes[0] ^ bytes[1]
        headerParity ^= headerParity >> 4
        XCTAssertEqual(headerParity & 0x0F, 0x0F)

        let protected = bytes[2..<(bytes.count - 1)]
        XCTAssertEqual(protected.reduce(UInt8(0), ^) ^ 0xA9, bytes.last)
        let evolutionLength = (Int(bytes[2] & 0x0F) << 8) | Int(bytes[3])
        XCTAssertGreaterThan(evolutionLength, 0)
        XCTAssertLessThanOrEqual(evolutionLength, bytes.count - 5)

        var evolution = TestBitReader(Array(bytes.dropFirst(4)))
        XCTAssertEqual(evolution.read(2), 0)
        XCTAssertEqual(evolution.read(3), 0)
        XCTAssertEqual(evolution.read(5), 11)
        XCTAssertEqual(evolution.read(1), 0)
        XCTAssertEqual(evolution.read(1), 0)
        XCTAssertEqual(evolution.read(1), 0)
        XCTAssertEqual(evolution.read(1), 1)
        XCTAssertEqual(evolution.read(8), 8)
        XCTAssertEqual(evolution.read(1), 0)
        XCTAssertEqual(evolution.read(1), 1)
        XCTAssertEqual(evolution.read(1), 0)
        XCTAssertEqual(evolution.read(1), 0)
        XCTAssertEqual(evolution.read(5), 0)
        XCTAssertEqual(evolution.read(2), 0)
        XCTAssertEqual(evolution.read(8), UInt64(oamdByteCount))
        XCTAssertEqual(evolution.read(1), 0)
        evolution.skip(oamdByteCount * 8)
        XCTAssertEqual(evolution.read(5), 0)
        XCTAssertEqual(evolution.read(2), 1)
        XCTAssertEqual(evolution.read(2), 0)
        _ = evolution.read(8)
    }

    func testEvolutionPrimaryProtectionMatchesHMACSHA256Vector() {
        let accessUnitPrefix: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0xFE, 0xDC]
        let canonicalEvolution: [UInt8] = [
            0x02, 0xC4, 0x21, 0x00, 0x20, 0x87,
            0xE1, 0x12, 0xE0, 0x00, 0x00, 0x00,
        ]

        XCTAssertEqual(
            AtmosMetadataWriter.primaryProtection(
                accessUnitPrefix: accessUnitPrefix,
                canonicalEvolution: canonicalEvolution
            ),
            0x3E
        )
    }

    func testWrappedEvolutionCanBeReauthenticatedAfterPrefixRewrite() {
        let positions = AtmosSpatialCoder.fixedElementPositions
            + Array(repeating: ADMPosition.centre, count: 8)
        let original = AtmosMetadataWriter.makeExtraData(
            positions: positions, accessUnitPrefix: [0x10, 0x20]
        )
        let updated = AtmosMetadataWriter.reauthenticateWrappedEvolution(
            original, accessUnitPrefix: [0x10, 0x21]
        )

        XCTAssertNotEqual(updated, original)
        XCTAssertEqual(
            updated[2..<(updated.count - 1)].reduce(UInt8(0), ^) ^ 0xA9,
            updated.last
        )

        let evolutionLength = (Int(updated[2] & 0x0F) << 8) | Int(updated[3])
        var canonicalEvolution = Array(updated[4..<(4 + evolutionLength)])
        var evolution = TestBitReader(canonicalEvolution)
        evolution.skip(33)
        let oamdLength = Int(evolution.read(8))
        XCTAssertEqual(evolution.read(1), 0)
        evolution.skip(oamdLength * 8 + 5)
        XCTAssertEqual(evolution.read(2), 1)
        XCTAssertEqual(evolution.read(2), 0)
        let protectionOffset = evolution.position
        let protection = UInt8(evolution.read(8))
        for bit in protectionOffset..<(protectionOffset + 8) {
            canonicalEvolution[bit / 8] &= ~(1 << UInt8(7 - bit % 8))
        }
        XCTAssertEqual(
            AtmosMetadataWriter.primaryProtection(
                accessUnitPrefix: [0x10, 0x21],
                canonicalEvolution: canonicalEvolution
            ),
            protection
        )
    }

    func testEvolutionPrimaryProtectionMatchesOfficialDolbyStreamIfAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFT_TRUEHD_OFFICIAL_MLP"] else {
            throw XCTSkip("Set SWIFT_TRUEHD_OFFICIAL_MLP to validate against a Dolby stream")
        }
        let file = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let accessUnitLength = ((Int(file[0] & 0x0F) << 8) | Int(file[1])) * 2
        let accessUnit = Array(file.prefix(accessUnitLength))
        XCTAssertEqual(Array(accessUnit[4..<8]), [0xF8, 0x72, 0x6F, 0xBA])

        let directoryOffset = 4 + 32
        let directoryEntrySize = 4
        let finalEntryOffset = directoryOffset + 3 * directoryEntrySize
        let finalEntry = (UInt16(accessUnit[finalEntryOffset]) << 8)
            | UInt16(accessUnit[finalEntryOffset + 1])
        let extraOffset = directoryOffset + 4 * directoryEntrySize
            + Int(finalEntry & 0x0FFF) * 2
        let evolutionLength = (Int(accessUnit[extraOffset + 2] & 0x0F) << 8)
            | Int(accessUnit[extraOffset + 3])
        var canonicalEvolution = Array(
            accessUnit[(extraOffset + 4)..<(extraOffset + 4 + evolutionLength)]
        )

        var evolution = TestBitReader(canonicalEvolution)
        evolution.skip(33)
        let oamdLength = Int(evolution.read(8))
        XCTAssertEqual(evolution.read(1), 0)
        evolution.skip(oamdLength * 8)
        XCTAssertEqual(evolution.read(5), 0)
        XCTAssertEqual(evolution.read(2), 1)
        XCTAssertEqual(evolution.read(2), 0)
        let protectionOffset = evolution.position
        let officialProtection = UInt8(evolution.read(8))
        for bit in protectionOffset..<(protectionOffset + 8) {
            canonicalEvolution[bit / 8] &= ~(1 << UInt8(7 - bit % 8))
        }

        XCTAssertEqual(
            AtmosMetadataWriter.primaryProtection(
                accessUnitPrefix: Array(accessUnit[..<extraOffset]),
                canonicalEvolution: canonicalEvolution
            ),
            officialProtection
        )
    }

    func testOAMDUsesDefaultGainCodeForPositionalSignals() {
        let positions = AtmosSpatialCoder.fixedElementPositions
            + Array(repeating: ADMPosition.centre, count: 8)
        var oamd = TestBitReader(AtmosMetadataWriter.makeOAMDPayload(positions: positions))
        oamd.skip(43)
        XCTAssertEqual(oamd.read(1), 0) // LFE is active.
        XCTAssertEqual(oamd.read(2), 0) // LFE uses the special non-positional code.
        XCTAssertEqual(oamd.read(1), 1)
        XCTAssertEqual(oamd.read(1), 0)
        XCTAssertEqual(oamd.read(1), 0) // First positional signal is active.
        XCTAssertEqual(oamd.read(2), 3) // Default 0 dB positional gain.
    }

    func testOAMDSampleOffsetsAndRampMatchFrameCadence() {
        let positions = AtmosSpatialCoder.fixedElementPositions
            + Array(repeating: ADMPosition.centre, count: 8)

        var offset16 = TestBitReader(
            AtmosMetadataWriter.makeOAMDPayload(positions: positions, sampleOffset: 16)
        )
        offset16.skip(28)
        XCTAssertEqual(offset16.read(1), 0)
        XCTAssertEqual(offset16.read(2), 1)
        XCTAssertEqual(offset16.read(2), 1)
        XCTAssertEqual(offset16.read(3), 0)
        XCTAssertEqual(offset16.read(6), 0)
        XCTAssertEqual(offset16.read(2), 2)

        var offset32 = TestBitReader(
            AtmosMetadataWriter.makeOAMDPayload(positions: positions, sampleOffset: 32)
        )
        offset32.skip(28)
        XCTAssertEqual(offset32.read(1), 0)
        XCTAssertEqual(offset32.read(2), 0)
        XCTAssertEqual(offset32.read(3), 0)
        XCTAssertEqual(offset32.read(6), 1)
        XCTAssertEqual(offset32.read(2), 2)
    }

    func testHighResolutionTimingSerializesZeroTrimSequence() {
        var writer = HighResolutionTimingWriter()
        let bits = (0..<27).map { index in
            writer.nextBit(outputSample: UInt64(index * 128 * 40)) ? "1" : "0"
        }.joined()
        XCTAssertEqual(bits, "000001100000110000011100000")
    }

    func testFixedPointAtmosMatrixRoundTrip() {
        let core: [Int32] = [
            10_000, 20_000, 30_000, 4_000, 5_000, 6_000, 7_000, 8_000,
        ]
        let extras: [Int32] = [-101, 204, 77, -38, 511, -704, 93, 18]
        let targets = [[0, 2], [0], [7], [6], [1], [4], [5], [7]]
        var compatibleCore = core
        for speaker in [0, 1, 2, 4, 5, 6, 7] {
            let sum = zip(extras, targets).reduce(Int64(0)) {
                $0 + ($1.1.contains(speaker) ? Int64($1.0) : 0)
            }
            compatibleCore[speaker] += Int32((sum + 1) >> 1)
        }
        let transport = AtmosCompatibilityMatrix.transportSamples(
            standardSamples: compatibleCore + extras,
            channelCount: 16
        )
        let immersive = AtmosCompatibilityMatrix.immersiveOutput(
            transport[0..<16],
            matrixRenderTargets: targets
        )
        let recoveredCore = (0..<8).map {
            immersive[AtmosCompatibilityMatrix.matrixChannel(forSpeakerChannel: $0)]
        }
        XCTAssertEqual(recoveredCore, core)
        XCTAssertEqual(Array(immersive.dropFirst(8)), extras)
    }

    func testCompatibilityPresentationsRecoverDiscreteChannels() {
        let standard: [Int32] = [
            1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000,
        ]
        let transport = AtmosCompatibilityMatrix.transportSamples(
            standardSamples: standard,
            channelCount: 8
        )

        XCTAssertGreaterThan(transport[0], standard[0])
        XCTAssertGreaterThan(transport[1], standard[1])
        XCTAssertEqual(
            AtmosCompatibilityMatrix.sixChannelOutput(transport[0..<8]),
            [1_000, 14_000, 12_000, 2_000, 3_000, 4_000]
        )
        XCTAssertEqual(
            AtmosCompatibilityMatrix.eightChannelOutput(transport[0..<8]),
            [1_000, 8_000, 7_000, 2_000, 3_000, 4_000, 5_000, 6_000]
        )
    }

    func testSpatialCoderUsesCHNAFormatIDsInsteadOfPhysicalTrackOrder() throws {
        let shuffledFormatIDs = [
            "AC_00011009", "AC_00011002", "AC_00011004", "AC_00011001",
            "AC_00011008", "AC_00011003", "AC_00011005", "AC_0001100a",
            "AC_00011007", "AC_00011006"
        ]
        let channels = shuffledFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        let coder = try AtmosSpatialCoder(
            metadata: ADMMetadata(channels: channels),
            sourceChannelCount: channels.count,
            elementBitDepth: 20
        )
        var source = (1...10).map { Int32($0 << 4) }
        source[0] = 0
        source[7] = 0

        let encoded = coder.encode(source: source, frameCount: 1, sourceStartFrame: 0)
        XCTAssertEqual(Array(encoded.samples.prefix(8)), [4, 2, 6, 3, 7, 10, 9, 5])
    }

    func testSpatialCoderDoesNotAttenuateAnActiveObjectBecauseAssignedTracksAreSilent() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006"
        ]
        var channels = bedFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        channels.append(
            contentsOf: (0..<4).map { index in
                ADMChannelMetadata(
                    channelFormatID: String(format: "AC_00031%03d", index),
                    isObject: true,
                    blocks: [
                        ADMPositionBlock(
                            startFrame: 0,
                            endFrame: .max,
                            position: ADMPosition(x: 0, y: 0.8, z: 0.6)
                        )
                    ]
                )
            }
        )
        let coder = try AtmosSpatialCoder(
            metadata: ADMMetadata(channels: channels),
            sourceChannelCount: channels.count,
            elementBitDepth: 20
        )
        var source = [Int32](repeating: 0, count: channels.count)
        source[8] = 4_096

        let encoded = coder.encode(source: source, frameCount: 1, sourceStartFrame: 0)
        XCTAssertEqual(encoded.samples[8..<16].reduce(0, +), 256)
    }

    func testSpatialCoderLimitsMixedElementsToRequestedBitDepth() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006"
        ]
        var channels = bedFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        channels.append(contentsOf: (0..<8).map { index in
            ADMChannelMetadata(
                channelFormatID: String(format: "AC_00031%03d", index),
                isObject: true,
                blocks: [
                    ADMPositionBlock(
                        startFrame: 0,
                        endFrame: .max,
                        position: ADMPosition(x: 0, y: 0.8, z: 0.6)
                    )
                ]
            )
        })
        let coder = try AtmosSpatialCoder(
            metadata: ADMMetadata(channels: channels),
            sourceChannelCount: channels.count,
            elementBitDepth: 17
        )
        let encoded = coder.encode(
            source: [Int32](repeating: 0x007F_FFFF, count: channels.count),
            frameCount: 1,
            sourceStartFrame: 0
        )

        XCTAssertTrue(encoded.samples.allSatisfy { (-65_536...65_535).contains($0) })
        XCTAssertTrue(encoded.samples.contains(65_535))
    }

    func testSpatialCoderKeepsMovingObjectsOnOneTrackAndUpdatesPosition() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006"
        ]
        var channels = bedFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        channels.append(
            contentsOf: [
                ADMChannelMetadata(channelFormatID: "AC_00011009", isObject: false, blocks: []),
                ADMChannelMetadata(channelFormatID: "AC_0001100a", isObject: false, blocks: []),
                ADMChannelMetadata(
                    channelFormatID: "AC_00031001",
                    isObject: true,
                    blocks: [
                        ADMPositionBlock(
                            startFrame: 0,
                            endFrame: 1_000,
                            position: ADMPosition(x: -0.8, y: 0.8, z: 0.7)
                        ),
                        ADMPositionBlock(
                            startFrame: 1_000,
                            endFrame: .max,
                            position: ADMPosition(x: -0.8, y: -0.8, z: 0.7)
                        )
                    ]
                )
            ]
        )
        let coder = try AtmosSpatialCoder(
            metadata: ADMMetadata(channels: channels),
            sourceChannelCount: channels.count,
            elementBitDepth: 20
        )
        var source = [Int32](repeating: 0, count: channels.count)
        source[10] = 4_096

        let front = coder.encode(source: source, frameCount: 1, sourceStartFrame: 0)
        let rear = coder.encode(source: source, frameCount: 1, sourceStartFrame: 2_000)
        let frontTargets = coder.matrixRenderTargets(at: 0)
        let rearTargets = coder.matrixRenderTargets(at: 2_000)

        XCTAssertNotEqual(front.samples[8], 0)
        XCTAssertEqual(front.samples[12], 0)
        XCTAssertNotEqual(rear.samples[8], 0)
        XCTAssertEqual(rear.samples[12], 0)
        XCTAssertGreaterThan(rear.positions[8].z, 0.5)
        XCTAssertLessThan(rear.positions[8].y, -0.5)
        XCTAssertNotEqual(frontTargets[0], rearTargets[0])
        XCTAssertTrue(frontTargets[0].contains(0))
        XCTAssertTrue(rearTargets[0].contains(6))
    }

    func testSpatialCoderComputesFixedWholeProgramHeadroom() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006"
        ]
        var channels = bedFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        channels.append(contentsOf: (0..<8).map { index in
            ADMChannelMetadata(
                channelFormatID: String(format: "AC_00031%03d", index),
                isObject: true,
                blocks: [
                    ADMPositionBlock(
                        startFrame: 0,
                        endFrame: .max,
                        position: ADMPosition(x: 0, y: 0.8, z: 0.6)
                    )
                ]
            )
        })
        let metadata = ADMMetadata(channels: channels)
        let coder = try AtmosSpatialCoder(
            metadata: metadata,
            sourceChannelCount: channels.count,
            elementBitDepth: 17
        )
        let reader = TestAudioReader(
            channelCount: channels.count,
            frameCount: 80,
            sample: 0x007F_FFFF,
            metadata: metadata
        )

        XCTAssertEqual(
            try coder.requiredHeadroomShift(reader: reader, startFrame: 0, frameCount: 80),
            3
        )

        let cacheReader = TestAudioReader(
            channelCount: channels.count,
            frameCount: 80,
            sample: 0x007F_FFFF,
            metadata: metadata
        )
        let cache = try coder.prepareElementCache(
            reader: cacheReader, startFrame: 0, frameCount: 80
        )
        defer { try? FileManager.default.removeItem(at: cache.url) }
        XCTAssertEqual(cache.headroomShift, 3)
        let data = try Data(contentsOf: cache.url)
        let unscaled = data.withUnsafeBytes {
            Array($0.bindMemory(to: Int64.self))
        }
        coder.setAdditionalHeadroomShift(cache.headroomShift)
        let cachedSamples = coder.quantize(unscaledSamples: unscaled)

        var directSamples = [Int32]()
        let source = [Int32](
            repeating: 0x007F_FFFF, count: 40 * channels.count
        )
        directSamples += coder.encode(
            source: source, frameCount: 40, sourceStartFrame: 0
        ).samples
        directSamples += coder.encode(
            source: source, frameCount: 40, sourceStartFrame: 40
        ).samples
        XCTAssertEqual(cachedSamples, directSamples)
    }

    func testSpatialCoderProducesRequestedElementCount() throws {
        let formatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006",
            "AC_00011009", "AC_0001100a"
        ]
        let channels = formatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        for count in AtmosSpatialCoder.supportedElementCounts {
            let coder = try AtmosSpatialCoder(
                metadata: ADMMetadata(channels: channels),
                sourceChannelCount: channels.count,
                elementBitDepth: 20,
                spatialClusterCount: count
            )
            let encoded = coder.encode(
                source: [Int32](repeating: 0, count: channels.count),
                frameCount: 1,
                sourceStartFrame: 0
            )
            XCTAssertEqual(encoded.samples.count, count)
            XCTAssertEqual(encoded.positions.count, count)
            XCTAssertEqual(coder.matrixRenderTargets.count, count - 8)
        }
    }

    private func writeASCII(
        _ value: String,
        into bytes: inout [UInt8],
        at offset: Int,
        length: Int
    ) {
        let encoded = Array(value.utf8.prefix(length))
        bytes.replaceSubrange(offset..<(offset + encoded.count), with: encoded)
    }
}

private final class TestAudioReader: TrueHDAudioReader {
    let format: WaveFormat
    let frameCount: UInt64
    let admXML: Data? = nil
    let admChannelAssignment: Data? = nil
    let admMetadata: ADMMetadata?
    let sourceFrameRate: TrueHDFrameRate? = nil

    private let sample: Int32
    private var currentFrame: UInt64 = 0

    init(channelCount: Int, frameCount: UInt64, sample: Int32, metadata: ADMMetadata) {
        format = WaveFormat(
            sampleRate: 48_000,
            channelCount: channelCount,
            bitsPerSample: 24,
            validBitsPerSample: 24,
            blockAlignment: channelCount * 3,
            channelMask: 0,
            isBigEndian: false
        )
        self.frameCount = frameCount
        self.sample = sample
        admMetadata = metadata
    }

    func readFrames(maxCount: Int) throws -> PCMFrameBlock {
        let count = Int(min(UInt64(maxCount), frameCount - currentFrame))
        currentFrame += UInt64(count)
        return PCMFrameBlock(
            samples: [Int32](repeating: sample, count: count * format.channelCount),
            frameCount: count
        )
    }

    func seek(toFrame frame: UInt64) throws {
        currentFrame = min(frame, frameCount)
    }
}

private struct TestBitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var position: Int { bitOffset }

    mutating func read(_ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count {
            let byte = bytes[bitOffset / 8]
            let shift = 7 - bitOffset % 8
            value = (value << 1) | UInt64((byte >> shift) & 1)
            bitOffset += 1
        }
        return value
    }

    mutating func skip(_ count: Int) {
        bitOffset += count
    }
}
