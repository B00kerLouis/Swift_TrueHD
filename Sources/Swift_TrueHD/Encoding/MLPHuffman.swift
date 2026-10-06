// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Exact-cost selection for raw residuals and the three fixed VLC codebooks,
// including stateful offset inheritance and signalling overhead.

struct MLPHuffmanParameters: Sendable, Equatable {
    /// 0 is raw residuals; 1...3 select one of the fixed MLP VLC tables.
    let codebook: Int
    let offset: Int32
    let lsbBits: Int
    let payloadBitCount: Int
    let writesOffset: Bool

    var parameterBitCount: Int { writesOffset ? 16 : 1 }
    var totalBitCount: Int { payloadBitCount + parameterBitCount }
}

enum MLPHuffman {
    private struct Entry: Sendable {
        let code: UInt8
        let length: UInt8
    }

    // Fixed MLP codebooks from libavcodec/mlp.c. Index ranges are adjusted
    // by codebookOffset() before lookup.
    private static let tables: [[Entry]] = [
        [
            Entry(code: 0x01, length: 9), Entry(code: 0x01, length: 8),
            Entry(code: 0x01, length: 7), Entry(code: 0x01, length: 6),
            Entry(code: 0x01, length: 5), Entry(code: 0x01, length: 4),
            Entry(code: 0x01, length: 3), Entry(code: 0x04, length: 3),
            Entry(code: 0x05, length: 3), Entry(code: 0x06, length: 3),
            Entry(code: 0x07, length: 3), Entry(code: 0x03, length: 3),
            Entry(code: 0x05, length: 4), Entry(code: 0x09, length: 5),
            Entry(code: 0x11, length: 6), Entry(code: 0x21, length: 7),
            Entry(code: 0x41, length: 8), Entry(code: 0x81, length: 9)
        ],
        [
            Entry(code: 0x01, length: 9), Entry(code: 0x01, length: 8),
            Entry(code: 0x01, length: 7), Entry(code: 0x01, length: 6),
            Entry(code: 0x01, length: 5), Entry(code: 0x01, length: 4),
            Entry(code: 0x01, length: 3), Entry(code: 0x02, length: 2),
            Entry(code: 0x03, length: 2), Entry(code: 0x03, length: 3),
            Entry(code: 0x05, length: 4), Entry(code: 0x09, length: 5),
            Entry(code: 0x11, length: 6), Entry(code: 0x21, length: 7),
            Entry(code: 0x41, length: 8), Entry(code: 0x81, length: 9)
        ],
        [
            Entry(code: 0x01, length: 9), Entry(code: 0x01, length: 8),
            Entry(code: 0x01, length: 7), Entry(code: 0x01, length: 6),
            Entry(code: 0x01, length: 5), Entry(code: 0x01, length: 4),
            Entry(code: 0x01, length: 3), Entry(code: 0x01, length: 1),
            Entry(code: 0x03, length: 3), Entry(code: 0x05, length: 4),
            Entry(code: 0x09, length: 5), Entry(code: 0x11, length: 6),
            Entry(code: 0x21, length: 7), Entry(code: 0x41, length: 8),
            Entry(code: 0x81, length: 9)
        ]
    ]

    private static let extremes = [(-9, 8), (-8, 7), (-15, 14)]
    private static let minimumOffset = -16_384
    private static let maximumOffset = 16_383
    private static let maximumNonImprovingRegions = 3

    static func select(samples: [Int32], previousOffset: Int32 = 0) -> MLPHuffmanParameters {
        guard let first = samples.first else {
            return makeParameters(
                codebook: 0, offset: Int(previousOffset), lsbBits: 0,
                payloadBitCount: 0, previousOffset: previousOffset
            )
        }
        var minimum = Int(first)
        var maximum = Int(first)
        var sum: Int64 = 0
        for sample in samples {
            let value = Int(sample)
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += Int64(value)
        }

        var best = bestRawCandidate(
            samples: samples, minimum: minimum, maximum: maximum,
            previousOffset: previousOffset
        )
        let average = clampOffset(Int(sum / Int64(samples.count)))
        for codebook in 1...3 {
            if let candidate = bestHuffmanCandidate(
                samples: samples, minimum: minimum, maximum: maximum,
                codebook: codebook, initialOffset: average,
                previousOffset: previousOffset
            ), candidate.totalBitCount < best.totalBitCount {
                best = candidate
            }
        }
        return best
    }

