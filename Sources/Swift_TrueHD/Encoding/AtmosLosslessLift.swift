// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Foundation

/// Reversible inter-element prediction within one restart interval. Element
/// identities, positions and PCM precision are unchanged. The isolated LFE is
/// never a predictor or prediction target. The raw representation competes
/// against this representation on complete encoded byte cost.
enum AtmosLosslessLift {
    struct Step {
        let target: Int
        let reference: Int
        let coefficient: Int32
    }

    static func plan(samples: [Int32], channels: Int) -> [Step] {
        precondition(samples.count.isMultiple(of: channels))
        var result = [Step]()
        for target in 1..<channels where target != 3 {
            var power: Int64 = 0
            for base in stride(from: 0, to: samples.count, by: channels) {
                let value = Int64(samples[base + target])
                power += value * value
            }
            guard power > 0 else { continue }
            var bestPower = Double(power) * 0.9
            var best: Step?
            for reference in 0..<target where reference != 3 {
                var referencePower: Int64 = 0, covariance: Int64 = 0
                for base in stride(from: 0, to: samples.count, by: channels) {
                    let a = Int64(samples[base + target]), b = Int64(samples[base + reference])
                    referencePower += b * b
                    covariance += a * b
                }
                guard referencePower > 0 else { continue }
                let scale = Double(AtmosCompatibilityMatrix.scale)
                let coefficient = Int32(min(32_767, max(-32_768,
                    (Double(covariance) / Double(referencePower) * scale).rounded())))
                let gain = Double(coefficient) / scale
                let residualPower = Double(power) + gain * gain * Double(referencePower)
                    - 2 * gain * Double(covariance)
                if residualPower < bestPower {
                    bestPower = residualPower
                    best = Step(target: target, reference: reference, coefficient: coefficient)
                }
            }
            if let best { result.append(best) }
        }
        return result
    }

    static func apply(_ steps: [Step], samples: [Int32], channels: Int) -> [Int32] {
        var output = samples
        for base in stride(from: 0, to: samples.count, by: channels) {
            for step in steps {
                output[base + step.target] = samples[base + step.target]
                    - Int32((Int64(step.coefficient) * Int64(samples[base + step.reference]))
                        >> AtmosCompatibilityMatrix.fractionalBits)
            }
        }
        return output
    }

    static func rows(_ steps: [Step], channels: Int) -> [AtmosCompatibilityMatrix.Row] {
        steps.map { step in
            var coefficients = [Int32](repeating: 0, count: channels)
            coefficients[step.target] = Int32(AtmosCompatibilityMatrix.scale)
            coefficients[step.reference] = step.coefficient
            return AtmosCompatibilityMatrix.Row(speakerChannel: step.target,
                outputChannel: step.target, coefficients: coefficients,
                coefficientMask: (1 << UInt16(step.target)) | (1 << UInt16(step.reference)))
        }
    }
}
