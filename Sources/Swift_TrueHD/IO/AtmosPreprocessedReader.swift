// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Foundation

/// Bounded preprocessing of finite-size input objects. Eleven internal diffuse
/// buses feed the spatial reducer; they never become additional transport
/// elements. Seeking resets this render pass, so analysis and PCM preparation
/// reproduce the same source state without storing programme PCM.
final class AtmosPreprocessedReader: TrueHDAudioReader {
    let format: WaveFormat
    let frameCount: UInt64
    let admXML: Data? = nil
    let admChannelAssignment: Data? = nil
    let sourceFrameRate: TrueHDFrameRate?
    let admMetadata: ADMMetadata?
    private let source: TrueHDAudioReader
    private let metadata: ADMMetadata
    private let affected: [Int]
    private let sourceChannels: Int
    private var sourceFrame: UInt64 = 0
    private var pending = [Int32]()
    private var pendingOffset = 0
    private var positionState = [ADMPosition]()
    private var sizeState = [Double]()
    private var previousDry = [Double]()
    private var previousWet = [[Double]]()
    private var filters = [AtmosDecorrelator]()
    private var filterActive = [Bool]()
    private static let hop = 512
    private static let positionDecay = exp(-512.0 / (48_000 * 0.025))
    private static let sizeDecay = exp(-512.0 / (48_000 * 0.020))
    private static let paths = [0, 0, -1, 1, 1, 2, 2, 3, 3, 0, 0]
    private static let signs: [Float] = [1, -1, 0, 1, -1, 1, -1, 1, -1, 1, -1]

    static func isNeeded(for reader: TrueHDAudioReader) -> Bool {
        reader.admMetadata?.channels.contains { $0.blocks.contains { $0.spread > 0 } } ?? false
    }

    init(source: TrueHDAudioReader) throws {
        guard let metadata = source.admMetadata else {
            throw TrueHDError.invalidConfiguration("Diffuse preprocessing requires object metadata")
        }
        self.source = source
        self.metadata = metadata
        sourceChannels = source.format.channelCount
        affected = metadata.channels.indices.filter { metadata.channels[$0].blocks.contains { $0.spread > 0 } }
        frameCount = source.frameCount
        sourceFrameRate = source.sourceFrameRate
        var channels = metadata.channels
        for (index, position) in AtmosDiffuseField.positions.enumerated() {
            channels.append(ADMChannelMetadata(channelFormatID: "STHD_DIFFUSE_\(index)", isObject: true,
                blocks: [ADMPositionBlock(startFrame: 0, endFrame: .max, position: position)]))
        }
        admMetadata = ADMMetadata(channels: channels, programmeStartSeconds: metadata.programmeStartSeconds)
        let original = source.format
        format = WaveFormat(sampleRate: original.sampleRate, channelCount: channels.count,
                            bitsPerSample: original.bitsPerSample, validBitsPerSample: original.validBitsPerSample,
                            blockAlignment: channels.count * original.bitsPerSample / 8,
                            channelMask: 0, isBigEndian: false)
        try seek(toFrame: 0)
    }

    func seek(toFrame frame: UInt64) throws {
        try source.seek(toFrame: frame)
        sourceFrame = frame
        pending.removeAll(keepingCapacity: true)
        pendingOffset = 0
        positionState = affected.map { metadata.channels[$0].position(at: frame) }
        sizeState = affected.map { metadata.channels[$0].spread(at: frame) }
        previousDry = sizeState.map(Self.dryGain)
        previousWet = zip(positionState, sizeState).map(Self.wetGains)
        filters = affected.map { _ in AtmosDecorrelator() }
        filterActive = [Bool](repeating: false, count: affected.count)
    }

    func readFrames(maxCount: Int) throws -> PCMFrameBlock {
        guard maxCount > 0 else { return PCMFrameBlock(samples: [], frameCount: 0) }
        var result = [Int32]()
        result.reserveCapacity(maxCount * format.channelCount)
        while result.count < maxCount * format.channelCount {
            if pendingOffset == pending.count {
                guard sourceFrame < frameCount else { break }
                try prepareBlock()
                pendingOffset = 0
                if pending.isEmpty { break }
            }
            let count = min(pending.count - pendingOffset, maxCount * format.channelCount - result.count)
            result.append(contentsOf: pending[pendingOffset..<(pendingOffset + count)])
            pendingOffset += count
        }
        return PCMFrameBlock(samples: result, frameCount: result.count / format.channelCount)
    }