    static func write(
        sample: Int32,
        parameters: MLPHuffmanParameters,
        to writer: inout BitWriter
    ) {
        let codebook = parameters.codebook
        let lsbBits = parameters.lsbBits
        var signedOffset = Int(parameters.offset)
        let signShift = lsbBits + (codebook > 0 ? 2 - codebook : -1)
        if codebook > 0 { signedOffset -= 7 << lsbBits }
        if signShift >= 0 { signedOffset -= 1 << signShift }

        var value = Int(sample) - signedOffset
        if codebook > 0 {
            let tableIndex = codebook - 1
            let high = value >> lsbBits
            let index = high
            precondition(tables[tableIndex].indices.contains(index))
            let entry = tables[tableIndex][index]
            writer.write(UInt64(entry.code), count: Int(entry.length))
            if lsbBits > 0 { value &= (1 << lsbBits) - 1 }
        }
        writer.write(UInt64(bitPattern: Int64(value)), count: lsbBits)
    }

    private static func bestRawCandidate(
        samples: [Int32],
        minimum inputMinimum: Int,
        maximum inputMaximum: Int,
        previousOffset: Int32
    ) -> MLPHuffmanParameters {
        var minimum = inputMinimum
        var maximum = inputMaximum
        if minimum < minimumOffset {
            maximum = max(maximum, 2 * minimumOffset - minimum + 1)
        }
        if maximum > maximumOffset {
            minimum = min(minimum, 2 * maximumOffset - maximum - 1)
        }
        let bits = max(signedBitCount(minimum), signedBitCount(maximum))
        let offset = clampOffset(minimum + (maximum - minimum) / 2 + (bits == 0 ? 0 : 1))
        return makeParameters(
            codebook: 0, offset: offset, lsbBits: bits,
            payloadBitCount: bits * samples.count, previousOffset: previousOffset
        )
    }

    private struct HuffmanEvaluation {
        let parameters: MLPHuffmanParameters
        let equivalentOffsetRange: ClosedRange<Int>
    }

    /// Searches distinct offset regions by jumping over ranges that produce
    /// identical VLC symbols. The bounded non-improvement rule mirrors the
    /// production FFmpeg encoder and prevents pathological 32K-offset scans.
    private static func bestHuffmanCandidate(
        samples: [Int32],
        minimum: Int,
        maximum: Int,
        codebook: Int,
        initialOffset: Int,
        previousOffset: Int32
    ) -> MLPHuffmanParameters? {
        var best: MLPHuffmanParameters?

        func consider(_ evaluation: HuffmanEvaluation) {
            if best == nil || evaluation.parameters.totalBitCount < best!.totalBitCount {
                best = evaluation.parameters
            }
        }

        guard let initial = huffmanEvaluation(
            samples: samples, minimum: minimum, maximum: maximum,
            codebook: codebook, offset: initialOffset,
            previousOffset: previousOffset
        ) else { return nil }
        consider(initial)

        // Offset signalling is stateful. Always score the inherited offset,
        // and zero as a stable restart-friendly candidate, even if the local
        // directional search would stop before reaching their regions.
        for preferredOffset in [Int(previousOffset), 0] where preferredOffset != initialOffset {
            if let evaluation = huffmanEvaluation(
                samples: samples, minimum: minimum, maximum: maximum,
                codebook: codebook, offset: clampOffset(preferredOffset),
                previousOffset: previousOffset
            ) {
                consider(evaluation)
            }
        }

        var offset = initial.equivalentOffsetRange.lowerBound - 1
        var previousCount = Int.max
        var nonImprovingRegions = 0
        while offset >= minimumOffset {
            guard let evaluation = huffmanEvaluation(
                samples: samples, minimum: minimum, maximum: maximum,
                codebook: codebook, offset: offset,
                previousOffset: previousOffset
            ) else { break }
            consider(evaluation)
            if evaluation.parameters.totalBitCount < previousCount {
                nonImprovingRegions = 0
            } else {
                nonImprovingRegions += 1
                if nonImprovingRegions >= maximumNonImprovingRegions { break }
            }
            previousCount = evaluation.parameters.totalBitCount
            let next = evaluation.equivalentOffsetRange.lowerBound - 1
            guard next < offset else { break }
            offset = next
        }

        offset = initial.equivalentOffsetRange.upperBound + 1
        previousCount = Int.max
        nonImprovingRegions = 0
        while offset <= maximumOffset {
            guard let evaluation = huffmanEvaluation(
                samples: samples, minimum: minimum, maximum: maximum,
                codebook: codebook, offset: offset,
                previousOffset: previousOffset
            ) else { break }
            consider(evaluation)
            if evaluation.parameters.totalBitCount < previousCount {
                nonImprovingRegions = 0
            } else {
                nonImprovingRegions += 1
                if nonImprovingRegions >= maximumNonImprovingRegions { break }
            }
            previousCount = evaluation.parameters.totalBitCount
            let next = evaluation.equivalentOffsetRange.upperBound + 1
            guard next > offset else { break }
            offset = next
        }
        return best
    }

