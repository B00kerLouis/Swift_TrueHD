// SPDX-License-Identifier: AGPL-3.0-only

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
            drcProfile: .filmLight
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
            encoderName: "Swift TrueHD Native Atmos"
        )

        let manifest = try String(contentsOf: result.manifestURL, encoding: .utf8)
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        XCTAssertTrue(manifest.contains("<spatial-clusters>14</spatial-clusters>"))
        XCTAssertTrue(manifest.contains("<source-frame-rate>24</source-frame-rate>"))
        XCTAssertTrue(manifest.contains("<frame-rate>25</frame-rate>"))
        XCTAssertTrue(manifest.contains("<drc-profile>film_light</drc-profile>"))
        XCTAssertTrue(manifest.contains("generator=\"Swift TrueHD Native Atmos\""))
        XCTAssertTrue(manifest.contains("<automatic-compliance>"))
        XCTAssertTrue(log.contains("First frame of action: 00:00:00:00"))
    }
}
