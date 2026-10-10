// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Builds fixed-point FIR and LPC candidates, then scores the exact residual and
// signalling cost that the decoder will reconstruct.

import Foundation

struct MLPFIRParameters: Sendable, Equatable {
    let coefficients: [Int32]
    let shift: Int
    let coefficientBits: Int
    let coefficientShift: Int

    var order: Int { coefficients.count }

    var signallingBitCount: Int {
        // changed flag, order, filter shift, coefficient format, coefficients,
        // and the mandatory no-explicit-state flag.
        1 + 4 + 4 + 5 + 3 + order * coefficientBits + 1
    }
}

struct MLPChannelCodingDecision: Sendable {
    let samples: [Int32]
    let entropy: MLPHuffmanParameters
    let fir: MLPFIRParameters?
    let writesFIR: Bool
    let finalHistory: [Int32]
}

enum MLPPredictiveCoding {
    static let historyLength = 8

    private static let candidates = [
        MLPFIRParameters(
            coefficients: [256], shift: 8, coefficientBits: 10, coefficientShift: 0
        ),
        MLPFIRParameters(
            coefficients: [512, -256], shift: 8,
            coefficientBits: 11, coefficientShift: 0
        ),
        MLPFIRParameters(
            coefficients: [768, -768, 256], shift: 8,
            coefficientBits: 11, coefficientShift: 0
        ),
        MLPFIRParameters(
            coefficients: [1_024, -1_536, 1_024, -256], shift: 8,
            coefficientBits: 12, coefficientShift: 0
        )
    ]

    /// Selects raw, order-1...4 fixed FIR and order-1...8 LPC residuals using the full
    /// entropy payload and filter signalling cost. All candidates update the
    /// same original-sample history, matching the MLP decoder's FIR state.
    static func select(
        rawSamples: [Int32],
        history inputHistory: [Int32],
        previousOffset: Int32,
        activeFIR: MLPFIRParameters?,
        allowPrediction: Bool,
        maximumOrder: Int = 8,
        includeLPC: Bool = true,
        analysisCandidates: [MLPFIRParameters] = []
    ) -> MLPChannelCodingDecision {
        precondition(inputHistory.count == historyLength)
        let rawEntropy = MLPHuffman.select(
            samples: rawSamples, previousOffset: previousOffset
        )
        var bestSamples = rawSamples
        var bestEntropy = rawEntropy
        var bestFIR: MLPFIRParameters?
        var bestCost = rawEntropy.totalBitCount + filterSignallingCost(
            selected: nil, active: activeFIR
        )

        let finalHistory = updatedHistory(samples: rawSamples, inputHistory: inputHistory)

        if allowPrediction {
            for candidate in candidates where candidate.order <= maximumOrder {
                let residuals = apply(
                    samples: rawSamples, history: inputHistory, filter: candidate
                )
                let entropy = MLPHuffman.select(
                    samples: residuals, previousOffset: previousOffset
                )
                let cost = entropy.totalBitCount + filterSignallingCost(
                    selected: candidate, active: activeFIR
                )
                if cost < bestCost {
                    bestCost = cost
                    bestSamples = residuals
                    bestEntropy = entropy
                    bestFIR = candidate
                }
            }
            if includeLPC {
                // A bounded interval supplies stable coefficients; short-block
                // analysis remains available for local changes in the signal.
                let analyzed = analysisCandidates + lpcCandidates(
                    samples: rawSamples,
                    history: inputHistory,
                    maximumOrder: maximumOrder
                )
                for candidate in analyzed where candidate.order <= maximumOrder && !candidates.contains(where: {
                    $0.coefficients == candidate.coefficients && $0.shift == candidate.shift
                }) {
                    let residuals = apply(
                        samples: rawSamples, history: inputHistory, filter: candidate
                    )
                    let entropy = MLPHuffman.select(
                        samples: residuals, previousOffset: previousOffset
                    )
                    let cost = entropy.totalBitCount + filterSignallingCost(
                        selected: candidate, active: activeFIR
                    )
                    if cost < bestCost {
                        bestCost = cost
                        bestSamples = residuals
                        bestEntropy = entropy
                        bestFIR = candidate
                    }
                }
            }
        }

        return MLPChannelCodingDecision(
            samples: bestSamples,
            entropy: bestEntropy,
            fir: bestFIR,
            writesFIR: bestFIR != activeFIR,
            finalHistory: finalHistory
        )
    }

