// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.
import Foundation
import XCTest
@testable import libtruehda

final class AtmosObjectModeTests: XCTestCase {
    func testPublicConfigurationDefaultsToDynamicAndPreservesExplicitChannelbase() {
        XCTAssertEqual(TrueHDEncoderConfiguration().objectMode, .dynamic)
        XCTAssertEqual(TrueHDEncoderConfiguration(spatialClusterCount: 12).objectMode, .dynamic)
        let legacySelector = TrueHDEncoderConfiguration(spatialClusterCount: 14,
            firstFrameOfAction: "00:00:00:00", frameRate: .input, drcProfile: .filmLight,
            predictionMode: .auto, dialogueNormalization: 31)
        XCTAssertEqual(legacySelector.objectMode, .dynamic)
        let fixed = TrueHDEncoderConfiguration(objectMode: .channelbase)
        XCTAssertEqual((fixed.copy() as! TrueHDEncoderConfiguration).objectMode, .channelbase)
    }

    func testMovingCoordinateBridgeRetainsQ15BeforeOAMDQuantization() {
        // The input steps lie exactly on Q15. Their filtered intermediate
        // positions distinguish the metadata bridge from direct grid rounding.
        let units = [0.00806612465098842, 0.040324193173516834,
                     0.508066128973014, 0.9758080517309349]
        for (unit, expected) in zip(units, [0, 2, 31, 60]) {
            let position = AtmosAggregatePlanner.quantize(.init(x: unit * 2 - 1, y: 1, z: 0))
            XCTAssertEqual(31 + Int((position.x * 31).rounded()), expected)
        }
    }

    func testSpatialPrecisionRetriesPreserveIndependentLFESamples() throws {
        let reader = MovingAggregateReader()
        for count in [12, 14, 16] {
            for depth in [20, 19, 18, 17] {
                let coder = try AtmosSpatialCoder(metadata: reader.admMetadata!, sourceChannelCount: 11,
                    elementBitDepth: depth, spatialClusterCount: count, objectMode: .dynamic)
                for value: Int32 in [16, -16, 4_000_016, -4_000_016] {
                    var samples = [Int32](repeating: 0, count: 11)
                    samples[3] = value
                    let output = coder.encode(source: samples, frameCount: 1, sourceStartFrame: 0)
                    XCTAssertEqual(output.samples[3], value >> 4)
                    XCTAssertEqual(output.samples.filter { $0 != 0 }.count, 1)
                }
            }
        }
    }

    func testLosslessElementLiftingReconstructsEverySampleAndIsolatesLFE() {
        for channels in [12, 14, 16] {
            let frames = 193
            var samples = [Int32]()
            for frame in 0..<frames {
                let base = Int32((frame * 7_919) % 200_003 - 100_001)
                for channel in 0..<channels {
                    samples.append(channel == 3 ? Int32(frame * 613 - 41_111)
                        : (channel.isMultiple(of: 2) ? base : -base) + Int32(channel * (frame % 7)))
                }
            }
            let steps = AtmosLosslessLift.plan(samples: samples, channels: channels)
            XCTAssertFalse(steps.isEmpty)
            XCTAssertTrue(steps.allSatisfy { $0.reference < $0.target && $0.reference != 3 && $0.target != 3 })
            let coded = AtmosLosslessLift.apply(steps, samples: samples, channels: channels)
            let rows = AtmosLosslessLift.rows(steps, channels: channels)
            var decoded = coded
            for base in stride(from: 0, to: samples.count, by: channels) {
                XCTAssertEqual(coded[base + 3], samples[base + 3])
                for row in rows {
                    var sum: Int64 = 0
                    for channel in 0..<channels { sum += Int64(decoded[base + channel]) * Int64(row.coefficients[channel]) }
                    decoded[base + row.outputChannel] = Int32(sum >> AtmosCompatibilityMatrix.fractionalBits)
                }
            }
            XCTAssertEqual(decoded, samples)
        }
    }

