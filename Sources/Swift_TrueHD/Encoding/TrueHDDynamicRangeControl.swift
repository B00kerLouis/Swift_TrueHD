// SPDX-License-Identifier: AGPL-3.0-only
//
// Produces decoder-side gain metadata from weighted programme levels. The
// encoded PCM is never gain-processed by this component.

import Foundation

/// Native TrueHD DRC metadata analysis. Audio samples are never modified: the
/// analyzer produces one gain trajectory for each cumulative presentation.
struct TrueHDDynamicRangeControl {
    static let accessUnitsPerRegularUpdate: UInt64 = 128
    static let interpolationTimeCode = 7
    static let decibelsPerGainCode = 6.020_599_913_279_624 / 64.0

    private let profile: TrueHDDRCProfile
    private let channelCount: Int
    private let presentationMaximumChannels: [Int]
    private let decodedOutputShift: Int
    private var weightingFilters: [BWeightingFilter]
    private var envelopeLevels: [Double]
    private var gainCodes: [Int]
    private var lastUpdateAccessUnits: [UInt64?]
    private var lastTargetCodes: [Int]

    init(
        profile: TrueHDDRCProfile,
        channelCount: Int,
        presentationMaximumChannels: [Int],
        decodedOutputShift: Int = 0
    ) {
        precondition(channelCount > 0)
        precondition(presentationMaximumChannels.allSatisfy { $0 < channelCount })
        self.profile = profile
        self.channelCount = channelCount
        self.presentationMaximumChannels = presentationMaximumChannels
        self.decodedOutputShift = decodedOutputShift
        weightingFilters = (0..<channelCount).map { _ in BWeightingFilter(sampleRate: 48_000) }
        envelopeLevels = [Double](repeating: 0, count: presentationMaximumChannels.count)
        gainCodes = [Int](repeating: 0, count: presentationMaximumChannels.count)
        lastUpdateAccessUnits = [UInt64?](repeating: nil, count: presentationMaximumChannels.count)
        lastTargetCodes = [Int](repeating: 0, count: presentationMaximumChannels.count)
    }

    /// Analyzes an access unit and returns a gain code only for presentations
    /// that require an extra directory word in this access unit.
    mutating func updates(
        samples: [Int32],
        frameCount: Int,
        accessUnit: UInt64,
        forceUpdate: Bool = false
    ) -> [Int?] {
        precondition(samples.count >= frameCount * channelCount)
        guard frameCount > 0 else {
            return [Int?](repeating: nil, count: presentationMaximumChannels.count)
        }

        var weightedPeaks = [Double](repeating: 0, count: presentationMaximumChannels.count)
        let normalization = 1.0 / Double(Int64(1) << Int64(23 - decodedOutputShift))
        for frame in 0..<frameCount {
            let base = frame * channelCount
            var cumulativePeak = 0.0
            var presentation = 0
            for channel in 0..<channelCount {
                let sample = Double(samples[base + channel]) * normalization
                let weighted = weightingFilters[channel].process(sample)
                // LFE is intentionally excluded from the broadband detector.
                if channel != 3 { cumulativePeak = max(cumulativePeak, abs(weighted)) }
                while presentation < presentationMaximumChannels.count,
                      channel == presentationMaximumChannels[presentation] {
                    weightedPeaks[presentation] = max(
                        weightedPeaks[presentation], cumulativePeak
                    )
                    presentation += 1
                }
                if presentation == presentationMaximumChannels.count { break }
            }
        }

        var result = [Int?](repeating: nil, count: presentationMaximumChannels.count)
        for presentation in presentationMaximumChannels.indices {
            let blockLevel = max(weightedPeaks[presentation], 1e-10)
            if envelopeLevels[presentation] == 0 {
                envelopeLevels[presentation] = blockLevel
            } else {
                // Loud events must affect cut metadata quickly; boost releases
                // more slowly so noise floors do not pump between access units.
                let seconds = Double(frameCount) / 48_000.0
                let timeConstant = blockLevel > envelopeLevels[presentation] ? 0.050 : 1.500
                let coefficient = 1 - exp(-seconds / timeConstant)
                envelopeLevels[presentation] += coefficient
                    * (blockLevel - envelopeLevels[presentation])
            }

            let levelDB = 20 * log10(max(envelopeLevels[presentation], 1e-10))
            let dialogueNormalization = presentation == 0 ? 29 : 23
            let targetDB = profile.gainDB(
                forWeightedLevel: levelDB,
                dialogueNormalization: dialogueNormalization
            )
            let targetCode = Self.gainCode(forDecibels: targetDB)
            let regularUpdate = accessUnit % Self.accessUnitsPerRegularUpdate == 0
            let adaptiveSpeechUpdate: Bool
            if profile == .speech,
               let previousUpdate = lastUpdateAccessUnits[presentation] {
                adaptiveSpeechUpdate = accessUnit - previousUpdate >= 8
                    && abs(targetCode - lastTargetCodes[presentation]) >= 16
            } else {
                adaptiveSpeechUpdate = false
            }

            if forceUpdate, !regularUpdate, !adaptiveSpeechUpdate {
                result[presentation] = gainCodes[presentation]
                lastUpdateAccessUnits[presentation] = accessUnit
            } else if regularUpdate || adaptiveSpeechUpdate {
                let currentDB = Double(gainCodes[presentation]) * Self.decibelsPerGainCode
                let response: Double
                if targetDB < currentDB {
                    response = 0.70
                } else if lastUpdateAccessUnits[presentation] == nil {
                    response = profile == .speech ? 0.40 : 0.105
                } else {
                    switch profile {
                    case .filmStandard, .filmLight: response = 0.08
                    case .musicStandard, .musicLight: response = 0.10
                    case .speech: response = 0.40
                    }
                }
                let smoothedDB = currentDB + response * (targetDB - currentDB)
                let code = Self.gainCode(forDecibels: smoothedDB)
                gainCodes[presentation] = code
                lastUpdateAccessUnits[presentation] = accessUnit
                lastTargetCodes[presentation] = targetCode
                result[presentation] = code
            }
        }
        return result
    }

