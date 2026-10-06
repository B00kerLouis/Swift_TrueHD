// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Plans the MLP access-unit input timeline at the declared peak transport
// rate. Output timing remains the fixed 40-sample TrueHD cadence; input timing
// describes when each complete access unit must enter the decoder buffer.

import Foundation

struct MLPAccessUnitRecord: Sendable, Equatable {
    let offset: UInt64
    let byteCount: Int
}

struct MLPTransportPlan: Sendable, Equatable {
    let codedPeakRate: Int
    let inputTimings: [UInt16]
    let maximumLeadSamples: Int

    var declaredPeakBitRate: Int {
        codedPeakRate * 3_000
    }
}

enum MLPTransportTiming {
    static let samplesPerAccessUnit = 40

    // DEE constrains the scheduled input timeline to 75 ms at 48 kHz. Its
    // declared peak is the lowest 3 kbps code whose complete backwards
    // schedule stays inside this decoder-buffer window.
    static let maximumLeadSamples = 3_600
    static let maximumCodedPeakRate = 6_000

    static func makePlan(byteCounts: [Int]) throws -> MLPTransportPlan {
        guard !byteCounts.isEmpty, byteCounts.allSatisfy({ $0 > 0 }) else {
            throw TrueHDError.malformedBitstream(
                "Transport timing requires at least one non-empty access unit"
            )
        }

        var lower = 1
        var upper = maximumCodedPeakRate
        while lower < upper {
            let candidate = lower + (upper - lower) / 2
            if schedule(byteCounts: byteCounts, codedPeakRate: candidate).maximumLead
                <= maximumLeadSamples {
                upper = candidate
            } else {
                lower = candidate + 1
            }
        }

        let result = schedule(byteCounts: byteCounts, codedPeakRate: lower)
        guard result.maximumLead <= maximumLeadSamples else {
            throw TrueHDError.peakBitRateExceeded(
                required: lower * 3_000,
                limit: maximumCodedPeakRate * 3_000
            )
        }
        return MLPTransportPlan(
            codedPeakRate: lower,
            inputTimings: result.timings.map { UInt16(truncatingIfNeeded: $0) },
            maximumLeadSamples: result.maximumLead
        )
    }

    static func inputTimings(
        byteCounts: [Int],
        codedPeakRate: Int
    ) -> [UInt16] {
        schedule(byteCounts: byteCounts, codedPeakRate: codedPeakRate)
            .timings
            .map { UInt16(truncatingIfNeeded: $0) }
    }

    static func maximumLead(
        byteCounts: [Int],
        codedPeakRate: Int
    ) -> Int {
        schedule(byteCounts: byteCounts, codedPeakRate: codedPeakRate).maximumLead
    }

    private static func schedule(
        byteCounts: [Int],
        codedPeakRate: Int
    ) -> (timings: [Int64], maximumLead: Int) {
        precondition(codedPeakRate > 0)
        var timings = [Int64](repeating: 0, count: byteCounts.count)
        var nextInput: Int64?
        var maximumLead = 0

        for index in byteCounts.indices.reversed() {
            let duration = transmissionDuration(
                byteCount: byteCounts[index],
                codedPeakRate: codedPeakRate
            )
            let output = Int64(index * samplesPerAccessUnit)
            let nominalInput = output - max(Int64(samplesPerAccessUnit), duration)
            let input = nextInput.map { min(nominalInput, $0 - duration) }
                ?? nominalInput
            timings[index] = input
            maximumLead = max(maximumLead, Int(output - input))
            nextInput = input
        }
        return (timings, maximumLead)
    }

    private static func transmissionDuration(
        byteCount: Int,
        codedPeakRate: Int
    ) -> Int64 {
        // At 48 kHz a major-sync peak-rate code represents 3 kbps, so the
        // exact ceiling in audio samples is ceil(bytes * 128 / code).
        let numerator = Int64(byteCount) * 128
        return (numerator + Int64(codedPeakRate) - 1) / Int64(codedPeakRate)
    }
}
