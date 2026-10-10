// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research

import Foundation
import XCTest
@testable import libtruehda

final class NativeComplianceTests: XCTestCase {
    func testDRCProfileDefaultsToFilmLightAndExposesStableNames() {
        XCTAssertEqual(TrueHDEncoderConfiguration().drcProfile, .filmLight)
        XCTAssertEqual(TrueHDDRCProfile.allCases.map(\.commandLineName), [
            "film_standard", "film_light", "music_standard", "music_light", "speech"
        ])
    }

    func testDRCProfilesUsePublishedContinuousTransferCurves() {
        XCTAssertEqual(
            TrueHDDRCProfile.filmStandard.gainDB(
                forWeightedLevel: -43, dialogueNormalization: 31
            ),
            6,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TrueHDDRCProfile.filmStandard.gainDB(
                forWeightedLevel: -31, dialogueNormalization: 31
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TrueHDDRCProfile.filmLight.gainDB(
                forWeightedLevel: -26, dialogueNormalization: 31
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TrueHDDRCProfile.musicLight.gainDB(
                forWeightedLevel: -65, dialogueNormalization: 31
            ),
            12,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TrueHDDRCProfile.speech.gainDB(
                forWeightedLevel: -50, dialogueNormalization: 31
            ),
            15,
            accuracy: 0.000_001
        )
    }

    func testFilmLightNullBandAndCutMatchOfficialProfile() {
        for level in [-41.0, -31.0, -26.0, -21.0] {
            XCTAssertEqual(TrueHDDRCProfile.filmLight.gainDB(
                forWeightedLevel: level, dialogueNormalization: 31
            ), 0, accuracy: 0.000_001)
        }
        XCTAssertEqual(TrueHDDRCProfile.filmLight.gainDB(
            forWeightedLevel: -16, dialogueNormalization: 31
        ), -2.5, accuracy: 0.000_001)
        XCTAssertEqual(TrueHDDRCProfile.filmLight.gainDB(
            forWeightedLevel: -11, dialogueNormalization: 31
        ), -5, accuracy: 0.000_001)
    }

    func testDRCGainWordUsesSignedLog2UnitsAndInterpolationCode() {
        XCTAssertEqual(TrueHDDynamicRangeControl.gainCode(forDecibels: 0), 0)
        XCTAssertEqual(TrueHDDynamicRangeControl.extraWord(gainCode: 7), 0x03F0)
        XCTAssertEqual(TrueHDDynamicRangeControl.extraWord(gainCode: -28), 0xF270)
    }

    func testDRCAnalyzerProducesRealProfileDependentStartupGains() {
        let samples = [Int32](repeating: 0, count: 40 * 8)
        func firstGain(_ profile: TrueHDDRCProfile) -> Int? {
            var analyzer = TrueHDDynamicRangeControl(
                profile: profile,
                channelCount: 8,
                presentationMaximumChannels: [1, 5, 7]
            )
            return analyzer.updates(samples: samples, frameCount: 40, accessUnit: 0)[0]
        }

        XCTAssertEqual(firstGain(.filmStandard), 7)
        XCTAssertEqual(firstGain(.filmLight), 7)
        XCTAssertEqual(firstGain(.musicStandard), 13)
        XCTAssertEqual(firstGain(.musicLight), 13)
        XCTAssertEqual(firstGain(.speech), 64)
    }

    func testDRCUsesDecodedMatrixLFEPosition() throws {
        func gain(activeChannel: Int?) throws -> Int {
            var analyzer = TrueHDDynamicRangeControl(
                profile: .filmLight, channelCount: 6,
                presentationMaximumChannels: [5],
                dialogueNormalizations: [24], lfeChannel: 5
            )
            var samples = [Int32](repeating: 0, count: 40 * 6)
            if let channel = activeChannel {
                for frame in 0..<40 {
                    samples[frame * 6 + channel] = Int32((8_000_000 * sin(Double(frame) * .pi / 24)).rounded())
                }
            }
            return try XCTUnwrap(analyzer.updates(
                samples: samples, frameCount: 40, accessUnit: 0
            )[0])
        }
        XCTAssertEqual(try gain(activeChannel: 5), try gain(activeChannel: nil))
        XCTAssertLessThan(try gain(activeChannel: 3), 0)
    }

    func testConfigurationCopyPreservesPublicOptions() throws {
        let configuration = TrueHDEncoderConfiguration(
            spatialClusterCount: 14,
            firstFrameOfAction: "00:00:10:00",
            frameRate: .fps25,
            drcProfile: .musicStandard
        )

        let copy = try XCTUnwrap(configuration.copy() as? TrueHDEncoderConfiguration)

        XCTAssertEqual(copy.spatialClusterCount, 14)
        XCTAssertEqual(copy.firstFrameOfAction, "00:00:10:00")
        XCTAssertEqual(copy.frameRate, .fps25)
        XCTAssertEqual(copy.drcProfile, .musicStandard)
    }

    func testAtmosConfigurationCreatesNativeEncoder() throws {
        let configuration = TrueHDEncoderConfiguration()
        XCTAssertNoThrow(try AtmosBitstreamEncoder(configuration: configuration))
    }

    func testAtmosConfigurationRejectsUnsupportedSpatialClusterCount() {
        let configuration = TrueHDEncoderConfiguration()
        configuration.spatialClusterCount = 13
        XCTAssertThrowsError(try AtmosBitstreamEncoder(configuration: configuration))
    }

    func testAtmosPeakRateUsesThreeKilobitCeilingUnits() {
        XCTAssertEqual(AtmosBitstreamEncoder.codedPeakRate(9_060_000), 3_020)
        XCTAssertEqual(AtmosBitstreamEncoder.codedPeakRate(9_058_462), 3_020)
        XCTAssertEqual(AtmosBitstreamEncoder.codedPeakRate(3_001), 2)
    }

    func testTransportTimingMatchesDEEPeakRateSchedule() {
        XCTAssertEqual(
            MLPTransportTiming.inputTimings(
                byteCounts: [1_218, 344, 336],
                codedPeakRate: 3_020
            ),
            [
                UInt16(truncatingIfNeeded: -52),
                0,
                40,
            ]
        )

        // Two consecutive access units that each require 43 samples at the
        // declared peak must be scheduled backwards without overlapping.
        XCTAssertEqual(
            MLPTransportTiming.inputTimings(
                byteCounts: [1_000, 1_000, 100],
                codedPeakRate: 3_020
            ),
            [
                UInt16(truncatingIfNeeded: -46),
                UInt16(truncatingIfNeeded: -3),
                40,
            ]
        )
    }

    func testTransportPeakSelectionUsesDEESeventyFiveMillisecondWindow() throws {
        let plan = try MLPTransportTiming.makePlan(byteCounts: [1_218])
        XCTAssertEqual(plan.codedPeakRate, 44)
        XCTAssertEqual(plan.declaredPeakBitRate, 132_000)
        XCTAssertEqual(plan.maximumLeadSamples, 3_544)
        XCTAssertGreaterThan(
            MLPTransportTiming.maximumLead(
                byteCounts: [1_218],
                codedPeakRate: plan.codedPeakRate - 1
            ),
            MLPTransportTiming.maximumLeadSamples
        )
    }

    func testTransportRewriterUpdatesEveryHeaderAndMajorSync() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("transport.mlp")
        let majorSync = [UInt8](arrayLiteral: 0xF8, 0x72, 0x6F, 0xBA)
            + [UInt8](repeating: 0xA5, count: 28)
        let majorByteCount = 4 + majorSync.count + 6
        let minorByteCount = 4 + 6
        var file = [UInt8](repeating: 0, count: majorByteCount + minorByteCount)
        file[1] = UInt8(majorByteCount / 2)
        file.replaceSubrange(4..<8, with: [0xF8, 0x72, 0x6F, 0xBA])
        file[majorByteCount + 1] = UInt8(minorByteCount / 2)
        try Data(file).write(to: outputURL)

        let inputTimings = [
            UInt16(truncatingIfNeeded: -52),
            UInt16(0),
        ]
        try MLPTransportRewriter.rewrite(
            outputURL: outputURL,
            records: [
                MLPAccessUnitRecord(offset: 0, byteCount: majorByteCount),
                MLPAccessUnitRecord(
                    offset: UInt64(majorByteCount),
                    byteCount: minorByteCount
                ),
            ],
            plan: MLPTransportPlan(
                codedPeakRate: 3_020,
                inputTimings: inputTimings,
                maximumLeadSamples: 52
            ),
            majorSync: majorSync,
            substreamCount: 3,
            authenticateEvolution: false
        )

        let rewritten = [UInt8](try Data(contentsOf: outputURL))
        XCTAssertEqual(Array(rewritten[4..<(4 + majorSync.count)]), majorSync)
        for (index, base) in [0, majorByteCount].enumerated() {
            XCTAssertEqual(
                (UInt16(rewritten[base + 2]) << 8)
                    | UInt16(rewritten[base + 3]),
                inputTimings[index]
            )
            let lengthInWords = (UInt16(rewritten[base] & 0x0F) << 8)
                | UInt16(rewritten[base + 1])
            let directoryOffset = base + (index == 0 ? 4 + majorSync.count : 4)
            var parity = inputTimings[index] ^ lengthInWords
            for byte in rewritten[directoryOffset..<(directoryOffset + 6)] {
                parity ^= UInt16(byte)
            }
            parity ^= parity >> 8
            parity ^= parity >> 4
            XCTAssertEqual(
                UInt16(rewritten[base] >> 4),
                (parity & 0x0F) ^ 0x0F
            )
        }
    }

    func testTransportTimingMatchesCompleteOfficialStreamIfAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFT_TRUEHD_OFFICIAL_MLP"] else {
            throw XCTSkip("Set SWIFT_TRUEHD_OFFICIAL_MLP to validate transport timing")
        }
        let file = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        guard file.count >= 20,
              file[4..<8].elementsEqual([0xF8, 0x72, 0x6F, 0xBA]) else {
            XCTFail("Official stream does not start with a TrueHD major sync")
            return
        }