    private static func dryGain(_ size: Double) -> Double {
        size >= 0.2 ? 0 : pow(cos(max(0, size) * .pi / 0.4), 2)
    }

    private static func wetGains(_ point: ADMPosition, _ size: Double) -> [Double] {
        let wet = 1 - dryGain(size)
        return AtmosDiffuseField.gains(at: point, size: size).map { $0 * wet }
    }

    private func prepareBlock() throws {
        let block = try source.readFrames(maxCount: Self.hop)
        guard block.frameCount > 0 else { pending = []; return }
        let count = block.frameCount
        pending = [Int32](repeating: 0, count: count * format.channelCount)
        for frame in 0..<count {
            let from = frame * sourceChannels, to = frame * format.channelCount
            pending.replaceSubrange(to..<(to + sourceChannels), with: block.samples[from..<(from + sourceChannels)])
        }
        var diffuse = [Float](repeating: 0, count: count * 11)
        let targetFrame = min(frameCount - 1, sourceFrame + UInt64(Self.hop) - 1)
        for (index, channel) in affected.enumerated() {
            let target = metadata.channels[channel].position(at: targetFrame)
            let targetSize = metadata.channels[channel].spread(at: targetFrame)
            func smooth(_ previous: Double, _ target: Double, _ decay: Double) -> Double {
                let value = previous * decay + target * (1 - decay)
                return abs(value - target) <= 1 / 32_768.0 ? target : value
            }
            positionState[index] = ADMPosition(
                x: smooth(positionState[index].x, target.x, Self.positionDecay),
                y: smooth(positionState[index].y, target.y, Self.positionDecay),
                z: smooth(positionState[index].z, target.z, Self.positionDecay))
            sizeState[index] = smooth(sizeState[index], targetSize, Self.sizeDecay)
            let dry = Self.dryGain(sizeState[index])
            let wet = Self.wetGains(positionState[index], sizeState[index])
            let active = dry < 1 || previousDry[index] < 1
            if !active {
                if filterActive[index] { filters[index].reset(); filterActive[index] = false }
                previousDry[index] = dry
                previousWet[index] = wet
                continue
            }
            let input = (0..<count).map { Float(block.samples[$0 * sourceChannels + channel]) / 8_388_608 }
            let decorrelated: [[Float]]
            if !filterActive[index] {
                let primed = filters[index].process([Float](repeating: 0, count: Self.hop) + input)
                decorrelated = primed.map { Array($0.suffix(count)) }
                filterActive[index] = true
            } else {
                decorrelated = filters[index].process(input)
            }
            for frame in 0..<count {
                let fraction = Double(frame) / Double(Self.hop)
                let dryGain = previousDry[index] * (1 - fraction) + dry * fraction
                pending[frame * format.channelCount + channel] = Int32((Double(block.samples[frame * sourceChannels + channel]) * dryGain).rounded())
                for bus in 0..<11 {
                    let gain = Float(previousWet[index][bus] * (1 - fraction) + wet[bus] * fraction)
                    guard gain > 0 else { continue }
                    let path = Self.paths[bus]
                    let signal = path < 0 ? input[frame]
                        : Float(sqrt(0.85)) * input[frame]
                            + Self.signs[bus] * Float(sqrt(0.15)) * decorrelated[path][frame]
                    diffuse[frame * 11 + bus] += signal * gain
                }
            }
            previousDry[index] = dry
            previousWet[index] = wet
        }
        for frame in 0..<count {
            for bus in 0..<11 {
                let value = (Double(diffuse[frame * 11 + bus]) * 8_388_608).rounded()
                guard value.isFinite, value >= Double(Int32.min), value <= Double(Int32.max) else {
                    throw TrueHDError.invalidConfiguration("Diffuse source accumulation exceeded the bounded PCM range")
                }
                pending[frame * format.channelCount + sourceChannels + bus] = Int32(value)
            }
        }
        sourceFrame += UInt64(count)
    }
}