    static func gainCode(forDecibels decibels: Double) -> Int {
        max(-256, min(255, Int((decibels / decibelsPerGainCode).rounded())))
    }

    static func extraWord(gainCode: Int, timeCode: Int = interpolationTimeCode) -> UInt16 {
        precondition((-256...255).contains(gainCode))
        precondition((0...7).contains(timeCode))
        let signedNineBits = UInt16(bitPattern: Int16(gainCode)) & 0x01FF
        return (signedNineBits << 7) | (UInt16(timeCode) << 4)
    }
}

extension TrueHDDRCProfile {
    /// Profile transfer curves are expressed at the published -31 dB dialogue
    /// reference, then translated to the presentation's dialogue-normalization
    /// value. The Film Light cut branch follows its published -26...-11 dB
    /// early-cut range.
    func gainDB(forWeightedLevel levelDB: Double, dialogueNormalization: Int) -> Double {
        let translatedLevel = levelDB - Double(31 - dialogueNormalization)
        let gain: Double
        switch self {
        case .filmStandard:
            gain = Self.profileGain(
                level: translatedLevel,
                boostFloor: -43, boostCeiling: -31, maximumBoost: 6,
                nullCeiling: -26, earlyCutCeiling: -16, finalCutCeiling: 4,
                finalRatio: 20
            )
        case .filmLight:
            gain = Self.profileGain(
                level: translatedLevel,
                boostFloor: -53, boostCeiling: -41, maximumBoost: 6,
                nullCeiling: -26, earlyCutCeiling: -11, finalCutCeiling: 4,
                finalRatio: 20
            )
        case .musicStandard:
            gain = Self.profileGain(
                level: translatedLevel,
                boostFloor: -55, boostCeiling: -31, maximumBoost: 12,
                nullCeiling: -26, earlyCutCeiling: -16, finalCutCeiling: 4,
                finalRatio: 20
            )
        case .musicLight:
            if translatedLevel <= -65 {
                gain = 12
            } else if translatedLevel < -41 {
                gain = (-41 - translatedLevel) * 0.5
            } else if translatedLevel <= -21 {
                gain = 0
            } else {
                gain = -min(15, (translatedLevel + 21) * 0.5)
            }
        case .speech:
            if translatedLevel <= -50 {
                gain = 15
            } else if translatedLevel < -31 {
                gain = min(15, (-31 - translatedLevel) * 0.8)
            } else if translatedLevel <= -26 {
                gain = 0
            } else if translatedLevel < -16 {
                gain = -(translatedLevel + 26) * 0.5
            } else {
                gain = -5 - (translatedLevel + 16) * 0.95
            }
        }
        return max(-24, min(gain, self == .speech ? 15 : (self == .musicLight || self == .musicStandard ? 12 : 6)))
    }

