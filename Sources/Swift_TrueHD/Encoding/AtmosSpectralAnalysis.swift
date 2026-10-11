// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Accelerate
import Foundation

/// Bounded two-interval analysis used only to allocate spatial aggregates.
/// The analysis window and hearing weights never modify the encoded PCM.
final class AtmosSpectralAnalysis {
    static let bands = 24
    private static let hop = 1_536
    private static let length = 4_096
    private let setup: vDSP_DFT_Setup
    private let sources: [Int]
    private let channels: Int
    private let window: [Float]
    private let frequencyWeights: [Float]
    private let bandWidths: [Int]
    private var previous: [Float]
    private var history: [[Float]]
    private var totals: [Float]
    private var real = [Float](repeating: 0, count: length)
    private var imaginary = [Float](repeating: 0, count: length)
    private var transformedReal = [Float](repeating: 0, count: length)
    private var transformedImaginary = [Float](repeating: 0, count: length)
    private var hasPrevious = false

    init(channels: Int, sources: [Int]) throws {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.length), .FORWARD) else {
            throw TrueHDError.invalidConfiguration("Cannot allocate spatial spectrum analysis")
        }
        self.setup = setup
        self.channels = channels
        self.sources = sources
        window = (0..<(Self.hop * 2)).map { (index: Int) -> Float in
            let distance = index < Self.hop ? index : (Self.hop * 2 - 1 - index)
            return Float(distance) / Float(Self.hop)
        }
        let binHz = 48_000.0 / Double(Self.length)
        var widths = [Int](), index = 1
        while index <= Self.length / 2 {
            let width = min(Self.length / 2 + 1 - index,
                            max(1, Int((2 * (Double(index) * binHz / 9.265 + 24.7) / binHz).rounded())))
            widths.append(width)
            index += width
        }
        bandWidths = widths
        frequencyWeights = (0..<(Self.length / 2)).map { bin in
            let f = max(0.001, Double(bin) * binHz / 1_000)
            let thresholdDB = min(70, 3.64 * pow(f, -0.8)
                                  - 6.5 * exp(-0.6 * pow(f - 3.3, 2)) + 0.001 * pow(f, 4))
            let amplitude = pow(10, thresholdDB / 20)
            return Float(pow(1_000_000 / Double(Self.hop) / amplitude, 2))
        }
        previous = [Float](repeating: 0, count: sources.count * Self.hop)
        history = [[Float]](repeating: [Float](repeating: 0, count: widths.count), count: sources.count)
        totals = [Float](repeating: 0, count: sources.count)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    /// The first call supplies the left half. Each subsequent call emits the
    /// preceding interval's lookahead analysis; a zero block flushes the tail.
    func push(samples: [Int32], frames: Int) -> [Float]? {
        precondition(frames <= Self.hop && samples.count == frames * channels)
        var output = [Float](repeating: 0, count: sources.count * Self.bands)
        let decay = Float(exp(-Double(Self.hop * 2) / (48_000 * 0.1)))
        let smooth = Float(exp(-Double(Self.hop * 2) / (48_000 * 0.3)))
        for (source, channel) in sources.enumerated() {
            let base = source * Self.hop
            var active = false
            for n in 0..<Self.hop {
                let next = n < frames ? Float(samples[n * channels + channel]) / 8_388_608 : 0
                real[n] = previous[base + n] * window[n]
                real[n + Self.hop] = next * window[n + Self.hop]
                active = active || real[n] != 0 || real[n + Self.hop] != 0
                previous[base + n] = next
            }
            // Warm the release state from [silence, first interval] as well.
            // Otherwise an onset at sample zero is hidden by the next window.
            var powers = [Float](repeating: 0, count: bandWidths.count)
            if active {
                real.withUnsafeBufferPointer { input in
                    imaginary.withUnsafeBufferPointer { imaginary in
                        transformedReal.withUnsafeMutableBufferPointer { output in
                            transformedImaginary.withUnsafeMutableBufferPointer { outputImaginary in
                                vDSP_DFT_Execute(setup, input.baseAddress!, imaginary.baseAddress!,
                                                 output.baseAddress!, outputImaginary.baseAddress!)
                            }
                        }
                    }
                }
                var bin = 0
                for band in bandWidths.indices {
                    for _ in 0..<bandWidths[band] {
                        let r = transformedReal[bin], i = transformedImaginary[bin]
                        powers[band] += (r * r + i * i) * frequencyWeights[bin]
                        bin += 1
                    }
                }
            }
            var forward = powers
            var sum: Float = 0
            for band in powers.indices { sum = powers[band] + 0.0001 * sum; forward[band] = sum }
            sum = 0
            for band in powers.indices.reversed() {
                forward[band] += 0.0001 * sum
                sum = powers[band] + 0.0001 * sum
            }
            let total = forward.reduce(0, +)
            let transient = total > totals[source] * 100 * (1 + Float.ulpOfOne)
                || totals[source] > total * 100 * (1 + Float.ulpOfOne)
            var updatedTotal: Float = 0
            for band in powers.indices {
                let value = transient ? max(forward[band], history[source][band] * decay)
                    : forward[band] * (1 - smooth) + history[source][band] * smooth
                updatedTotal += value
                history[source][band] = band < Self.bands ? value : 0
                if band < Self.bands { output[source * Self.bands + band] = value }
            }
            totals[source] = updatedTotal
        }
        let ready = hasPrevious
        hasPrevious = true
        return ready ? output : nil
    }
}
