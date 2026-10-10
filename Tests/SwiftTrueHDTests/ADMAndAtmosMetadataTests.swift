// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research

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
        // The audit accepts any complete native Atmos programme; fixture
        // duration must not be hard-coded into the structural validation.
        XCTAssertGreaterThan(accessUnitCount, 0)
        XCTAssertGreaterThan(evolutionCount, 0)
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

    func testADMPolarAxisAndJumpInterpolationFollowBS2076() throws {
        let xml = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <audioFormatExtended>
              <audioChannelFormat audioChannelFormatID="AC_00031001" typeDefinition="Objects">
                <audioBlockFormat audioBlockFormatID="AB_00031001_00000001"
                                  rtime="00:00:00.000" duration="00:00:00.001">
                  <cartesian>0</cartesian>
                  <position coordinate="azimuth">90</position>
                  <position coordinate="elevation">0</position>
                  <position coordinate="distance">1</position>
                  <jumpPosition>1</jumpPosition>
                </audioBlockFormat>
                <audioBlockFormat audioBlockFormatID="AB_00031001_00000002"
                                  rtime="00:00:00.001" duration="00:00:00.001">
                  <cartesian>1</cartesian>
                  <position coordinate="X">0</position>
                  <position coordinate="Y">1</position>
                  <position coordinate="Z">0</position>
                  <jumpPosition>1</jumpPosition>
                </audioBlockFormat>
                <audioBlockFormat audioBlockFormatID="AB_00031001_00000003"
                                  rtime="00:00:00.002" duration="00:00:00.002">
                  <cartesian>1</cartesian>
                  <position coordinate="X">1</position>
                  <position coordinate="Y">0</position>
                  <position coordinate="Z">0</position>
                  <jumpPosition>0</jumpPosition>
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
        let channel = metadata.channels[0]
        XCTAssertEqual(channel.position(at: 0).x, -1, accuracy: 0.000_001)
        XCTAssertEqual(channel.position(at: 0).y, 0, accuracy: 0.000_001)
        XCTAssertEqual(channel.position(at: 72), ADMPosition(x: 0, y: 1, z: 0))
        XCTAssertEqual(channel.position(at: 144).x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(channel.position(at: 144).y, 0.5, accuracy: 0.000_001)
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

    func testOAMDPositionOrderFollowsDecodedChannelAssignment() {
        // Decoded output channels receive matrix channels through the
        // canonical FBA ch_assign permutation. The OAMD signal list is
        // decoded-output ordered, so its per-signal position must resolve
        // each output channel back to the matrix channel that feeds it.
        let order16 = AtmosBitstreamEncoder.oamdPositionOrder(elementCount: 16)
        XCTAssertEqual(order16.count, 16)
        XCTAssertEqual(Set(order16), Set(0..<16), "Order must be a permutation")

        // ch_assign [2, 10, 7, 8, 3, 0, 4, 5, 9, 11, 12, 13, 14, 15, 6, 1]
        // maps matrix channel 0 (L) to output 2, matrix channel 5 (LFE) to
        // output 0, and matrix channel 1 (Rb) to output 10. Positions are
        // stored in OAMD signal order LFE, L, R, C, Lb, Rb, Ls, Rs then
        // clusters, so each output resolves to the position of the matrix
        // channel that feeds it.
        XCTAssertEqual(order16[0], 0, "Output 0 carries the LFE bed position")
        XCTAssertEqual(order16[2], 1, "Output 2 carries the transport L position")
        XCTAssertEqual(order16[8], 2, "Output 8 carries the transport R position")
        XCTAssertEqual(order16[3], 3, "Output 3 carries the transport C position")
        XCTAssertEqual(order16[7], 4, "Output 7 carries the transport Lb position")
        XCTAssertEqual(order16[10], 5, "Output 10 carries the transport Rb position")
        XCTAssertEqual(order16[4], 6, "Output 4 carries the transport Ls position")
        XCTAssertEqual(order16[5], 7, "Output 5 carries the transport Rs position")
        // Cluster elements (matrix channels 8+) keep their matrix index.
        XCTAssertEqual(order16[9], 8, "Output 9 carries the first cluster position")
        XCTAssertEqual(order16[1], 15, "Output 1 carries the last cluster position")

        for count in AtmosSpatialCoder.supportedElementCounts {
            let order = AtmosBitstreamEncoder.oamdPositionOrder(elementCount: count)
            XCTAssertEqual(Set(order), Set(0..<count))
            XCTAssertEqual(order[0], 0)
        }
    }

    func testOAMDUsesDefaultGainCodeForPositionalSignals() {
        let positions = AtmosSpatialCoder.fixedElementPositions
            + Array(repeating: ADMPosition.centre, count: 8)
        var oamd = oamdObjectElementReader(
            AtmosMetadataWriter.makeOAMDPayload(positions: positions)
        )
        oamd.skip(15) // required flag, timing block, reserved-data flag
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

        var offset16 = oamdObjectElementReader(
            AtmosMetadataWriter.makeOAMDPayload(positions: positions, sampleOffset: 16)
        )
        XCTAssertEqual(offset16.read(1), 0)
        XCTAssertEqual(offset16.read(2), 1)
        XCTAssertEqual(offset16.read(2), 1)
        XCTAssertEqual(offset16.read(3), 0)
        XCTAssertEqual(offset16.read(6), 0)
        XCTAssertEqual(offset16.read(2), 2)

        var offset32 = oamdObjectElementReader(
            AtmosMetadataWriter.makeOAMDPayload(positions: positions, sampleOffset: 32)
        )
        XCTAssertEqual(offset32.read(1), 0)
        XCTAssertEqual(offset32.read(2), 0)
        XCTAssertEqual(offset32.read(3), 0)
        XCTAssertEqual(offset32.read(6), 1)
        XCTAssertEqual(offset32.read(2), 2)
    }

    func testOAMDSerializesOneCompleteDecoderCompatibleObjectState() {
        var positions = AtmosSpatialCoder.fixedElementPositions
            + Array(repeating: ADMPosition.centre, count: 4)
        positions[1] = ADMPosition(x: -0.5, y: 0.75, z: 0.25)
        var object = oamdObjectElementReader(
            AtmosMetadataWriter.makeOAMDPayload(
                updates: [
                    AtmosMetadataUpdate(
                        blockOffsetFactor: 8,
                        rampDuration: 750,
                        positions: positions
                    )
                ],
                sampleOffset: 10
            )
        )

        XCTAssertEqual(object.read(1), 0) // object element is required
        XCTAssertEqual(object.read(2), 2) // explicit sample offset
        XCTAssertEqual(object.read(5), 10)
        XCTAssertEqual(object.read(3), 0) // one complete object-info block
        XCTAssertEqual(object.read(6), 8)
        XCTAssertEqual(object.read(2), 3)
        XCTAssertEqual(object.read(1), 0)
        XCTAssertEqual(object.read(11), 750)
        XCTAssertEqual(object.read(1), 1) // no reserved object data

        // LFE carries one complete basic state and no positional payload.
        XCTAssertEqual(object.read(1), 0)
        XCTAssertEqual(object.read(2), 0)
        XCTAssertEqual(object.read(1), 1)
        XCTAssertEqual(object.read(1), 0)

        // The first positional signal also carries one complete state.
        XCTAssertEqual(object.read(1), 0)
        XCTAssertEqual(object.read(2), 3)
        XCTAssertEqual(object.read(1), 1)
        let decoded = readOAMDPosition(&object)
        XCTAssertEqual(decoded.x, positions[1].x, accuracy: 1.0 / 31.0)
        XCTAssertEqual(decoded.y, positions[1].y, accuracy: 1.0 / 31.0)
        XCTAssertEqual(decoded.z, positions[1].z, accuracy: 1.0 / 15.0)
        object.skip(3 + 1 + 2 + 1 + 1) // zone/elevation, size, screen, snap
        XCTAssertEqual(object.read(1), 0)
    }

    func testOAMDSampleOffsetThirtyNineKeepsExactAbsoluteTiming() {
        let positions = AtmosSpatialCoder.fixedElementPositions
            + Array(repeating: ADMPosition.centre, count: 4)
        var object = oamdObjectElementReader(
            AtmosMetadataWriter.makeOAMDPayload(
                updates: [
                    AtmosMetadataUpdate(
                        blockOffsetFactor: 3,
                        rampDuration: 1_000,
                        positions: positions
                    )
                ],
                sampleOffset: 39
            )
        )

        XCTAssertEqual(object.read(1), 0)
        XCTAssertEqual(object.read(2), 2)
        XCTAssertEqual(object.read(5), 7)
        XCTAssertEqual(object.read(3), 0)
        XCTAssertEqual(object.read(6), 4) // 7 + 32 * 4 == 39 + 32 * 3
        XCTAssertEqual(object.read(2), 3)
        XCTAssertEqual(object.read(1), 0)
        XCTAssertEqual(object.read(11), 1_000)
    }

    func testOAMDKnownElementStartsImmediatelyAfterItsSize() {
        let positions = AtmosSpatialCoder.fixedElementPositions
            + Array(repeating: ADMPosition.centre, count: 4)
        let bytes = AtmosMetadataWriter.makeOAMDPayload(positions: positions)
        var reader = TestBitReader(bytes)
        XCTAssertEqual(reader.read(2), 0)
        XCTAssertEqual(reader.read(5), UInt64(positions.count - 1))
        XCTAssertEqual(reader.read(1), 1)
        XCTAssertEqual(reader.read(1), 1)
        XCTAssertEqual(reader.read(1), 0)
        XCTAssertEqual(reader.read(4), 1)
        XCTAssertEqual(reader.read(4), 1)
        let declaredByteCount = Int(reader.readVariable(groupBits: 4)) + 1
        let elementStart = reader.position
        let remainingBits = bytes.count * 8 - elementStart

        XCTAssertGreaterThanOrEqual(remainingBits, declaredByteCount * 8)
        XCTAssertLessThan(remainingBits, declaredByteCount * 8 + 8)
        // This is the first bit of the recognized Object element itself.
        // A discard-unknown-element bit exists only for unknown element IDs
        // and must not be inserted here.
        XCTAssertEqual(reader.read(1), 0) // Object element is required.
    }

    func testSpatialCoderUsesOneCompleteFrameBoundaryState() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006",
            "AC_00011009", "AC_0001100a"
        ]
        var channels = bedFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        channels.append(
            ADMChannelMetadata(
                channelFormatID: "AC_00031001",
                isObject: true,
                blocks: [
                    ADMPositionBlock(
                        startFrame: 0, endFrame: 250,
                        position: ADMPosition(x: -1, y: 1, z: 0),
                        interpolatesToNext: true
                    ),
                    ADMPositionBlock(
                        startFrame: 250, endFrame: 1_000,
                        position: ADMPosition(x: 0, y: 0, z: 0.5),
                        interpolatesToNext: true
                    ),
                    ADMPositionBlock(
                        startFrame: 1_000, endFrame: .max,
                        position: ADMPosition(x: 1, y: -1, z: 1)
                    ),
                ]
            )
        )
        let coder = try AtmosSpatialCoder(
            metadata: ADMMetadata(channels: channels),
            sourceChannelCount: channels.count,
            elementBitDepth: 20
        )
        let initial = try coder.metadataUpdates(
            frameStart: 0, programmeStart: 0, programmeEnd: 3_072
        )
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial[0].blockOffsetFactor, 0)
        XCTAssertEqual(initial[0].rampDuration, 1_536)
        XCTAssertEqual(initial[0].positions, coder.positions(at: 0))

        let next = try coder.metadataUpdates(
            frameStart: 1_536, programmeStart: 0, programmeEnd: 3_072
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].blockOffsetFactor, 0)
        XCTAssertEqual(next[0].rampDuration, 1_536)
        XCTAssertEqual(next[0].positions, coder.positions(at: 3_072))
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
        let renderCoefficients = targets.map { speakers -> [Int32] in
            var coefficients = [Int32](repeating: 0, count: 8)
            for speaker in speakers {
                coefficients[speaker] = Int32(AtmosCompatibilityMatrix.halfCoefficient)
            }
            return coefficients
        }
        var compatibleCore = core
        let spatialElements = extras.map(Int64.init)
        for speaker in [0, 1, 2, 4, 5, 6, 7] {
            compatibleCore[speaker] += Int32(
                AtmosCompatibilityMatrix.foldedContribution(
                    spatialElements: spatialElements[...],
                    renderCoefficients: renderCoefficients,
                    speaker: speaker
                )
            )
        }
        let transport = AtmosCompatibilityMatrix.transportSamples(
            standardSamples: compatibleCore + extras,
            channelCount: 16
        )
        let immersive = AtmosCompatibilityMatrix.immersiveOutput(
            transport[0..<16],
            renderCoefficients: renderCoefficients
        )
        let recoveredCore = (0..<8).map {
            immersive[AtmosCompatibilityMatrix.matrixChannel(forSpeakerChannel: $0)]
        }
        XCTAssertEqual(recoveredCore, core)
        XCTAssertEqual(Array(immersive.dropFirst(8)), extras)
    }

    func testCompatibilityObjectRendererMatchesDEEAnchorPositions() {
        let scale = Double(AtmosCompatibilityMatrix.scale)
        func gains(_ position: ADMPosition) -> [Double] {
            AtmosCompatibilityMatrix.renderCoefficients(for: position).map {
                Double($0) / scale
            }
        }

        let leftFront = gains(ADMPosition(x: -1, y: 1, z: 0))
        XCTAssertEqual(leftFront[0], 1, accuracy: 1 / scale)
        XCTAssertEqual(leftFront.filter { $0 != 0 }.count, 1)

        let rightRear = gains(ADMPosition(x: 1, y: -1, z: 0))
        XCTAssertEqual(rightRear[7], pow(2, -0.25), accuracy: 2 / scale)
        XCTAssertEqual(rightRear.filter { $0 != 0 }.count, 1)

        let overheadCentre = gains(ADMPosition(x: 0, y: 0, z: 1))
        XCTAssertEqual(overheadCentre[4], pow(2, -0.25) / sqrt(2), accuracy: 2 / scale)
        XCTAssertEqual(overheadCentre[5], overheadCentre[4], accuracy: 1 / scale)
        XCTAssertEqual(overheadCentre.filter { $0 != 0 }.count, 2)

        let leftCentreFront = gains(ADMPosition(x: -0.5, y: 1, z: 0))
        XCTAssertEqual(leftCentreFront[0], 1 / sqrt(2), accuracy: 2 / scale)
        XCTAssertEqual(leftCentreFront[2], leftCentreFront[0], accuracy: 1 / scale)
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
            [1_000, 11_924, 10_217, 2_000, 3_000, 4_000]
        )
        XCTAssertEqual(
            AtmosCompatibilityMatrix.eightChannelOutput(transport[0..<8]),
            [1_000, 6_727, 5_886, 2_000, 3_000, 4_000, 4_330, 5_196]
        )
        let immersiveTransport = transport + [Int32](repeating: 99_999, count: 8)
        XCTAssertEqual(
            AtmosCompatibilityMatrix.eightChannelOutput(immersiveTransport[...]),
            AtmosCompatibilityMatrix.eightChannelOutput(transport[...]),
            "The 7.1 checksum and PCM must exclude the immersive suffix"
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

    func testSpatialCoderDoesNotAttenuateAnActiveObjectBecauseOtherTracksAreSilent() throws {
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
        XCTAssertGreaterThan(encoded.samples[8..<16].reduce(0, +), 0)
        XCTAssertGreaterThan(
            encoded.samples.enumerated().filter { $0.offset != 3 }
                .reduce(Int64(0)) { $0 + Int64($1.element) * Int64($1.element) },
            240 * 240
        )
    }

    func testSpatialCoderKeepsPresentObjectWithoutPositionEvents() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006",
            "AC_00011009", "AC_0001100a"
        ]
        var channels = bedFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        channels.append(
            ADMChannelMetadata(
                channelFormatID: "AC_00031001",
                isObject: true,
                blocks: [],
                isPresent: true
            )
        )
        let coder = try AtmosSpatialCoder(
            metadata: ADMMetadata(channels: channels),
            sourceChannelCount: channels.count,
            elementBitDepth: 20
        )
        var source = [Int32](repeating: 0, count: channels.count)
        source[10] = 4_096

        let encoded = coder.encode(source: source, frameCount: 1, sourceStartFrame: 0)
        XCTAssertNotEqual(
            encoded.samples.enumerated().filter { $0.offset != 3 }
                .reduce(0) { $0 + abs($1.element) },
            0
        )
    }

    func testSpatialCoderKeepsStaticBedAlignedObjectAsObject() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006",
            "AC_00011009", "AC_0001100a"
        ]
        var channels = bedFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        channels.append(
            ADMChannelMetadata(
                channelFormatID: "AC_00031001",
                isObject: true,
                blocks: [
                    ADMPositionBlock(
                        startFrame: 0,
                        endFrame: .max,
                        position: ADMPosition(x: -1, y: 1, z: 0)
                    )
                ]
            )
        )
        let coder = try AtmosSpatialCoder(
            metadata: ADMMetadata(channels: channels),
            sourceChannelCount: channels.count,
            elementBitDepth: 20
        )
        var source = [Int32](repeating: 0, count: channels.count)
        source[10] = 4_096

        let encoded = coder.encode(source: source, frameCount: 1, sourceStartFrame: 0)
        XCTAssertNotEqual(
            encoded.samples[0], 0,
            "A Bed-aligned Object must remain in the fixed spatial rendering basis"
        )
    }

    func testFixedOAMDBasisIgnoresSilentObjectsAndPansActivePCM() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006",
            "AC_00011009", "AC_0001100a"
        ]
        var channels = bedFormatIDs.enumerated().map { index, formatID in
            ADMChannelMetadata(
                channelFormatID: formatID,
                isObject: false,
                blocks: [],
                isPresent: index < 8
            )
        }
        let activePosition = ADMPosition(x: -0.8, y: 0.75, z: 0.6)
        channels.append(contentsOf: [
            ADMChannelMetadata(
                channelFormatID: "AC_00031001", isObject: true,
                blocks: [ADMPositionBlock(
                    startFrame: 0, endFrame: .max, position: activePosition
                )]
            ),
            ADMChannelMetadata(
                channelFormatID: "AC_00031002", isObject: true,
                blocks: [ADMPositionBlock(
                    startFrame: 0, endFrame: .max,
                    position: ADMPosition(x: 0.9, y: -0.9, z: 0)
                )]
            )
        ])
        let metadata = ADMMetadata(channels: channels)
        let coder = try AtmosSpatialCoder(
            metadata: metadata,
            sourceChannelCount: channels.count,
            elementBitDepth: 20
        )
        var samplesByChannel = [Int32](repeating: 0, count: channels.count)
        samplesByChannel[10] = 8_192
        let reader = TestAudioReader(
            channelCount: channels.count,
            frameCount: 1_536,
            samplesByChannel: samplesByChannel,
            metadata: metadata
        )
        let cache = try coder.prepareElementCache(
            reader: reader, startFrame: 0, frameCount: 1_536
        )
        defer { try? FileManager.default.removeItem(at: cache.url) }

        let update = try XCTUnwrap(coder.metadataUpdates(
            frameStart: 0, programmeStart: 0, programmeEnd: 1_536
        ).first)
        let cacheData = try Data(contentsOf: cache.url)
        let firstElements = (0..<16).map { element in
            cacheData.withUnsafeBytes {
                $0.loadUnaligned(
                    fromByteOffset: element * MemoryLayout<Int64>.size,
                    as: Int64.self
                )
            }
        }
        let activeClusters = (0..<8).filter {
            firstElements[8 + $0] != 0
        }
        XCTAssertGreaterThan(
            activeClusters.count, 1,
            "An elevated Object must use a constant-power set of fixed height anchors"
        )
        XCTAssertEqual(update.positions, coder.positions(at: 0))
        XCTAssertEqual(update.positions, coder.positions(at: 1_535))

        let serializedPositions = readOAMDPositions(
            AtmosMetadataWriter.makeOAMDPayload(positions: update.positions),
            positionCount: update.positions.count
        )
        for (serialized, expected) in zip(serializedPositions, update.positions.dropFirst()) {
            XCTAssertEqual(serialized.x, expected.x, accuracy: 1.0 / 31.0)
            XCTAssertEqual(serialized.y, expected.y, accuracy: 1.0 / 31.0)
            XCTAssertEqual(serialized.z, expected.z, accuracy: 1.0 / 15.0)
        }
        let report = coder.spatialAccuracyReport()
        XCTAssertEqual(report.maximumActiveSpatialSources, 1)
        XCTAssertEqual(report.groupedIntervalCount, 0)
        XCTAssertEqual(report.assignmentChangeCount, 0)
        XCTAssertLessThan(report.maximumQuantizedPositionError, 0.8)
    }

    func testSpatialCoderPansManyObjectsAcrossTheFixedRenderingBasis() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006",
            "AC_00011009", "AC_0001100a"
        ]
        var channels = bedFormatIDs.enumerated().map { index, formatID in
            ADMChannelMetadata(
                channelFormatID: formatID, isObject: false,
                blocks: [], isPresent: index < 8
            )
        }
        let positions = [
            ADMPosition(x: -0.8, y: 0.8, z: 0.8),
            ADMPosition(x: 0.8, y: 0.8, z: 0.8),
            ADMPosition(x: -0.9, y: 0.1, z: 0.5),
            ADMPosition(x: 0.9, y: 0.1, z: 0.5),
            ADMPosition(x: -0.8, y: -0.8, z: 0.8),
            ADMPosition(x: 0.8, y: -0.8, z: 0.8),
            ADMPosition(x: 0, y: 0.8, z: 0.75),
            ADMPosition(x: 0, y: -0.8, z: 0.75),
            ADMPosition(x: -0.6, y: 0.7, z: 0.7),
            ADMPosition(x: 0.6, y: -0.7, z: 0.7)
        ]
        channels.append(contentsOf: positions.enumerated().map { index, position in
            ADMChannelMetadata(
                channelFormatID: String(format: "AC_00032%03d", index),
                isObject: true,
                blocks: [ADMPositionBlock(
                    startFrame: 0, endFrame: .max, position: position
                )]
            )
        })
        let metadata = ADMMetadata(channels: channels)
        let coder = try AtmosSpatialCoder(
            metadata: metadata, sourceChannelCount: channels.count,
            elementBitDepth: 20, spatialClusterCount: 16
        )
        var samples = [Int32](repeating: 0, count: channels.count)
        for channel in 10..<channels.count { samples[channel] = 4_096 }
        let reader = TestAudioReader(
            channelCount: channels.count, frameCount: 1_536,
            samplesByChannel: samples, metadata: metadata
        )
        let cache = try coder.prepareElementCache(
            reader: reader, startFrame: 0, frameCount: 1_536
        )
        defer { try? FileManager.default.removeItem(at: cache.url) }
        let data = try Data(contentsOf: cache.url)
        let rendered = (0..<16).map { element in
            data.withUnsafeBytes {
                $0.loadUnaligned(
                    fromByteOffset: element * MemoryLayout<Int64>.size,
                    as: Int64.self
                )
            }
        }
        XCTAssertGreaterThan(rendered.filter { $0 != 0 }.count, 8)
        XCTAssertGreaterThan(
            rendered.enumerated().filter { $0.offset != 3 }
                .reduce(Int64(0)) { $0 + $1.element * $1.element },
            0
        )

        let report = coder.spatialAccuracyReport()
        XCTAssertEqual(report.maximumActiveSpatialSources, 10)
        XCTAssertEqual(report.groupedIntervalCount, 0)
        XCTAssertEqual(report.sourceIntervalCount, 10)
        XCTAssertEqual(report.assignmentChangeCount, 0)
        XCTAssertLessThan(report.energyWeightedRMSQuantizedPositionError, 0.8)
    }

    func testHeightPannerUsesSmoothEqualPowerRowsNearSideAnchor() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006",
            "AC_00011009", "AC_0001100a"
        ]
        var channels = bedFormatIDs.enumerated().map { index, formatID in
            ADMChannelMetadata(
                channelFormatID: formatID, isObject: false,
                blocks: [], isPresent: index < 8
            )
        }
        channels.append(ADMChannelMetadata(
            channelFormatID: "AC_00031001",
            isObject: true,
            blocks: [ADMPositionBlock(
                startFrame: 0, endFrame: .max,
                position: ADMPosition(x: -1, y: -0.1, z: 1)
            )]
        ))
        let coder = try AtmosSpatialCoder(
            metadata: ADMMetadata(channels: channels),
            sourceChannelCount: channels.count,
            elementBitDepth: 20,
            spatialClusterCount: 16
        )
        var source = [Int32](repeating: 0, count: channels.count)
        source[10] = 1_048_576

        let encoded = coder.encode(source: source, frameCount: 1, sourceStartFrame: 0)
        let leftSideHeight = Double(encoded.samples[10])
        let leftRearHeight = Double(encoded.samples[12])
        XCTAssertGreaterThan(leftSideHeight, 0)
        XCTAssertGreaterThan(leftRearHeight, 0)
        XCTAssertEqual(
            leftRearHeight / leftSideHeight,
            tan(0.1 * Double.pi / 2),
            accuracy: 0.002,
            "A slightly rearward Object must crossfade smoothly instead of sticking to one height anchor"
        )
        XCTAssertEqual(
            hypot(leftSideHeight, leftRearHeight),
            65_536,
            accuracy: 2,
            "Height-row interpolation must preserve Object power"
        )
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
        let transport = AtmosCompatibilityMatrix.transportSamples(
            standardSamples: encoded.samples,
            channelCount: 16
        )
        XCTAssertTrue(transport.allSatisfy { (-65_536...65_535).contains($0) })
        XCTAssertGreaterThanOrEqual(transport.map { $0.magnitude }.max() ?? 0, 65_400)
        XCTAssertLessThan(transport.map { $0.magnitude }.max() ?? 0, 65_535)
    }

    func testSpatialCoderMovesPCMAcrossAStableOAMDBasis() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006"
        ]
        var channels = bedFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        channels.append(
            contentsOf: [
                ADMChannelMetadata(
                    channelFormatID: "AC_00011009", isObject: false,
                    blocks: [], isPresent: false
                ),
                ADMChannelMetadata(
                    channelFormatID: "AC_0001100a", isObject: false,
                    blocks: [], isPresent: false
                ),
                ADMChannelMetadata(
                    channelFormatID: "AC_00031001",
                    isObject: true,
                    blocks: [
                        ADMPositionBlock(
                            startFrame: 0,
                            endFrame: 3_072,
                            position: ADMPosition(x: -0.8, y: 0.8, z: 0.7),
                            interpolatesToNext: true
                        ),
                        ADMPositionBlock(
                            startFrame: 3_072,
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
        var samplesByChannel = [Int32](repeating: 0, count: channels.count)
        samplesByChannel[10] = 4_096
        let reader = TestAudioReader(
            channelCount: channels.count,
            frameCount: 4_608,
            samplesByChannel: samplesByChannel,
            metadata: ADMMetadata(channels: channels)
        )
        let cache = try coder.prepareElementCache(
            reader: reader, startFrame: 0, frameCount: 4_608
        )
        defer { try? FileManager.default.removeItem(at: cache.url) }
        let cacheData = try Data(contentsOf: cache.url)
        func heightPower(at frame: Int, clusters: [Int]) -> Int64 {
            clusters.reduce(Int64(0)) { power, cluster in
                let sample: Int64 = cacheData.withUnsafeBytes {
                    $0.loadUnaligned(
                        fromByteOffset: (frame * 16 + 8 + cluster)
                            * MemoryLayout<Int64>.size,
                        as: Int64.self
                    )
                }
                return power + sample * sample
            }
        }
        func activeHeightElements(at frame: Int) -> Int {
            (0..<8).filter { cluster in
                cacheData.withUnsafeBytes {
                    $0.loadUnaligned(
                        fromByteOffset: (frame * 16 + 8 + cluster)
                            * MemoryLayout<Int64>.size,
                        as: Int64.self
                    ) != 0
                }
            }.count
        }
        XCTAssertGreaterThan(activeHeightElements(at: 0), 1)
        XCTAssertGreaterThan(
            heightPower(at: 0, clusters: [0, 1, 6]),
            heightPower(at: 0, clusters: [4, 5, 7])
        )
        XCTAssertGreaterThan(
            heightPower(at: 4_607, clusters: [4, 5, 7]),
            heightPower(at: 4_607, clusters: [0, 1, 6])
        )

        let front = try XCTUnwrap(coder.metadataUpdates(
            frameStart: 0, programmeStart: 0, programmeEnd: 4_608
        ).first)
        let rear = try XCTUnwrap(coder.metadataUpdates(
            frameStart: 3_072, programmeStart: 0, programmeEnd: 4_608
        ).first)
        let frontRender = coder.matrixRenderCoefficients(at: 0)
        let rearRender = coder.matrixRenderCoefficients(at: 4_607)
        let report = coder.spatialAccuracyReport()
        XCTAssertEqual(report.assignmentChangeCount, 0)
        XCTAssertEqual(front.positions, rear.positions)
        XCTAssertEqual(frontRender, rearRender)
    }

    func testSpatialCoderSmoothsHighSpeedXYZMotionAcrossMetadataBoundary() throws {
        let bedFormatIDs = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006"
        ]
        var channels = bedFormatIDs.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        }
        let starts = (0..<10).map { index in
            let angle = Double(index) * 2 * Double.pi / 10
            return ADMPosition(x: cos(angle) * 0.9, y: sin(angle) * 0.9, z: 0.7)
        }
        channels.append(contentsOf: starts.enumerated().map { index, start in
            ADMChannelMetadata(
                channelFormatID: String(format: "AC_00033%03d", index),
                isObject: true,
                blocks: [
                    ADMPositionBlock(
                        startFrame: 0, endFrame: 1_536, position: start,
                        interpolatesToNext: true
                    ),
                    ADMPositionBlock(
                        startFrame: 1_536, endFrame: .max,
                        position: ADMPosition(
                            x: -start.x, y: -start.y,
                            z: index.isMultiple(of: 2) ? 0.05 : 1
                        )
                    )
                ]
            )
        })
        let metadata = ADMMetadata(channels: channels)
        let coder = try AtmosSpatialCoder(
            metadata: metadata, sourceChannelCount: channels.count,
            elementBitDepth: 20, spatialClusterCount: 16
        )
        var samplesByChannel = [Int32](repeating: 0, count: channels.count)
        for channel in 8..<channels.count {
            samplesByChannel[channel] = Int32((channel - 7) * 4_096)
        }
        let reader = TestAudioReader(
            channelCount: channels.count, frameCount: 3_072,
            samplesByChannel: samplesByChannel, metadata: metadata
        )
        let cache = try coder.prepareElementCache(
            reader: reader, startFrame: 0, frameCount: 3_072
        )
        defer { try? FileManager.default.removeItem(at: cache.url) }
        let data = try Data(contentsOf: cache.url)
        func renderedSamples(at frame: Int) -> [Int64] {
            (0..<16).filter { $0 != 3 }.map { element in
                data.withUnsafeBytes {
                    $0.loadUnaligned(
                        fromByteOffset: (frame * 16 + element)
                            * MemoryLayout<Int64>.size,
                        as: Int64.self
                    )
                }
            }
        }

        let boundarySteps = zip(
            renderedSamples(at: 1_535), renderedSamples(at: 1_536)
        ).map { abs($0.0 - $0.1) }
        let precedingSteps = zip(
            renderedSamples(at: 1_534), renderedSamples(at: 1_535)
        ).map { abs($0.0 - $0.1) }
        let followingSteps = zip(
            renderedSamples(at: 1_536), renderedSamples(at: 1_537)
        ).map { abs($0.0 - $0.1) }
        XCTAssertLessThanOrEqual(
            boundarySteps.max() ?? .max,
            max(precedingSteps.max() ?? 0, followingSteps.max() ?? 0) + 1,
            "The metadata boundary must not exceed the surrounding ramp slope"
        )
        XCTAssertEqual(coder.spatialAccuracyReport().assignmentChangeCount, 0)
        var maximumSpatialStep: Int64 = 0
        var previousSpatial = renderedSamples(at: 1_535)
        for frame in 1_536..<3_072 {
            let currentSpatial = renderedSamples(at: frame)
            for element in currentSpatial.indices {
                maximumSpatialStep = max(
                    maximumSpatialStep,
                    abs(currentSpatial[element] - previousSpatial[element])
                )
            }
            previousSpatial = currentSpatial
        }
        XCTAssertLessThanOrEqual(
            maximumSpatialStep, 128,
            "Rapid horizontal and height motion must remain a bounded per-sample ramp"
        )
        XCTAssertEqual(
            coder.matrixRenderCoefficients(at: 1_535),
            coder.matrixRenderCoefficients(at: 1_536),
            "The compatibility matrix must begin the OAMD ramp without a boundary step"
        )
        XCTAssertEqual(
            coder.matrixRenderCoefficients(at: 1_536),
            coder.matrixRenderCoefficients(at: 3_071)
        )
        let firstMetadata = try XCTUnwrap(coder.metadataUpdates(
            frameStart: 0, programmeStart: 0, programmeEnd: 3_072
        ).first)
        let secondMetadata = try XCTUnwrap(coder.metadataUpdates(
            frameStart: 1_536, programmeStart: 0, programmeEnd: 3_072
        ).first)
        XCTAssertEqual(firstMetadata.positions, secondMetadata.positions)
    }

    func testSpatialCoderLimitsOverloadsWithoutWholeProgramAttenuation() throws {
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
            4
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
        XCTAssertEqual(cache.headroomShift, 4)
        XCTAssertEqual(cache.limiterGains.count, 80)
        XCTAssertTrue(cache.limiterGains.allSatisfy { $0 < UInt32(1) << 30 })
        let data = try Data(contentsOf: cache.url)
        let unscaled = data.withUnsafeBytes {
            Array($0.bindMemory(to: Int64.self))
        }
        let cachedSamples = coder.quantize(
            unscaledSamples: unscaled,
            limiterGains: cache.limiterGains[
                cache.limiterGains.startIndex..<cache.limiterGains.endIndex
            ]
        )

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

        let quietReader = TestAudioReader(
            channelCount: channels.count,
            frameCount: 80,
            sample: 0x0000_1000,
            metadata: metadata
        )
        let quietCache = try coder.prepareElementCache(
            reader: quietReader, startFrame: 0, frameCount: 80
        )
        defer { try? FileManager.default.removeItem(at: quietCache.url) }
        XCTAssertTrue(
            quietCache.limiterGains.allSatisfy { $0 == UInt32(1) << 30 },
            "Signals inside the 20-bit matrix range must retain unity gain"
        )

        var transient = [Int32](
            repeating: 0, count: 4_096 * channels.count
        )
        for channel in 8..<channels.count {
            transient[2_048 * channels.count + channel] = 0x007F_FFFF
        }
        let transientReader = TestAudioReader(
            channelCount: channels.count,
            interleavedSamples: transient,
            metadata: metadata
        )
        let transientCache = try coder.prepareElementCache(
            reader: transientReader, startFrame: 0, frameCount: 4_096
        )
        defer { try? FileManager.default.removeItem(at: transientCache.url) }
        let unity = UInt32(1) << 30
        var maximumAttackDelta: UInt32 = 0
        var maximumReleaseDelta: UInt32 = 0
        for index in 1..<transientCache.limiterGains.count {
            let previous = transientCache.limiterGains[index - 1]
            let current = transientCache.limiterGains[index]
            if current < previous {
                maximumAttackDelta = max(maximumAttackDelta, previous - current)
            } else {
                maximumReleaseDelta = max(maximumReleaseDelta, current - previous)
            }
        }
        XCTAssertLessThanOrEqual(maximumAttackDelta, unity / 1_024 + 128)
        XCTAssertLessThanOrEqual(maximumReleaseDelta, unity / 4_800 + 128)
        XCTAssertLessThan(transientCache.limiterGains[2_048], unity)
    }

    func testAtmosStereoSerializesHalfGainWithoutChangingTransportPCM() throws {
        let formats = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006",
            "AC_00011009", "AC_0001100a"
        ]
        let metadata = ADMMetadata(channels: formats.map {
            ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
        })
        for depth in 17...20 {
            let configuration = TrueHDEncoderConfiguration()
            configuration.frameRate = .fps24
            let reader = TestAudioReader(
                channelCount: 10, frameCount: 40,
                samplesByChannel: [0, 262_144, -262_144, 0, 0, 0, 0, 0, 0, 0],
                metadata: metadata
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("turehda-stereo-\(UUID().uuidString).mlp")
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try AtmosBitstreamEncoder(
                configuration: configuration, elementBitDepth: depth
            ).encode(reader: reader, outputURL: url, overwrite: false, progress: nil)
            let bytes = [UInt8](try Data(contentsOf: url))
            let directory = 36
            var payload = directory
            for _ in 0..<4 {
                payload += bytes[payload] & 0x80 == 0 ? 2 : 4
            }
            var bits = TestBitReader(Array(bytes[payload...]))
            XCTAssertEqual(bits.read(2), 3) // Restart block and header.
            // Fixed restart fields, two assignments and the restart CRC.
            bits.skip(14 + 16 + 4 * 4 + 23 + 4 + 5 * 3 + 1 + 8 + 1 + 15 + 12 + 8)
            XCTAssertEqual(bits.read(1), 0) // Default guards.
            XCTAssertEqual(bits.read(1), 1)
            XCTAssertEqual(bits.read(9), 8)
            XCTAssertEqual(bits.read(1), 0) // The shared stereo PCM has no matrix.
            XCTAssertEqual(bits.read(1), 1)
            XCTAssertEqual(bits.read(4), UInt64(23 - depth))
            XCTAssertEqual(bits.read(4), UInt64(23 - depth))
        }
    }

    func testSurroundLiftingRecoversSignedImmersivePCM() {
        var seed: UInt64 = 0x3141_5926
        for count in [12, 14, 16] {
            for _ in 0..<200 {
                let original = (0..<count).map { _ -> Int32 in
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1
                    return Int32(truncatingIfNeeded: seed >> 32) % 65_536
                }
                let transport = AtmosCompatibilityMatrix.transportSamples(
                    standardSamples: original, channelCount: count
                )
                let decoded = AtmosCompatibilityMatrix.immersiveOutput(
                    transport[...], renderCoefficients: Array(
                        repeating: [Int32](repeating: 0, count: 8), count: count - 8
                    )
                )
                for speaker in 0..<8 {
                    XCTAssertEqual(
                        decoded[AtmosCompatibilityMatrix.matrixChannel(forSpeakerChannel: speaker)],
                        original[speaker]
                    )
                }
                XCTAssertEqual(Array(decoded.dropFirst(8)), Array(original.dropFirst(8)))
            }
        }
    }

    func testHeightBedDefaultsUseFullHeightWithoutOppositeSideLeakage() throws {
        let formats = [
            "AC_00011004", "AC_00011001", "AC_00011002", "AC_00011003",
            "AC_00011007", "AC_00011008", "AC_00011005", "AC_00011006",
            "AC_00011009", "AC_0001100a"
        ]
        let coder = try AtmosSpatialCoder(
            metadata: ADMMetadata(channels: formats.map {
                ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: [])
            }), sourceChannelCount: 10, elementBitDepth: 20
        )
        for (sourceChannel, heightElement) in [(8, 10), (9, 11)] {
            var source = [Int32](repeating: 0, count: 10)
            source[sourceChannel] = 1_048_576
            let encoded = coder.encode(source: source, frameCount: 1, sourceStartFrame: 0)
            XCTAssertEqual(encoded.samples[heightElement], 65_536)
            let transport = AtmosCompatibilityMatrix.transportSamples(
                standardSamples: encoded.samples, channelCount: 16
            )
            let immersive = AtmosCompatibilityMatrix.immersiveOutput(
                transport[...], renderCoefficients: coder.matrixRenderCoefficients
            )
            XCTAssertEqual(immersive[heightElement], 65_536)
            XCTAssertTrue(immersive.enumerated().allSatisfy {
                $0.offset == heightElement || $0.element == 0
            })
        }
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
            XCTAssertEqual(coder.matrixRenderCoefficients.count, count - 8)
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

    private let samplesByChannel: [Int32]
    private let interleavedSamples: [Int32]?
    private var currentFrame: UInt64 = 0

    init(channelCount: Int, frameCount: UInt64, sample: Int32, metadata: ADMMetadata) {
        self.samplesByChannel = [Int32](repeating: sample, count: channelCount)
        interleavedSamples = nil
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
        admMetadata = metadata
    }

    init(
        channelCount: Int,
        frameCount: UInt64,
        samplesByChannel: [Int32],
        metadata: ADMMetadata
    ) {
        precondition(samplesByChannel.count == channelCount)
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
        self.samplesByChannel = samplesByChannel
        interleavedSamples = nil
        admMetadata = metadata
    }

    init(
        channelCount: Int,
        interleavedSamples: [Int32],
        metadata: ADMMetadata
    ) {
        precondition(interleavedSamples.count.isMultiple(of: channelCount))
        format = WaveFormat(
            sampleRate: 48_000,
            channelCount: channelCount,
            bitsPerSample: 24,
            validBitsPerSample: 24,
            blockAlignment: channelCount * 3,
            channelMask: 0,
            isBigEndian: false
        )
        frameCount = UInt64(interleavedSamples.count / channelCount)
        samplesByChannel = [Int32](repeating: 0, count: channelCount)
        self.interleavedSamples = interleavedSamples
        admMetadata = metadata
    }

    func readFrames(maxCount: Int) throws -> PCMFrameBlock {
        let count = Int(min(UInt64(maxCount), frameCount - currentFrame))
        let startFrame = Int(currentFrame)
        currentFrame += UInt64(count)
        if let interleavedSamples {
            let start = startFrame * format.channelCount
            let end = (startFrame + count) * format.channelCount
            return PCMFrameBlock(
                samples: Array(interleavedSamples[start..<end]), frameCount: count
            )
        }
        return PCMFrameBlock(
            samples: Array(repeating: samplesByChannel, count: count).flatMap { $0 },
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

    mutating func readVariable(groupBits: Int) -> UInt64 {
        var value = read(groupBits)
        var continues = read(1) != 0
        while continues {
            value = (value + 1) << UInt64(groupBits)
            value += read(groupBits)
            continues = read(1) != 0
        }
        return value
    }
}

private func oamdObjectElementReader(_ bytes: [UInt8]) -> TestBitReader {
    var reader = TestBitReader(bytes)
    XCTAssertEqual(reader.read(2), 0)
    let objectCountBits = reader.read(5)
    if objectCountBits == 31 { _ = reader.read(7) }
    XCTAssertEqual(reader.read(1), 1)
    XCTAssertEqual(reader.read(1), 1)
    XCTAssertEqual(reader.read(1), 0)
    let elementCountBits = reader.read(4)
    if elementCountBits == 15 { _ = reader.read(5) }
    XCTAssertEqual(reader.read(4), 1)
    _ = reader.readVariable(groupBits: 4)
    return reader
}

private func readOAMDPosition(_ reader: inout TestBitReader) -> ADMPosition {
    let x = Double(reader.read(6)) / 31.0 - 1
    let y = 1 - Double(reader.read(6)) / 31.0
    let positiveZ = reader.read(1) != 0
    let zMagnitude = Double(reader.read(4)) / 15.0
    XCTAssertEqual(reader.read(1), 0)
    return ADMPosition(x: x, y: y, z: positiveZ ? zMagnitude : -zMagnitude)
}

private func readOAMDPositions(
    _ bytes: [UInt8],
    positionCount: Int
) -> [ADMPosition] {
    var reader = oamdObjectElementReader(bytes)
    reader.skip(15) // required flag, timing block, and reserved-data flag
    var positions = [ADMPosition]()
    positions.reserveCapacity(max(0, positionCount - 1))
    for index in 0..<positionCount {
        XCTAssertEqual(reader.read(1), 0) // active
        _ = reader.read(2) // gain
        _ = reader.read(1) // priority
        if index != 0 {
            positions.append(readOAMDPosition(&reader))
            reader.skip(3 + 1 + 2 + 1 + 1) // zone, elevation, size, screen, snap
        }
        XCTAssertEqual(reader.read(1), 0) // no additional table data
    }
    return positions
}
