// SPDX-License-Identifier: AGPL-3.0-only
//
// Builds fixed-point FIR and LPC candidates, then scores the exact residual and
// signalling cost that the decoder will reconstruct.

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

    /// Selects raw or order-1...4 FIR residuals using the full
    /// entropy payload and filter signalling cost. All candidates update the
    /// same original-sample history, matching the MLP decoder's FIR state.
    static func select(
        rawSamples: [Int32],
        history inputHistory: [Int32],
        previousOffset: Int32,
        activeFIR: MLPFIRParameters?,
        allowPrediction: Bool,
        maximumOrder: Int = 8,
        includeLPC: Bool = true
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

        var finalHistory = inputHistory
        for sample in rawSamples {
            finalHistory.insert(sample, at: 0)
            finalHistory.removeLast()
        }

        if allowPrediction {
            var availableCandidates = candidates.filter { $0.order <= maximumOrder }
            if includeLPC {
                availableCandidates += lpcCandidates(
                    samples: rawSamples,
                    history: inputHistory,
                    maximumOrder: maximumOrder
                )
            }
            var tested = Set<MLPFIRKey>()
            for candidate in availableCandidates {
                let key = MLPFIRKey(candidate)
                guard tested.insert(key).inserted else { continue }
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
        var history = inputHistory
        var residuals = [Int32]()
        residuals.reserveCapacity(samples.count)
        for sample in samples {
            var accumulation: Int64 = 0
            for order in 0..<filter.order {
                accumulation += Int64(history[order]) * Int64(filter.coefficients[order])
            }
            accumulation >>= Int64(filter.shift)
            let prediction = Int32(truncatingIfNeeded: accumulation)
            residuals.append(sample &- prediction)
            history.insert(sample, at: 0)
            history.removeLast()
        }
        return residuals
    }

    /// Levinson-Durbin LPC analysis with MLP-compatible fixed-point
    /// quantization. Each stable intermediate order is a real coding candidate.
    private static func lpcCandidates(
        samples: [Int32],
        history: [Int32],
        maximumOrder: Int
    ) -> [MLPFIRParameters] {
        let orderLimit = min(8, maximumOrder)
        guard orderLimit > 0 else { return [] }
        let signal = history.reversed().map(Double.init) + samples.map(Double.init)
        guard signal.count > orderLimit else { return [] }

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
        var error = autocorrelation[0]
        var best: MLPFIRParameters?
        var bestAbsoluteResidual = UInt64.max
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

            var updated = coefficients
            if order > 1 {
                for index in 0..<(order - 1) {
                    updated[index] = coefficients[index]
                        - reflection * coefficients[order - 2 - index]
                }
            }
            updated.append(reflection)
            coefficients = updated
            error *= 1 - reflection * reflection

            if let quantized = quantizeLPC(coefficients) {
                let residuals = apply(
                    samples: samples, history: history, filter: quantized
                )
                let absoluteResidual = residuals.reduce(UInt64(0)) { partial, value in
                    partial &+ UInt64(value.magnitude)
                }
                if absoluteResidual < bestAbsoluteResidual {
                    bestAbsoluteResidual = absoluteResidual
                    best = quantized
                }
            }
        }
        return best.map { [$0] } ?? []
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

private struct MLPFIRKey: Hashable {
    let coefficients: [Int32]
    let shift: Int

    init(_ parameters: MLPFIRParameters) {
        coefficients = parameters.coefficients
        shift = parameters.shift
    }
}