    private static func profileGain(
        level: Double,
        boostFloor: Double,
        boostCeiling: Double,
        maximumBoost: Double,
        nullCeiling: Double,
        earlyCutCeiling: Double,
        finalCutCeiling: Double,
        finalRatio: Double
    ) -> Double {
        if level <= boostFloor { return maximumBoost }
        if level < boostCeiling {
            return min(maximumBoost, (boostCeiling - level) * 0.5)
        }
        if level <= nullCeiling { return 0 }
        if level < earlyCutCeiling {
            return -(level - nullCeiling) * 0.5
        }
        let earlyCut = -(earlyCutCeiling - nullCeiling) * 0.5
        let finalSlope = 1 - 1 / finalRatio
        if level < finalCutCeiling {
            return earlyCut - (level - earlyCutCeiling) * finalSlope
        }
        return earlyCut - (finalCutCeiling - earlyCutCeiling) * finalSlope
            - (level - finalCutCeiling)
    }
}

/// Five stable first-order sections implement the standard B-weighting pole
/// layout (two 20.6 Hz high-pass poles, one 158.5 Hz high-pass pole, and two
/// 12.2 kHz low-pass poles), normalized to unity at 1 kHz.
private struct BWeightingFilter {
    private var sections: [FirstOrderFilter]
    private let normalization: Double

    init(sampleRate: Double) {
        sections = [
            FirstOrderFilter(kind: .highPass, frequency: 20.6, sampleRate: sampleRate),
            FirstOrderFilter(kind: .highPass, frequency: 20.6, sampleRate: sampleRate),
            FirstOrderFilter(kind: .highPass, frequency: 158.5, sampleRate: sampleRate),
            FirstOrderFilter(kind: .lowPass, frequency: 12_200, sampleRate: sampleRate),
            FirstOrderFilter(kind: .lowPass, frequency: 12_200, sampleRate: sampleRate),
        ]
        let magnitude = sections.reduce(1.0) {
            $0 * $1.magnitude(at: 1_000, sampleRate: sampleRate)
        }
        normalization = magnitude > 0 ? 1 / magnitude : 1
    }

    mutating func process(_ input: Double) -> Double {
        var value = input
        for index in sections.indices { value = sections[index].process(value) }
        return value * normalization
    }
}

private struct FirstOrderFilter {
    enum Kind { case highPass, lowPass }

    private let b0: Double
    private let b1: Double
    private let a1: Double
    private var previousInput = 0.0
    private var previousOutput = 0.0

    init(kind: Kind, frequency: Double, sampleRate: Double) {
        let k = 2 * sampleRate
        let warped = k * tan(.pi * frequency / sampleRate)
        let divisor = k + warped
        switch kind {
        case .highPass:
            b0 = k / divisor
            b1 = -k / divisor
        case .lowPass:
            b0 = warped / divisor
            b1 = warped / divisor
        }
        a1 = (warped - k) / divisor
    }

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + b1 * previousInput - a1 * previousOutput
        previousInput = input
        previousOutput = output
        return output
    }

    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let angle = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(angle)
        let sine = sin(angle)
        let numeratorReal = b0 + b1 * cosine
        let numeratorImaginary = -b1 * sine
        let denominatorReal = 1 + a1 * cosine
        let denominatorImaginary = -a1 * sine
        let numerator = hypot(numeratorReal, numeratorImaginary)
        let denominator = hypot(denominatorReal, denominatorImaginary)
        return denominator > 0 ? numerator / denominator : 0
    }
}
