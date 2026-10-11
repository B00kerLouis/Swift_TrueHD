// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Accelerate
import Foundation

/// Measures both sides of the same overlap before the output limiter. A quiet
/// element can change location before its next audible contribution, avoiding
/// a sweep from a stale position when the element is reassigned.
enum AtmosCentroidTransition {
    struct MetadataState {
        var pending: ADMPosition
        private var pendingSilent = true

        init(position: ADMPosition) { pending = position }

        mutating func advance(to position: ADMPosition, direction: Int, silent: Bool) -> ADMPosition {
            var emitted = pending
            var emittedSilent = pendingSilent
            if direction < 0 { emitted = position; emittedSilent = silent }
            if direction <= 0 { pending = position; pendingSilent = silent }
            if emittedSilent && pendingSilent { pending = emitted }
            return emitted
        }
    }

    static func energies(samples: [Int32], frames: Int, channels: Int, sources: [Int],
                         previous: [Float], current: [Float], elements: Int) -> ([Double], [Double]) {
        let sourceCount = sources.count
        var input = [Float](repeating: 0, count: frames * sourceCount)
        for frame in 0..<frames {
            for (index, channel) in sources.enumerated() {
                input[frame * sourceCount + index] = Float(samples[frame * channels + channel]) / 8_388_608
            }
        }
        func energy(_ gains: [Float], rising: Bool) -> [Double] {
            var rendered = [Float](repeating: 0, count: frames * elements)
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(elements),
                        Int32(sourceCount), 1, input, Int32(sourceCount), gains, Int32(elements),
                        0, &rendered, Int32(elements))
            var result = [Double](repeating: 0, count: elements)
            for frame in 0..<frames {
                let gain = Float(rising ? frame : (1_535 - frame)) / 1_536
                for element in 0..<elements {
                    let value = rendered[frame * elements + element] * gain
                    result[element] += Double(value * value)
                }
            }
            return result
        }
        return (energy(previous, rising: false), energy(current, rising: true))
    }

    static func direction(previous: ADMPosition, current: ADMPosition,
                          previousLeader: Int, currentLeader: Int,
                          wasActive: Bool, isActive: Bool,
                          previousEnergy: Double, currentEnergy: Double) -> Int {
        if !wasActive && isActive { return -1 }
        if previousLeader != currentLeader || AtmosAggregatePlanner.distanceSquared(previous, current) > 0.1 {
            if previousEnergy > currentEnergy * 100 { return 1 }
            if previousEnergy * 100 < currentEnergy { return -1 }
        }
        return 0
    }
}