        let codedPeakRate = (Int(file[18] & 0x7F) << 8) | Int(file[19])
        var byteCounts = [Int]()
        var inputTimings = [UInt16]()
        var offset = 0
        while offset < file.count {
            guard offset + 4 <= file.count else {
                XCTFail("Official stream has a truncated access header")
                return
            }
            let byteCount = (
                (Int(file[offset] & 0x0F) << 8)
                    | Int(file[offset + 1])
            ) * 2
            guard byteCount >= 4, offset + byteCount <= file.count else {
                XCTFail("Official stream has an invalid access-unit length")
                return
            }
            byteCounts.append(byteCount)
            inputTimings.append(
                (UInt16(file[offset + 2]) << 8)
                    | UInt16(file[offset + 3])
            )
            offset += byteCount
        }

        XCTAssertEqual(
            MLPTransportTiming.inputTimings(
                byteCounts: byteCounts,
                codedPeakRate: codedPeakRate
            ),
            inputTimings
        )
        let plan = try MLPTransportTiming.makePlan(byteCounts: byteCounts)
        XCTAssertEqual(plan.codedPeakRate, codedPeakRate)
        XCTAssertLessThanOrEqual(
            plan.maximumLeadSamples,
            MLPTransportTiming.maximumLeadSamples
        )
        if codedPeakRate > 1 {
            XCTAssertGreaterThan(
                MLPTransportTiming.maximumLead(
                    byteCounts: byteCounts,
                    codedPeakRate: codedPeakRate - 1
                ),
                MLPTransportTiming.maximumLeadSamples
            )
        }
    }

    func testAtmosRestartNoiseSeedsMatchReferenceAtAccessUnit124() {
        let seeds: [UInt32] = [
            AtmosBitstreamEncoder.advancingNoiseGeneratorSeed(
                1, iterations: 124 * 120, leftShift: 16
            ),
            AtmosBitstreamEncoder.advancingNoiseGeneratorSeed(
                2, iterations: 124 * 64, leftShift: 16
            ),
            AtmosBitstreamEncoder.advancingNoiseGeneratorSeed(
                3, iterations: 124 * 64, leftShift: 16
            ),
            AtmosBitstreamEncoder.advancingNoiseGeneratorSeed(
                4, iterations: 124 * 64, leftShift: 8
            ),
        ]

        XCTAssertEqual(seeds.map { $0 & 0x007F_FFFF }, [
            7_413_404, 2_940_437, 8_040_719, 6_083_760,
        ])
    }

    func testDBMDFrameRateEnumerationIsReadFromSourceMetadata() {
        let expected: [(UInt8, TrueHDFrameRate)] = [
            (0x21, .fps23976), (0x22, .fps24), (0x23, .fps25),
            (0x24, .fps2997Drop), (0x25, .fps2997), (0x26, .fps30)
        ]
        for (code, frameRate) in expected {
            var dbmd = Data(repeating: 0, count: 0xDB)
            dbmd[0] = 0x06
            dbmd[1] = 0x00
            dbmd[0xDA] = code
            XCTAssertEqual(TrueHDFrameRate.fromDBMD(dbmd), frameRate)
        }
    }

    func testFFOAIsOutputTimecodeAndDoesNotTrimInput() throws {
        let timing = try TrueHDSourceTiming.resolve(
            frameRate: .fps24,
            firstFrameOfAction: "00:00:00:00",
            availableFrames: 96_000
        )
        XCTAssertEqual(timing.inputStartFrame, 0)
        XCTAssertEqual(timing.firstFrameOfAction, "00:00:00:00")
    }

    func testOutputFrameRateDefaultsToInputAndCanOverrideIt() {
        XCTAssertEqual(TrueHDOutputFrameRate.input.resolve(input: .fps24), .fps24)
        XCTAssertEqual(TrueHDOutputFrameRate.fps25.resolve(input: .fps24), .fps25)
    }

    func testCompanionManifestAndLogAreWritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("sample.mlp")
        let result = TrueHDEncodingResult(
            outputURL: output,
            profile: .atmos,
            sampleRate: 48_000,
            channelCount: 14,
            inputFrameCount: 96_000,
            outputByteCount: 1_000,
            sourceFrameRate: .fps24,
            outputFrameRate: .fps25,
            firstFrameOfAction: "00:00:00:00",
            spatialClusterCount: 14,
            elementBitDepth: 20,
            drcProfile: .filmLight,
            spatialAccuracy: TrueHDSpatialAccuracy(
                intervalCount: 63,
                maximumActiveSpatialSources: 9,
                groupedIntervalCount: 2,
                sourceIntervalCount: 100,
                exactlyRepresentedSourceIntervals: 97,
                assignmentChangeCount: 1,
                maximumQuantizedPositionError: 0.12345678,
                energyWeightedRMSQuantizedPositionError: 0.01234567
            )
        )
        let configuration = TrueHDEncoderConfiguration(
            spatialClusterCount: 14, frameRate: .fps25
        )
        try EncodingCompanionWriter.write(
            result: result,
            inputURL: directory.appendingPathComponent("input.wav"),
            configuration: configuration,
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1),
            encoderName: "libtruehda"
        )

        let manifest = try String(contentsOf: result.manifestURL, encoding: .utf8)
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        XCTAssertTrue(manifest.contains("<spatial-clusters>14</spatial-clusters>"))
        XCTAssertTrue(manifest.contains("<source-frame-rate>24</source-frame-rate>"))
        XCTAssertTrue(manifest.contains("<frame-rate>25</frame-rate>"))
        XCTAssertTrue(manifest.contains("<drc-profile>film_light</drc-profile>"))
        XCTAssertTrue(manifest.contains("generator=\"libtruehda\""))
        XCTAssertTrue(manifest.contains("<encode version=\"3\""))
        XCTAssertTrue(manifest.contains("<automatic-compliance>"))
        XCTAssertTrue(manifest.contains(
            "<available-spatial-elements>6</available-spatial-elements>"
        ))
        XCTAssertTrue(manifest.contains(
            "<maximum-quantized-xyz-deviation>0.12345678</maximum-quantized-xyz-deviation>"
        ))
        XCTAssertFalse(manifest.contains("xyz-error"))
        XCTAssertTrue(log.contains("First frame of action: 00:00:00:00"))
        XCTAssertTrue(log.contains("Fixed-basis spatial approximation"))
        XCTAssertTrue(log.contains("Fixed non-LFE rendering anchors: 13"))
        XCTAssertTrue(log.contains("Maximum quantized XYZ deviation: 0.12345678"))
        XCTAssertTrue(log.contains("Rendering-basis assignment changes: 1"))
        XCTAssertFalse(log.contains("XYZ error"))
    }
}