    static func writeFIR(
        decision: MLPChannelCodingDecision,
        to writer: inout BitWriter
    ) {
        writer.write(decision.writesFIR ? 1 : 0, count: 1)
        guard decision.writesFIR else { return }
        guard let fir = decision.fir else {
            writer.write(0, count: 4)
            return
        }
        precondition(
            (8...15).contains(fir.shift),
            "TrueHD FBA FIR coeff_q must be between 8 and 15"
        )
        writer.write(UInt64(fir.order), count: 4)
        writer.write(UInt64(fir.shift), count: 4)
        writer.write(UInt64(fir.coefficientBits), count: 5)
        writer.write(UInt64(fir.coefficientShift), count: 3)
        for coefficient in fir.coefficients {
            writer.writeSigned(
                coefficient >> Int32(fir.coefficientShift),
                count: fir.coefficientBits
            )
        }
        writer.write(0, count: 1) // FIR cannot carry explicit state
    }

    /// Analyze one bounded restart interval, independently of codec history.
    /// Lookahead improves high-order autocorrelation without retaining a whole
    /// programme. Each quantized candidate still competes on actual block bits.
    static func analyzeInterval(
        samples: [Int32], channels: Int, maximumOrder: Int = 8
    ) -> [[MLPFIRParameters]] {
        precondition(channels > 0 && samples.count % channels == 0)
        return (0..<channels).map { channel in
            let values = stride(from: channel, to: samples.count, by: channels).map { samples[$0] }
            // Tapering prevents a restart-interval cut from dominating the
            // high-order autocorrelation. Both analyses compete on original,
            // untapered PCM, so the window never changes encoded samples.
            return lpcCandidates(samples: values, history: [], maximumOrder: maximumOrder)
                + lpcCandidates(samples: values, history: [], maximumOrder: maximumOrder, windowed: true)
        }
    }

    private static func filterSignallingCost(
        selected: MLPFIRParameters?,
        active: MLPFIRParameters?
    ) -> Int {
        guard selected != active else { return 1 }
        return selected?.signallingBitCount ?? 5
    }

    private static func apply(
        samples: [Int32],
        history inputHistory: [Int32],
        filter: MLPFIRParameters
    ) -> [Int32] {
        var residuals = [Int32]()
        residuals.reserveCapacity(samples.count)
        for sampleIndex in samples.indices {
            var accumulation: Int64 = 0
            for order in 0..<filter.order {
                let sourceIndex = sampleIndex - order - 1
                let source = sourceIndex >= 0
                    ? samples[sourceIndex]
                    : inputHistory[-sourceIndex - 1]
                accumulation += Int64(source) * Int64(filter.coefficients[order])
            }
            accumulation >>= Int64(filter.shift)
            let prediction = Int32(truncatingIfNeeded: accumulation)
            residuals.append(samples[sampleIndex] &- prediction)
        }
        return residuals
    }