    func testSilentTrajectoryRecordsPreserveTheLastAudibleTransition() {
        let origin = ADMPosition(x: -1, y: 1, z: 0)
        let tail = ADMPosition(x: 0, y: 0, z: 1)
        let quiet = ADMPosition(x: 1, y: -1, z: 0)
        var state = AtmosCentroidTransition.MetadataState(position: origin)
        XCTAssertEqual(state.advance(to: origin, direction: -1, silent: false).x, origin.x)
        XCTAssertEqual(state.advance(to: tail, direction: 0, silent: true).x, origin.x)
        // The preceding record was audible: the first silent record still
        // carries the trajectory's tail into the next output interval.
        XCTAssertEqual(state.pending.x, tail.x)
        XCTAssertEqual(state.advance(to: quiet, direction: 0, silent: true).x, tail.x)
        XCTAssertEqual(state.pending.x, tail.x)
        XCTAssertEqual(state.advance(to: quiet, direction: -1, silent: false).x, quiet.x)
    }

    func testAggregatePrecisionIsReducedAfterCoherentSummation() throws {
        var channels = Array(MovingAggregateReader().admMetadata!.channels.prefix(10))
        for index in 0..<2 {
            channels.append(ADMChannelMetadata(channelFormatID: "TEST_OBJECT_\(index)", isObject: true,
                blocks: [ADMPositionBlock(startFrame: 0, endFrame: .max,
                                          position: .init(x: -1, y: 1, z: 0))]))
        }
        let coder = try AtmosSpatialCoder(metadata: ADMMetadata(channels: channels), sourceChannelCount: 12,
                                          elementBitDepth: 20, spatialClusterCount: 12, objectMode: .dynamic)
        for sample: Int32 in [8, -8] {
            var pcm = [Int32](repeating: 0, count: 12)
            pcm[10] = sample; pcm[11] = sample
            let encoded = coder.encode(source: pcm, frameCount: 1, sourceStartFrame: 0)
            XCTAssertEqual(encoded.samples[0], sample > 0 ? 1 : -1)
            XCTAssertTrue(encoded.samples.dropFirst().allSatisfy { $0 == 0 })
        }
    }

    func testCentroidTransitionUsesCoherentOverlapEnergy() {
        let frames = 1_536
        let input: [Int32] = (0..<frames).flatMap { _ in [Int32(123_456), Int32(-123_456)] }
        let (silent, audible) = AtmosCentroidTransition.energies(samples: input, frames: frames,
            channels: 2, sources: [0, 1], previous: [1, 1], current: [1, 0], elements: 1)
        XCTAssertEqual(silent[0], 0)
        XCTAssertGreaterThan(audible[0], 0)
        let old = ADMPosition(x: -1, y: 1, z: 0), new = ADMPosition(x: 1, y: -1, z: 1)
        XCTAssertEqual(AtmosCentroidTransition.direction(previous: old, current: new,
            previousLeader: 0, currentLeader: 1, wasActive: true, isActive: true,
            previousEnergy: silent[0], currentEnergy: audible[0]), -1)
        XCTAssertEqual(AtmosCentroidTransition.direction(previous: old, current: new,
            previousLeader: 0, currentLeader: 1, wasActive: true, isActive: true,
            previousEnergy: audible[0], currentEnergy: silent[0]), 1)
    }

    func testDiffuseReaderPreservesLFEAndPassThroughAcrossUnevenReadsAndSeek() throws {
        let source = MovingAggregateReader()
        let processed = try AtmosPreprocessedReader(source: source)
        let reference = MovingAggregateReader()
        for count in [17, 511, 1_007, 2_049, 63] {
            let expected = try reference.readFrames(maxCount: count)
            let actual = try processed.readFrames(maxCount: count)
            XCTAssertEqual(actual.frameCount, expected.frameCount)
            for frame in 0..<actual.frameCount {
                XCTAssertEqual(Array(actual.samples[(frame * 22)..<(frame * 22 + 11)]),
                               Array(expected.samples[(frame * 11)..<(frame * 11 + 11)]))
                XCTAssertTrue(actual.samples[(frame * 22 + 11)..<(frame * 22 + 22)].allSatisfy { $0 == 0 })
            }
        }
        try processed.seek(toFrame: 0)
        try reference.seek(toFrame: 0)
        let expected = try reference.readFrames(maxCount: 513)
        let actual = try processed.readFrames(maxCount: 513)
        for frame in 0..<513 { XCTAssertEqual(actual.samples[frame * 22 + 3], expected.samples[frame * 11 + 3]) }
    }