    private static func huffmanEvaluation(
        samples: [Int32],
        minimum: Int,
        maximum: Int,
        codebook: Int,
        offset: Int,
        previousOffset: Int32
    ) -> HuffmanEvaluation? {
        let tableIndex = codebook - 1
        var relativeMinimum = minimum - offset
        var relativeMaximum = maximum - offset
        var lsbBits = 0
        let extreme = extremes[tableIndex]
        while relativeMinimum < extreme.0 || relativeMaximum > extreme.1 {
            lsbBits += 1
            relativeMinimum >>= 1
            relativeMaximum >>= 1
            if lsbBits > 24 { return nil }
        }

        let lowBitRange = 1 << lsbBits
        let lowBitMask = lowBitRange - 1
        var unsignedOffset = offset
        if tableIndex == 2 {
            unsignedOffset -= lowBitRange
            lsbBits += 1
        }
        var bitCount = lsbBits * samples.count
        var lowerSlack = Int.max
        var upperSlack = Int.max
        for sample in samples {
            let value = Int(sample) - unsignedOffset
            let low = value & lowBitMask
            lowerSlack = min(lowerSlack, low)
            upperSlack = min(upperSlack, lowBitRange - low - 1)
            let high = value >> lsbBits
            let index = high + codebookOffset(tableIndex)
            guard tables[tableIndex].indices.contains(index) else { return nil }
            bitCount += Int(tables[tableIndex][index].length)
        }
        let parameters = makeParameters(
            codebook: codebook, offset: offset, lsbBits: lsbBits,
            payloadBitCount: bitCount, previousOffset: previousOffset
        )
        return HuffmanEvaluation(
            parameters: parameters,
            equivalentOffsetRange: (
                max(minimumOffset, offset - lowerSlack)
                    ... min(maximumOffset, offset + upperSlack)
            )
        )
    }

    private static func makeParameters(
        codebook: Int,
        offset: Int,
        lsbBits: Int,
        payloadBitCount: Int,
        previousOffset: Int32
    ) -> MLPHuffmanParameters {
        MLPHuffmanParameters(
            codebook: codebook,
            offset: Int32(offset),
            lsbBits: lsbBits,
            payloadBitCount: payloadBitCount,
            writesOffset: Int32(offset) != previousOffset
        )
    }

    private static func codebookOffset(_ tableIndex: Int) -> Int {
        7 + (2 - tableIndex)
    }

    private static func signedBitCount(_ value: Int) -> Int {
        if value == 0 { return 0 }
        if value == -1 { return 1 }
        if value > 0 { return Int.bitWidth - value.leadingZeroBitCount + 1 }
        return Int.bitWidth - (~value).leadingZeroBitCount + 1
    }

    private static func clampOffset(_ value: Int) -> Int {
        min(maximumOffset, max(minimumOffset, value))
    }
}
