// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import Swift_TrueHD

final class MLPHuffmanTests: XCTestCase {
    func testConstantBlockInheritsOffsetWithoutRedundantSignal() {
        let samples = [Int32](repeating: 1_234, count: 40)
        let first = MLPHuffman.select(samples: samples, previousOffset: 0)

        XCTAssertEqual(first.offset, 1_234)
        XCTAssertTrue(first.writesOffset)

        let inherited = MLPHuffman.select(samples: samples, previousOffset: first.offset)
        XCTAssertEqual(inherited.offset, first.offset)
        XCTAssertEqual(inherited.payloadBitCount, first.payloadBitCount)
        XCTAssertFalse(inherited.writesOffset)
    }

    func testReturningToZeroOffsetIsExplicitlySignalled() {
        let samples: [Int32] = [-12, -4, 0, 4, 12]
        let parameters = MLPHuffman.select(samples: samples, previousOffset: 1_234)

        XCTAssertNotEqual(parameters.offset, 1_234)
        XCTAssertTrue(parameters.writesOffset)
    }

    func testPayloadWriterEmitsSelectedPayloadBitCount() {
        let samples: [Int32] = [
            -9, -4, -1, 0, 0, 1, 3, 8,
            -8, -2, 0, 2, 7, -3, 1, 4
        ]
        let parameters = MLPHuffman.select(samples: samples)
        var writer = BitWriter()
        for sample in samples {
            MLPHuffman.write(sample: sample, parameters: parameters, to: &writer)
        }

        XCTAssertEqual(writer.bitCount, parameters.payloadBitCount)
    }

    func testFirstOrderPredictionSelectsRealResidualsForRamp() {
        let samples = (1...40).map(Int32.init)
        let decision = MLPPredictiveCoding.select(
            rawSamples: samples,
            history: [Int32](
                repeating: 0, count: MLPPredictiveCoding.historyLength
            ),
            previousOffset: 0,
            activeFIR: nil,
            allowPrediction: true
        )

        XCTAssertEqual(decision.fir?.coefficients, [512, -256])
        XCTAssertEqual(decision.fir?.shift, 8)
        XCTAssertTrue(decision.writesFIR)
        XCTAssertEqual(decision.samples, [Int32(1)] + [Int32](repeating: 0, count: 39))
        XCTAssertEqual(decision.finalHistory, Array((33...40).reversed()).map(Int32.init))
    }

    func testPredictionCanBeDisabledWhileUpdatingHistory() {
        let samples: [Int32] = [7, 11, 5, -3]
        let decision = MLPPredictiveCoding.select(
            rawSamples: samples,
            history: [99] + [Int32](
                repeating: 0, count: MLPPredictiveCoding.historyLength - 1
            ),
            previousOffset: 0,
            activeFIR: nil,
            allowPrediction: false
        )

        XCTAssertNil(decision.fir)
        XCTAssertEqual(decision.samples, samples)
        XCTAssertEqual(decision.finalHistory, [-3, 5, 11, 7, 99, 0, 0, 0])
    }
}