    func testSpeakerBasisRetainsWideAndHeightDirectionsForEachBudget() {
        let maximum = 32_767.0 / 32_768.0
        let wide = ADMPosition(x: -1, y: 1 - 2 * 5_285.0 / 32_768.0, z: 0)
        for count in [11, 13, 15] {
            let front = AtmosSpeakerBasis.gains(at: .init(x: -0.5, y: 1, z: 0), count: count)
            XCTAssertEqual(front[0], sqrt(0.5), accuracy: 1e-7)
            XCTAssertEqual(front[2], sqrt(0.5), accuracy: 1e-7)
            let rear = AtmosSpeakerBasis.gains(at: .init(x: -0.5, y: -1, z: 1), count: count)
            // Independent static-control measurements include the Q15 endpoint.
            XCTAssertEqual(rear[count - 2], 0.9238749, accuracy: 2e-7)
            XCTAssertEqual(rear[count - 1], 0.3826945, accuracy: 2e-7)
            XCTAssertEqual(rear.prefix(count == 11 ? 7 : 9).reduce(0, +), 0)
            let wideGains = AtmosSpeakerBasis.gains(at: wide, count: count)
            if count > 11 { XCTAssertEqual(wideGains[7], 1, accuracy: 1e-12) }
            for point in [wide, ADMPosition(x: 0.23, y: -0.61, z: maximum),
                          ADMPosition(x: -0.42, y: 0.38, z: 0.57)] {
                let gains = AtmosSpeakerBasis.gains(at: point, count: count)
                XCTAssertEqual(gains.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-10)
            }
        }
    }

    func testImageMixerDoesNotDuplicateCoincidentOrUnreachableSourceEnergy() {
        for count in [11, 13, 15] {
            let point = ADMPosition(x: -0.37, y: 0.29, z: 0.61)
            for centres in [[point, point], [ADMPosition(x: -1, y: 1, z: 0)],
                            [ADMPosition(x: -1, y: 1, z: 1), ADMPosition(x: 1, y: -1, z: 0)]] {
                let weights = AtmosImageMixer.weights(for: point, centres: centres, basisCount: count)
                XCTAssertTrue(weights.allSatisfy { $0.isFinite && $0 >= 0 })
                let basis = centres.map { AtmosSpeakerBasis.gains(at: $0, count: count) }
                let field = (0..<count).map { row in
                    weights.indices.reduce(0.0) { $0 + weights[$1] * basis[$1][row] }
                }
                XCTAssertEqual(field.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-5)
            }
        }
    }

    func testNearbyCentroidsRetainDistinctElevatedDirections() {
        // Synthetic near-coincident centres: retaining the slight elevation
        // gives the mixer a vertical contribution absent from the floor basis.
        var centres = [
            ADMPosition(x: -1, y: 1, z: 0), ADMPosition(x: 1, y: 1, z: 0),
            ADMPosition(x: 0, y: 1, z: 0), ADMPosition(x: -1, y: 0, z: 0),
            ADMPosition(x: 1, y: 0, z: 0), ADMPosition(x: -1, y: -1, z: 0),
            ADMPosition(x: 1, y: -1, z: 0)
        ]
        centres.append(ADMPosition(x: 0, y: 1, z: 0.01))
        let gains = AtmosImageMixer.weights(for: .init(x: 0, y: 1, z: 1),
                                            centres: centres, basisCount: 11)
        XCTAssertGreaterThan(gains[7], 0.5)
        let basis = centres.map { AtmosSpeakerBasis.gains(at: $0, count: 11) }
        let field = (0..<11).map { c in centres.indices.reduce(0.0) { $0 + gains[$1] * basis[$1][c] } }
        XCTAssertGreaterThan(field[7] + field[8], 0)
        XCTAssertEqual(field.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-5)
    }

