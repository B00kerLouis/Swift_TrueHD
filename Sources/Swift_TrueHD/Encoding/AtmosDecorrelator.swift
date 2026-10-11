// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Foundation

/// Four bounded all-pass paths with transient protection for diffuse sources.
/// State belongs to one source; the caller serializes processing and resets it
/// when that source leaves the diffuse path.
final class AtmosDecorrelator {
    private static let sampleRate = 48_000.0
    private static let fast = Float(exp(-1 / (sampleRate * 0.005)))
    private static let slow = Float(exp(-1 / (sampleRate * 0.08)))
    private static let release = Float(exp(-1 / (sampleRate * 0.05)))
    private static let highpass = Float(exp(-1 / (sampleRate * Double(Float(0.000053052)))))
    private static let delays: [Int] = {
        let weights = (0..<4).map { pow(3.0, Double($0) / 4) }
        let total = weights.reduce(0, +)
        return weights.map { Int(ceil(sampleRate * 0.02 * $0 / total)) }
    }()
    private static let signs: [[Float]] = [[-1, -1, -1, -1], [-1, 1, -1, 1],
                                         [-1, -1, 1, 1], [-1, 1, 1, -1]]
    private var rings = delays.map { [Float](repeating: 0, count: $0 * 4) }
    private var ringPositions = [Int](repeating: 0, count: 4)
    private var inputDelay = [Float](repeating: 0, count: 96)
    private var inputPosition = 0
    private var highpassState: Float = 0
    private var fastEnvelope: Float = 0
    private var slowEnvelope: Float = 0
    private var attackGain: Float = 1
    private var releaseGain: Float = 1
    private var firstBlock = true

    func reset() {
        for i in rings.indices { rings[i] = [Float](repeating: 0, count: rings[i].count) }
        ringPositions = [Int](repeating: 0, count: 4)
        inputDelay = [Float](repeating: 0, count: 96)
        inputPosition = 0
        highpassState = 0
        fastEnvelope = 0
        slowEnvelope = 0
        attackGain = 1
        releaseGain = 1
        firstBlock = true
    }

    func process(_ input: [Float]) -> [[Float]] {
        var output = [[Float]](repeating: [Float](repeating: 0, count: input.count), count: 4)
        for n in input.indices {
            let sample = firstBlock && n < input.count / 2
                ? input[n] * Float(n) / Float(input.count / 2) : input[n]
            let filtered = (sample + highpassState) * Self.highpass
            highpassState = filtered - sample
            let magnitude = abs(filtered) + 0.00001
            fastEnvelope = magnitude * (1 - Self.fast) + Self.fast * fastEnvelope
            slowEnvelope = magnitude * (1 - Self.slow) + Self.slow * slowEnvelope
            attackGain = (attackGain - 1) * Self.release + 1
            releaseGain = (releaseGain - 1) * Self.release + 1
            let fast = fastEnvelope == 0 ? 0.00001 : fastEnvelope
            let slow = slowEnvelope == 0 ? 0.00001 : slowEnvelope
            attackGain = min(attackGain, slow * 1.1 / fast)
            releaseGain = min(releaseGain, fast * 1.1 / slow)
            let delayed = inputDelay[inputPosition]
            inputDelay[inputPosition] = sample
            inputPosition = (inputPosition + 1) % inputDelay.count
            var values = SIMD4<Float>(repeating: delayed * attackGain)
            for stage in rings.indices {
                let base = ringPositions[stage] * 4
                for channel in 0..<4 {
                    let coefficient = Self.signs[stage][channel] * 0.4
                    let prior = rings[stage][base + channel]
                    let next = values[channel] + prior * coefficient
                    values[channel] = prior - next * coefficient
                    rings[stage][base + channel] = next
                }
                ringPositions[stage] = (ringPositions[stage] + 1) % Self.delays[stage]
            }
            for channel in 0..<4 { output[channel][n] = values[channel] * releaseGain }
        }
        firstBlock = false
        return output
    }
}