    /// Levinson-Durbin LPC analysis with MLP-compatible fixed-point
    /// quantization. Each stable intermediate order is a real coding candidate.
    private static func lpcCandidates(
        samples: [Int32],
        history: [Int32],
        maximumOrder: Int,
        windowed: Bool = false
    ) -> [MLPFIRParameters] {
        let orderLimit = min(8, maximumOrder)
        guard orderLimit > 0 else { return [] }
        var signal = [Double]()
        signal.reserveCapacity(history.count + samples.count)
        for sample in history.reversed() { signal.append(Double(sample)) }
        for sample in samples { signal.append(Double(sample)) }
        guard signal.count > orderLimit else { return [] }
        if windowed {
            let denominator = Double(signal.count - 1)
            for index in signal.indices {
                signal[index] *= 0.5 - 0.5 * cos(2 * .pi * Double(index) / denominator)
            }
        }

        var autocorrelation = [Double](repeating: 0, count: orderLimit + 1)
        for lag in 0...orderLimit {
            var sum = 0.0
            for index in lag..<signal.count {
                sum += signal[index] * signal[index - lag]
            }
            autocorrelation[lag] = sum
        }
        guard autocorrelation[0].isFinite, autocorrelation[0] > 0 else { return [] }

        var coefficients = [Double]()
        coefficients.reserveCapacity(orderLimit)
        var error = autocorrelation[0]
        var candidates = [MLPFIRParameters]()
        for order in 1...orderLimit {
            var numerator = autocorrelation[order]
            if order > 1 {
                for index in 1..<order {
                    numerator -= coefficients[index - 1]
                        * autocorrelation[order - index]
                }
            }
            guard error.isFinite, error > autocorrelation[0] * 1e-12 else { break }
            let reflection = numerator / error
            guard reflection.isFinite, abs(reflection) < 0.999_999 else { break }

            if order > 1 {
                let previousCount = order - 1
                var index = 0
                while index < previousCount / 2 {
                    let oppositeIndex = previousCount - 1 - index
                    let first = coefficients[index]
                    let second = coefficients[oppositeIndex]
                    coefficients[index] = first - reflection * second
                    coefficients[oppositeIndex] = second - reflection * first
                    index += 1
                }
                if previousCount & 1 == 1 {
                    let middleIndex = previousCount / 2
                    let middle = coefficients[middleIndex]
                    coefficients[middleIndex] = middle - reflection * middle
                }
            }
            coefficients.append(reflection)
            error *= 1 - reflection * reflection

            if let quantized = quantizeLPC(coefficients) {
                // Every quantized order is scored by the same exact Huffman,
                // offset and filter-signalling cost as raw/fixed FIR candidates.
                candidates.append(quantized)
            }
        }
        return candidates
    }

    private static func updatedHistory(
        samples: [Int32],
        inputHistory: [Int32]
    ) -> [Int32] {
        var result = [Int32](repeating: 0, count: historyLength)
        var sourceIndex = samples.count
        var destinationIndex = 0
        while destinationIndex < historyLength, sourceIndex > 0 {
            sourceIndex -= 1
            result[destinationIndex] = samples[sourceIndex]
            destinationIndex += 1
        }
        while destinationIndex < historyLength {
            result[destinationIndex] = inputHistory[destinationIndex - samples.count]
            destinationIndex += 1
        }
        return result
    }

    private static func quantizeLPC(_ coefficients: [Double]) -> MLPFIRParameters? {
        var shift = 12
        var quantized = coefficients.map { Int64(($0 * Double(1 << shift)).rounded()) }
        while shift > 0 && quantized.contains(where: { $0 < -32_768 || $0 > 32_767 }) {
            shift -= 1
            quantized = coefficients.map { Int64(($0 * Double(1 << shift)).rounded()) }
        }
        guard shift >= 8,
              !quantized.allSatisfy({ $0 == 0 }),
              quantized.allSatisfy({ (-32_768...32_767).contains($0) }) else { return nil }
        let values = quantized.map(Int32.init)
        let bits = values.reduce(1) { max($0, signedBitCount($1)) }
        guard bits <= 16 else { return nil }
        return MLPFIRParameters(
            coefficients: values,
            shift: shift,
            coefficientBits: bits,
            coefficientShift: 0
        )
    }

    private static func signedBitCount(_ value: Int32) -> Int {
        if value == 0 { return 1 }
        if value > 0 { return 33 - value.leadingZeroBitCount }
        return 33 - (~value).leadingZeroBitCount
    }
}