    func testTrajectoryControlClockMatchesMovingReferenceCoordinates() {
        var sampler = AtmosTrajectorySampler(initial: [ADMPosition(x: -1, y: 1, z: 1)])
        let expected = [45, 57, 61, 62]
        for (index, frame) in [47_616, 49_152, 50_688, 52_224].enumerated() {
            let points = sampler.targets(at: UInt64(frame)) { sample in
                [sample < 48_000 ? ADMPosition(x: -1, y: 1, z: 1) : ADMPosition(x: 1, y: 1, z: 1)]
            }
            XCTAssertEqual(31 + Int((points[0].x * 31).rounded()), expected[index])
        }
        // An event exactly on the 512-sample clock belongs to the next interval.
        var aligned = AtmosTrajectorySampler(initial: [ADMPosition(x: -0.228, y: 0.526, z: 0.51)])
        let first = aligned.targets(at: 958_464) { sample in
            [sample < 960_000 ? ADMPosition(x: -0.228, y: 0.526, z: 0.51) : ADMPosition(x: -1, y: 1, z: 0)]
        }[0]
        XCTAssertEqual(31 + Int((first.x * 31).rounded()), 24)
        XCTAssertEqual(31 - Int((first.y * 31).rounded()), 15)
        XCTAssertEqual(Int((first.z * 15).rounded()), 8)
    }

    func testUnusedCentroidsCannotStealATrackedMovingSource() {
        let anchors = [1, 2, 3, 6, 7, 4, 5].map { AtmosSpatialCoder.fixedElementPositions[$0] }
            + [ADMPosition(x: -1, y: 1, z: 1), ADMPosition(x: 1, y: 1, z: 1),
               ADMPosition(x: -1, y: -1, z: 1), ADMPosition(x: 1, y: -1, z: 1)]
        var centres = anchors
        var leaders = [Int](repeating: -1, count: anchors.count)
        var owner: Int?
        for point in [ADMPosition(x: -1, y: 1, z: 1), ADMPosition(x: 1, y: 1, z: 1),
                      ADMPosition(x: 0, y: 1, z: 0)] {
            let plan = AtmosAggregatePlanner.update(centres: &centres,
                                                     points: [point], energy: [1], leaders: &leaders)
            let active = plan.active.indices.filter { plan.active[$0] }
            XCTAssertEqual(active.count, 1)
            if let owner { XCTAssertEqual(active.first, owner) }
            owner = active.first
            let gains = plan.weights(for: point, source: 0)
            XCTAssertEqual(gains.filter { $0 != 0 }.count, 1)
            XCTAssertEqual(gains.reduce(0, +), 1)
        }
    }

    func testGainPlanPrefetchPreservesSourceAndIntervalBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: AtmosAggregateGainStore? = try AtmosAggregateGainStore(directory: directory,
                                                                         sourceCount: 2, elementCount: 11)
        for interval in 0..<10 {
            try store!.append((0..<22).map { Int32(interval * 100 + $0) })
        }
        try store!.prepareWindow(first: 3, last: 6)
        XCTAssertEqual(Array(store!.row(interval: 5, source: 1)), (11..<22).map { Int32(500 + $0) })
        try store!.prepareWindow(first: -1, last: 1)
        XCTAssertEqual(Array(store!.row(interval: -1, source: 0)), (0..<11).map(Int32.init))
        store = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testSignedOAMDQuantizationIsSymmetricAtHalfGridCoordinates() {
        let negative = AtmosAggregatePlanner.quantize(ADMPosition(x: -0.5, y: -0.5, z: 0.5))
        let positive = AtmosAggregatePlanner.quantize(ADMPosition(x: 0.5, y: 0.5, z: 0.5))
        XCTAssertEqual(negative.x, -16.0 / 31.0)
        XCTAssertEqual(negative.y, -16.0 / 31.0)
        XCTAssertEqual(positive.x, 16.0 / 31.0)
        XCTAssertEqual(positive.y, 16.0 / 31.0)
        XCTAssertEqual(negative.z, 8.0 / 15.0)
    }

    func testConfigurationCopyPreservesObjectModeAndLegacyInitializer() {
        let value = TrueHDEncoderConfiguration(spatialClusterCount: 14, objectMode: .dynamic)
        let copied = value.copy() as! TrueHDEncoderConfiguration
        value.objectMode = .channelbase
        XCTAssertEqual(copied.objectMode, .dynamic)
        XCTAssertEqual(copied.spatialClusterCount, 14)
        XCTAssertEqual(TrueHDObjectMode.allCases.map(\.commandLineName), ["dynamic", "channelbase"])
        let legacy = TrueHDEncoderConfiguration(spatialClusterCount: 12, firstFrameOfAction: "00:00:00:00",
                                               frameRate: .input, drcProfile: .filmLight,
                                               predictionMode: .fir2, dialogueNormalization: 31)
        XCTAssertEqual(legacy.predictionMode, .fir2)
    }

    func testDynamicAggregatesMoveAndChannelbaseStaysFixedForAllBudgets() throws {
        for count in [12, 14, 16] {
            for mode in TrueHDObjectMode.allCases {
                let reader = MovingAggregateReader()
                let coder = try AtmosSpatialCoder(metadata: reader.admMetadata!, sourceChannelCount: 11,
                                                  elementBitDepth: 20, spatialClusterCount: count, objectMode: mode)
                let cache = try coder.prepareElementCache(reader: reader, startFrame: 0, frameCount: reader.frameCount)
                defer { try? FileManager.default.removeItem(at: cache.url) }
                let first = coder.positions(at: 0), last = coder.positions(at: reader.frameCount - 1)
                XCTAssertEqual(first.count, count)
                XCTAssertEqual(first[0], ADMPosition(x: 0, y: 1, z: -1))
                XCTAssertEqual(first[0], last[0])
                if mode == .dynamic {
                    XCTAssertNotEqual(first, last)
                    XCTAssertEqual(coder.matrixRenderCoefficients(at: 3_072).count, count - 1)
                    let initial = try XCTUnwrap(coder.metadataUpdates(frameStart: 0, programmeStart: 0,
                                                                     programmeEnd: reader.frameCount).first)
                    XCTAssertEqual(initial.rampDuration, 1_536)
                } else {
                    XCTAssertEqual(first, last)
                    XCTAssertEqual(coder.matrixRenderCoefficients(at: 3_072).count, count - 8)
                }
            }
        }
    }


}

private final class MovingAggregateReader: TrueHDAudioReader {
    let format = WaveFormat(sampleRate: 48_000, channelCount: 11, bitsPerSample: 24,
                            validBitsPerSample: 24, blockAlignment: 33, channelMask: 0, isBigEndian: false)
    let frameCount: UInt64 = 12_288
    let admXML: Data? = nil
    let admChannelAssignment: Data? = nil
    let sourceFrameRate: TrueHDFrameRate? = nil
    let admMetadata: ADMMetadata?
    private var cursor: UInt64 = 0
    init() {
        let ids = ["AC_00011001", "AC_00011002", "AC_00011003", "AC_00011004", "AC_00011005",
                   "AC_00011006", "AC_00011007", "AC_00011008", "AC_00011009", "AC_0001100a"]
        var channels = ids.map { ADMChannelMetadata(channelFormatID: $0, isObject: false, blocks: []) }
        channels.append(ADMChannelMetadata(channelFormatID: "AC_00031001", isObject: true, blocks: [
            ADMPositionBlock(startFrame: 0, endFrame: 6_144, position: ADMPosition(x: -1, y: 1, z: 1), interpolatesToNext: true),
            ADMPositionBlock(startFrame: 6_144, endFrame: .max, position: ADMPosition(x: 1, y: -1, z: 0.4))
        ]))
        admMetadata = ADMMetadata(channels: channels)
    }
    func seek(toFrame frame: UInt64) throws { cursor = frame }
    func readFrames(maxCount: Int) throws -> PCMFrameBlock {
        let count = Int(min(UInt64(maxCount), frameCount - cursor))
        var samples = [Int32](repeating: 0, count: count * 11)
        for i in 0..<count { samples[i * 11 + 10] = 32_768; samples[i * 11 + 3] = -16_384 }
        cursor += UInt64(count)
        return PCMFrameBlock(samples: samples, frameCount: count)
    }
}
