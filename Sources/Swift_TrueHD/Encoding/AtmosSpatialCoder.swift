// SPDX-License-Identifier: AGPL-3.0-only
//
// Reduces bed and object sources to a stable transport-element set while
// maintaining time-varying positions and a compatible 7.1 render.

import Foundation

struct AtmosPreparedElementCache: Sendable {
    let url: URL
    let headroomShift: Int
    let limiterGains: [UInt32]
}

private struct AtmosHeadroomScan {
    let headroomShift: Int
    let limiterGains: [UInt32]
}

private struct UnscaledElementBlock: Sendable {
    let samples: [Int64]
}

private final class UnscaledElementBlockStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UnscaledElementBlock?]

    init(count: Int) {
        values = [UnscaledElementBlock?](repeating: nil, count: count)
    }

    func set(_ value: UnscaledElementBlock, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func completedValues() -> [UnscaledElementBlock] {
        lock.lock()
        defer { lock.unlock() }
        return values.map {
            precondition($0 != nil)
            return $0!
        }
    }
}

struct AtmosElementBlock: Sendable {
    let samples: [Int32]
    let positions: [ADMPosition]
}

final class AtmosSpatialCoder: @unchecked Sendable {
    static let coreChannelCount = 8
    static let supportedElementCounts = [12, 14, 16]
    private static let metadataIntervalSamples: UInt64 = 1_536
    private static let panningFractionalBits = 20
    private static let panningScale = Int64(1 << panningFractionalBits)

    // OAMD order is LFE, L, R, C, Lb, Rb, Ls, Rs, then object clusters.
    static let fixedElementPositions: [ADMPosition] = [
        ADMPosition(x: 0, y: 1, z: -1),
        ADMPosition(x: -1, y: 1, z: 0),
        ADMPosition(x: 1, y: 1, z: 0),
        ADMPosition(x: 0, y: 1, z: 0),
        ADMPosition(x: -1, y: -1, z: 0),
        ADMPosition(x: 1, y: -1, z: 0),
        ADMPosition(x: -1, y: 0, z: 0),
        ADMPosition(x: 1, y: 0, z: 0)
    ]

    private static let heightCentres: [ADMPosition] = [
        ADMPosition(x: -1, y: 1, z: 1),
        ADMPosition(x: 1, y: 1, z: 1),
        ADMPosition(x: -1, y: 0, z: 1),
        ADMPosition(x: 1, y: 0, z: 1),
        ADMPosition(x: -1, y: -1, z: 1),
        ADMPosition(x: 1, y: -1, z: 1),
        ADMPosition(x: 0, y: 1, z: 1),
        ADMPosition(x: 0, y: -1, z: 1)
    ]

    let elementCount: Int
    private(set) var matrixRenderCoefficients: [[Int32]]

    private let metadata: ADMMetadata
    private let sourceChannelCount: Int
    private let elementBitDepth: Int
    private let minimumElementSample: Int64
    private let maximumElementSample: Int64
    private let baseInputShift: Int
    private let lfeSourceChannel: Int
    private let coreSourceChannels: [[Int]]
    private let spatialSourceChannels: [Int]
    private let clusterCentres: [ADMPosition]
    private var preparedProgrammeStart: UInt64?
    private var preparedProgrammeEnd: UInt64?
    private var preparedSourceActivity = [[Double]]()

    init(
        metadata: ADMMetadata,
        sourceChannelCount: Int,
        elementBitDepth: Int,
        spatialClusterCount: Int = 16
    ) throws {
        guard sourceChannelCount >= 10 else {
            throw TrueHDError.unsupportedInput("ADM Atmos input must contain at least a 7.1.2 bed")
        }
        guard metadata.channels.count == sourceChannelCount else {
            throw TrueHDError.invalidWaveFile("ADM channel metadata count does not match PCM")
        }
        guard (17...20).contains(elementBitDepth) else {
            throw TrueHDError.invalidConfiguration(
                "Atmos element bit depth must be between 17 and 20"
            )
        }
        guard Self.supportedElementCounts.contains(spatialClusterCount) else {
            throw TrueHDError.invalidConfiguration("Spatial clusters must be 12, 14, or 16")
        }

        let requiredBedFormats = [
            "AC_00011004", // LFE
            "AC_00011001", // L
            "AC_00011002", // R
            "AC_00011003", // C
            "AC_00011007", // L rear surround
            "AC_00011008", // R rear surround
            "AC_00011005", // L side surround
            "AC_00011006"  // R side surround
        ]
        let bedChannels = requiredBedFormats.compactMap { formatID in
            metadata.channels.firstIndex {
                $0.isPresent && $0.channelFormatID == formatID
            }
        }
        guard bedChannels.count == requiredBedFormats.count,
              Set(bedChannels).count == requiredBedFormats.count else {
            throw TrueHDError.unsupportedInput(
                "ADM input must map a standard 7.1 bed through chna channel-format IDs"
            )
        }

        self.metadata = metadata
        self.sourceChannelCount = sourceChannelCount
        self.elementBitDepth = elementBitDepth
        minimumElementSample = -(Int64(1) << Int64(elementBitDepth - 1))
        maximumElementSample = (Int64(1) << Int64(elementBitDepth - 1)) - 1
        baseInputShift = 24 - elementBitDepth
        elementCount = spatialClusterCount
        lfeSourceChannel = bedChannels[0]
        // Internal sample order is L, R, C, LFE, Ls, Rs, Lb, Rb.
        let directCoreSources = [
            [bedChannels[1]], [bedChannels[2]], [bedChannels[3]], [bedChannels[0]],
            [bedChannels[6]], [bedChannels[7]], [bedChannels[4]], [bedChannels[5]]
        ]
        coreSourceChannels = directCoreSources
        let coreBedChannels = Set(bedChannels)
        spatialSourceChannels = (0..<sourceChannelCount).filter { channel in
            guard !coreBedChannels.contains(channel) else { return false }
            let item = metadata.channels[channel]
            guard item.isPresent else { return false }
            let isHeightBed = item.channelFormatID == "AC_00011009"
                || item.channelFormatID == "AC_0001100a"
            // A present Object without a position update is still real PCM.
            // Keep it in the spatial render at the neutral centre rather than
            // silently dropping an available source channel.
            return isHeightBed || item.isObject
        }
        let heightCount = spatialClusterCount - Self.coreChannelCount
        let heightIndices: [Int]
        switch heightCount {
        case 4: heightIndices = [0, 1, 4, 5]
        case 6: heightIndices = [0, 1, 2, 3, 4, 5]
        case 8: heightIndices = Array(Self.heightCentres.indices)
        default: preconditionFailure("Unsupported spatial cluster count")
        }
        let selectedCentres = heightIndices.map { Self.heightCentres[$0] }
        clusterCentres = selectedCentres
        matrixRenderCoefficients = selectedCentres.map {
            AtmosCompatibilityMatrix.renderCoefficients(for: $0)
        }
    }

    /// Scans the selected input once and returns one fixed headroom value for the whole encode.
    /// A single gain avoids the discontinuities caused by block-local clipping or gain changes.
    func requiredHeadroomShift(
        reader: TrueHDAudioReader,
        startFrame: UInt64,
        frameCount: UInt64
    ) throws -> Int {
        try prepareSpatialPlans(
            reader: reader, startFrame: startFrame, frameCount: frameCount
        )
        return try scanHeadroom(
            reader: reader, startFrame: startFrame, frameCount: frameCount,
            cacheOutput: nil
        ).headroomShift
    }

    func prepareElementCache(
        reader: TrueHDAudioReader,
        startFrame: UInt64,
        frameCount: UInt64
    ) throws -> AtmosPreparedElementCache {
        try prepareSpatialPlans(
            reader: reader, startFrame: startFrame, frameCount: frameCount
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "turehda-elements-\(UUID().uuidString).pcm64"
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            let scan: AtmosHeadroomScan
            do {
                scan = try scanHeadroom(
                    reader: reader, startFrame: startFrame, frameCount: frameCount,
                    cacheOutput: output
                )
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            return AtmosPreparedElementCache(
                url: url,
                headroomShift: scan.headroomShift,
                limiterGains: scan.limiterGains
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func scanHeadroom(
        reader: TrueHDAudioReader,
        startFrame: UInt64,
        frameCount: UInt64,
        cacheOutput: FileHandle?
    ) throws -> AtmosHeadroomScan {
        try reader.seek(toFrame: startFrame)
        var maximumAbs: Int64 = 0
        var framePeaks = [Int64]()
        if cacheOutput != nil {
            framePeaks.reserveCapacity(Int(frameCount))
        }
        var sourceFrame = startFrame
        let endFrame = startFrame + frameCount
        while sourceFrame < endFrame {
            // Match the encoder's eight-restart-interval batch (8 * 128 * 40).
            // DAMF readers fan one request out across many mono tracks, so this
            // reduces FileHandle calls by roughly 10x without unbounded memory.
            let count = Int(min(UInt64(40_960), endFrame - sourceFrame))
            var reachedEnd = false
            try autoreleasepool {
                let source = try reader.readFrames(maxCount: count)
                guard source.frameCount > 0 else {
                    reachedEnd = true
                    return
                }
                let blockCount = (source.frameCount + 39) / 40
                let blockStore = UnscaledElementBlockStore(count: blockCount)
                let chunkStartFrame = sourceFrame
                let workerCount = min(
                    max(1, ProcessInfo.processInfo.activeProcessorCount), blockCount
                )
                // Use one long-lived job per logical CPU instead of scheduling
                // more than a thousand 40-sample jobs. Each worker owns a
                // strided set of blocks, keeping every core busy while greatly
                // reducing Dispatch and temporary-allocation overhead.
                DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                    for block in stride(from: worker, to: blockCount, by: workerCount) {
                        let frameOffset = block * 40
                        let accessUnitFrameCount = min(
                            40, source.frameCount - frameOffset
                        )
                        let rendered = self.unscaledSamples(
                            source: source.samples,
                            frameCount: accessUnitFrameCount,
                            sourceStartFrame: chunkStartFrame + UInt64(frameOffset),
                            sourceFrameOffset: frameOffset
                        )
                        blockStore.set(rendered, at: block)
                    }
                }
                let blocks = blockStore.completedValues()
                var cachedChunk = [Int64]()
                if cacheOutput != nil {
                    cachedChunk.reserveCapacity(source.frameCount * elementCount)
                }
                for block in blocks {
                    let rendered = block.samples
                    for base in stride(from: 0, to: rendered.count, by: elementCount) {
                        var framePeak: Int64 = 0
                        for value in rendered[base..<(base + elementCount)] {
                            framePeak = max(framePeak, absoluteMagnitude(value))
                        }
                        let core = Array(rendered[base..<(base + 8)])
                        for value in AtmosCompatibilityMatrix.transportCore(core) {
                            framePeak = max(framePeak, absoluteMagnitude(value))
                        }
                        maximumAbs = max(maximumAbs, framePeak)
                        if cacheOutput != nil { framePeaks.append(framePeak) }
                    }
                    if cacheOutput != nil { cachedChunk.append(contentsOf: rendered) }
                }
                if let cacheOutput {
                    let data = cachedChunk.withUnsafeBytes { Data($0) }
                    try cacheOutput.write(contentsOf: data)
                }
                sourceFrame += UInt64(source.frameCount)
            }
            if reachedEnd { break }
        }

        var shift = 0
        while (maximumAbs >> Int64(shift)) > maximumElementSample {
            shift += 1
        }
        return AtmosHeadroomScan(
            headroomShift: shift,
            limiterGains: cacheOutput == nil
                ? []
                : makeCoreLimiterGains(framePeaks: framePeaks)
        )
    }

    /// Reference 20-bit streams keep the declared output shift and limit only impending
    /// overloads. A linked envelope preserves every lossless matrix relation;
    /// the previous whole-program bit shift reduced all channels by 6.02 dB as
    /// soon as a single sample anywhere in the programme exceeded the range.
    private func makeCoreLimiterGains(framePeaks: [Int64]) -> [UInt32] {
        guard !framePeaks.isEmpty else { return [] }

        let safetyLimit = Double(maximumElementSample - 64)
        var gains = [Float](repeating: 1, count: framePeaks.count)
        for index in framePeaks.indices where Double(framePeaks[index]) > safetyLimit {
            gains[index] = Float(safetyLimit / Double(framePeaks[index]))
        }

        // Bound both sides of every gain transition. Looking backwards lets the
        // attack reach the exact required gain before an overload, while the
        // slower forward pass prevents a release edge from modulating the PCM.
        let maximumAttackStep = Float(1.0 / 1_024.0)
        let maximumReleaseStep = Float(1.0 / 4_800.0)
        if gains.count > 1 {
            for index in stride(from: gains.count - 2, through: 0, by: -1) {
                gains[index] = min(
                    gains[index], gains[index + 1] + maximumAttackStep
                )
            }
            for index in 1..<gains.count {
                gains[index] = min(
                    gains[index], gains[index - 1] + maximumReleaseStep
                )
            }
        }

        let unity = Float(UInt32(1) << 30)
        return gains.map { rawGain in
            let gain = max(0, min(1, rawGain))
            return UInt32((gain * unity).rounded(.down))
        }
    }

    private func absoluteMagnitude(_ value: Int64) -> Int64 {
        value == Int64.min ? Int64.max : abs(value)
    }

    private func prepareSpatialPlans(
        reader: TrueHDAudioReader,
        startFrame: UInt64,
        frameCount: UInt64
    ) throws {
        preparedProgrammeStart = startFrame
        preparedProgrammeEnd = startFrame + frameCount
        let intervalCount = Int(
            (frameCount + Self.metadataIntervalSamples - 1) / Self.metadataIntervalSamples
        )
        preparedSourceActivity = [[Double]](
            repeating: [Double](repeating: 0, count: spatialSourceChannels.count),
            count: intervalCount
        )
        guard frameCount > 0, !spatialSourceChannels.isEmpty else { return }

        try reader.seek(toFrame: startFrame)
        var sourceFrame = startFrame
        let endFrame = startFrame + frameCount
        while sourceFrame < endFrame {
            let count = Int(min(UInt64(40_960), endFrame - sourceFrame))
            let source = try reader.readFrames(maxCount: count)
            guard source.frameCount > 0 else { break }
            for frame in 0..<source.frameCount {
                let absoluteFrame = sourceFrame + UInt64(frame)
                let interval = Int(
                    (absoluteFrame - startFrame) / Self.metadataIntervalSamples
                )
                let sourceBase = frame * sourceChannelCount
                for (sourceIndex, channel) in spatialSourceChannels.enumerated() {
                    let shifted = Int64(source.samples[sourceBase + channel])
                        >> Int64(baseInputShift)
                    guard shifted != 0 else { continue }
                    let value = Double(shifted)
                    preparedSourceActivity[interval][sourceIndex] += value * value
                }
            }
            sourceFrame += UInt64(source.frameCount)
        }
    }

    func encode(
        source: [Int32],
        frameCount: Int,
        sourceStartFrame: UInt64
    ) -> AtmosElementBlock {
        precondition(source.count == frameCount * sourceChannelCount)
        let metadataFrame = sourceStartFrame + UInt64(frameCount / 2)
        let unscaled = unscaledSamples(
            source: source,
            frameCount: frameCount,
            sourceStartFrame: sourceStartFrame
        ).samples
        let peaks = stride(from: 0, to: unscaled.count, by: elementCount).map { base in
            var peak: Int64 = 0
            for value in unscaled[base..<(base + elementCount)] {
                peak = max(peak, absoluteMagnitude(value))
            }
            for value in AtmosCompatibilityMatrix.transportCore(
                Array(unscaled[base..<(base + 8)])
            ) {
                peak = max(peak, absoluteMagnitude(value))
            }
            return peak
        }
        let gains = makeCoreLimiterGains(framePeaks: peaks)
        let result = quantize(
            unscaledSamples: unscaled,
            limiterGains: gains[gains.startIndex..<gains.endIndex]
        )
        return AtmosElementBlock(
            samples: result,
            positions: positions(at: metadataFrame)
        )
    }

    func quantize(
        unscaledSamples: [Int64],
        limiterGains: ArraySlice<UInt32>
    ) -> [Int32] {
        precondition(unscaledSamples.count == limiterGains.count * elementCount)
        let unity = UInt32(1) << 30
        var result = [Int32]()
        result.reserveCapacity(unscaledSamples.count)
        for (frameOffset, gain) in limiterGains.enumerated() {
            let base = frameOffset * elementCount
            for value in unscaledSamples[base..<(base + elementCount)] {
                let scaled: Int64
                if gain == unity {
                    scaled = value
                } else if value >= 0 {
                    scaled = (value * Int64(gain)) >> 30
                } else {
                    scaled = -((-value * Int64(gain)) >> 30)
                }
                result.append(limitElementSample(scaled))
            }
        }
        return result
    }

    func positions(
        at metadataFrame: UInt64
    ) -> [ADMPosition] {
        _ = metadataFrame
        return Self.fixedElementPositions + clusterCentres
    }

    /// Produces one decoder-valid complete fixed-basis OAMD state per metadata frame.
    /// Object motion is carried by continuous PCM panning rather than by changing
    /// element identities or collapsing several elements onto one coordinate.
    func metadataUpdates(
        frameStart: UInt64,
        programmeStart: UInt64,
        programmeEnd: UInt64
    ) throws -> [AtmosMetadataUpdate] {
        let frameEnd = min(frameStart + Self.metadataIntervalSamples, programmeEnd)
        guard frameEnd > frameStart else { return [] }
        let firstFrame = frameStart == programmeStart
        return [
            AtmosMetadataUpdate(
                blockOffsetFactor: 0,
                rampDuration: firstFrame ? 0 : Int(frameEnd - frameStart),
                positions: positions(at: firstFrame ? frameStart : frameEnd)
            )
        ]
    }

    func matrixRenderCoefficients(at metadataFrame: UInt64) -> [[Int32]] {
        _ = metadataFrame
        return matrixRenderCoefficients
    }

    private func unscaledSamples(
        source: [Int32],
        frameCount: Int,
        sourceStartFrame: UInt64,
        sourceFrameOffset: Int = 0
    ) -> UnscaledElementBlock {
        let activeSpatialSources = spatialSourceChannels.enumerated().filter { _, channel in
            for frame in 0..<frameCount {
                let index = (sourceFrameOffset + frame) * sourceChannelCount + channel
                if source[index] != 0 { return true }
            }
            return false
        }
        let renderCoefficients = matrixRenderCoefficients
        var result = [Int64](repeating: 0, count: frameCount * elementCount)
        var elements = [Int64](repeating: 0, count: elementCount)
        let panningPlans = activeSpatialSources.map { sourceIndex, channel in
            let first = quantizedPanningGains(
                for: smoothedSourcePosition(channel: channel, at: sourceStartFrame)
            )
            let last = quantizedPanningGains(
                for: smoothedSourcePosition(
                    channel: channel, at: sourceStartFrame + UInt64(frameCount)
                )
            )
            let activeElements = first.indices.filter {
                first[$0] != 0 || last[$0] != 0
            }
            return (
                channel: channel,
                first: first,
                last: last,
                activeElements: activeElements
            )
        }

        for frame in 0..<frameCount {
            let sourceBase = (sourceFrameOffset + frame) * sourceChannelCount
            let outputBase = frame * elementCount
            for index in elements.indices { elements[index] = 0 }

            for (element, channels) in coreSourceChannels.enumerated() {
                var sum: Int64 = 0
                for channel in channels {
                    sum += Int64(source[sourceBase + channel]) >> Int64(baseInputShift)
                }
                elements[element] = sum
            }
            for plan in panningPlans {
                let sample = Int64(source[sourceBase + plan.channel])
                    >> Int64(baseInputShift)
                guard sample != 0 else { continue }
                let elapsed = Int64(frame)
                let remaining = Int64(frameCount - frame)
                for element in plan.activeElements {
                    let gain = (
                        plan.first[element] * remaining
                            + plan.last[element] * elapsed
                    ) / Int64(frameCount)
                    elements[element] += pannedSample(sample, gain: gain)
                }
            }

            // The compatible core carries a continuously panned render of the
            // spatial elements. Summing all Q14 products before rounding lets
            // the inverse matrix remove the exact same fold in presentation 3.
            let spatialElements = elements[Self.coreChannelCount..<elementCount]
            for target in 0..<Self.coreChannelCount where target != 3 {
                elements[target] += AtmosCompatibilityMatrix.foldedContribution(
                    spatialElements: spatialElements,
                    renderCoefficients: renderCoefficients,
                    speaker: target
                )
            }

            // The coded PCM elements remain in TrueHD presentation order. OAMD has
            // its own LFE-first signal mapping and must not reorder these samples.
            for element in 0..<elementCount {
                result[outputBase + element] = elements[element]
            }
        }
        return UnscaledElementBlock(samples: result)
    }

    /// Keeps OAMD elements on a fixed 3D rendering basis and moves sources by
    /// continuously changing their PCM gains. This is the same stable signal
    /// model used by reference encoders: rapid XYZ updates cannot collapse all
    /// transport elements onto one coordinate or swap an audible source between
    /// unrelated Object identities.
    private func quantizedPanningGains(for input: ADMPosition) -> [Int64] {
        let position = input.clamped()
        var gains = [Double](repeating: 0, count: elementCount)

        func equalPowerPair(
            first: Int,
            second: Int,
            fraction: Double
        ) -> [(Int, Double)] {
            let angle = min(1, max(0, fraction)) * .pi / 2
            return [(first, cos(angle)), (second, sin(angle))]
        }

        let front: [(Int, Double)]
        if position.x < 0 {
            front = equalPowerPair(
                first: 0, second: 2, fraction: position.x + 1
            )
        } else {
            front = equalPowerPair(
                first: 2, second: 1, fraction: position.x
            )
        }
        let side = equalPowerPair(
            first: 4, second: 5, fraction: (position.x + 1) / 2
        )
        let rear = equalPowerPair(
            first: 6, second: 7, fraction: (position.x + 1) / 2
        )
        let firstRow: [(Int, Double)]
        let secondRow: [(Int, Double)]
        let rowFraction: Double
        if position.y >= 0 {
            firstRow = side
            secondRow = front
            rowFraction = position.y
        } else {
            firstRow = side
            secondRow = rear
            rowFraction = -position.y
        }
        let rowAngle = rowFraction * .pi / 2
        let elevation = min(1, max(0, position.z)) * .pi / 2
        let horizontalWeight = cos(elevation)
        for (element, gain) in firstRow {
            gains[element] += gain * cos(rowAngle) * horizontalWeight
        }
        for (element, gain) in secondRow {
            gains[element] += gain * sin(rowAngle) * horizontalWeight
        }

        let heightWeight = sin(elevation)
        if heightWeight > 0 {
            func rowPanning(_ indices: [Int]) -> [(Int, Double)] {
                let row = indices.sorted {
                    clusterCentres[$0].x < clusterCentres[$1].x
                }
                guard let first = row.first else { return [] }
                guard row.count > 1 else { return [(first, 1)] }
                if position.x <= clusterCentres[first].x { return [(first, 1)] }
                let last = row[row.count - 1]
                if position.x >= clusterCentres[last].x { return [(last, 1)] }
                for pair in zip(row, row.dropFirst()) {
                    let leftX = clusterCentres[pair.0].x
                    let rightX = clusterCentres[pair.1].x
                    if position.x <= rightX {
                        return equalPowerPair(
                            first: pair.0,
                            second: pair.1,
                            fraction: (position.x - leftX) / (rightX - leftX)
                        )
                    }
                }
                return [(last, 1)]
            }

            let frontHeight = rowPanning(clusterCentres.indices.filter {
                clusterCentres[$0].y > 0.5
            })
            let sideHeight = rowPanning(clusterCentres.indices.filter {
                abs(clusterCentres[$0].y) <= 0.5
            })
            let rearHeight = rowPanning(clusterCentres.indices.filter {
                clusterCentres[$0].y < -0.5
            })
            let firstHeightRow: [(Int, Double)]
            let secondHeightRow: [(Int, Double)]
            let heightRowFraction: Double
            if sideHeight.isEmpty {
                firstHeightRow = rearHeight
                secondHeightRow = frontHeight
                heightRowFraction = (position.y + 1) / 2
            } else if position.y >= 0 {
                firstHeightRow = sideHeight
                secondHeightRow = frontHeight
                heightRowFraction = position.y
            } else {
                firstHeightRow = sideHeight
                secondHeightRow = rearHeight
                heightRowFraction = -position.y
            }
            let heightRowAngle = min(1, max(0, heightRowFraction)) * .pi / 2
            for (cluster, gain) in firstHeightRow {
                gains[Self.coreChannelCount + cluster] +=
                    gain * cos(heightRowAngle) * heightWeight
            }
            for (cluster, gain) in secondHeightRow {
                gains[Self.coreChannelCount + cluster] +=
                    gain * sin(heightRowAngle) * heightWeight
            }
        }

        return gains.map {
            Int64(($0 * Double(Self.panningScale)).rounded())
        }
    }

    /// A one-metadata-frame causal ramp turns dense zero-length DAMF updates
    /// into a continuous trajectory. Sampling the current and preceding frame
    /// boundaries avoids looking ahead and matches the 1536-sample OAMD cadence.
    private func smoothedSourcePosition(
        channel: Int,
        at frame: UInt64
    ) -> ADMPosition {
        let programmeStart = preparedProgrammeStart ?? 0
        guard frame > programmeStart else {
            return sourcePosition(channel: channel, at: programmeStart)
        }
        let relative = frame - programmeStart
        let interval = relative / Self.metadataIntervalSamples
        guard interval > 0 else {
            return sourcePosition(channel: channel, at: programmeStart)
        }
        let intervalStart = programmeStart
            + interval * Self.metadataIntervalSamples
        let previousStart = intervalStart - Self.metadataIntervalSamples
        let from = sourcePosition(channel: channel, at: previousStart)
        let to = sourcePosition(channel: channel, at: intervalStart)
        let fraction = Double(frame - intervalStart)
            / Double(Self.metadataIntervalSamples)
        return ADMPosition(
            x: from.x + (to.x - from.x) * fraction,
            y: from.y + (to.y - from.y) * fraction,
            z: from.z + (to.z - from.z) * fraction
        ).clamped()
    }

    private func pannedSample(_ sample: Int64, gain: Int64) -> Int64 {
        let product = sample * gain
        if product >= 0 {
            return (product + Self.panningScale / 2) / Self.panningScale
        }
        return -((-product + Self.panningScale / 2) / Self.panningScale)
    }

    func spatialAccuracyReport() -> TrueHDSpatialAccuracy {
        var maximumActive = 0
        var sourceIntervals = 0
        var exactSourceIntervals = 0
        var maximumError = 0.0
        var weightedSquaredError = 0.0
        var totalEnergy = 0.0
        let basisPositions = [
            ADMPosition(x: -1, y: 1, z: 0),
            ADMPosition(x: 1, y: 1, z: 0),
            ADMPosition(x: 0, y: 1, z: 0),
            ADMPosition(x: 0, y: 1, z: -1),
            ADMPosition(x: -1, y: 0, z: 0),
            ADMPosition(x: 1, y: 0, z: 0),
            ADMPosition(x: -1, y: -1, z: 0),
            ADMPosition(x: 1, y: -1, z: 0),
        ] + clusterCentres

        for interval in preparedSourceActivity.indices {
            let activity = preparedSourceActivity[interval]
            let active = activity.indices.filter { activity[$0] > 0 }
            maximumActive = max(maximumActive, active.count)
            sourceIntervals += active.count

            let start = preparedProgrammeStart ?? 0
            let intervalStart = start
                + UInt64(interval) * Self.metadataIntervalSamples
            let targetFrame = min(
                intervalStart + Self.metadataIntervalSamples / 2,
                preparedProgrammeEnd ?? .max
            )

            for sourceIndex in active {
                let source = sourcePosition(
                    channel: spatialSourceChannels[sourceIndex], at: targetFrame
                )
                let gains = quantizedPanningGains(for: source)
                var power = 0.0
                var effective = ADMPosition.centre
                for element in gains.indices where gains[element] != 0 {
                    let gain = Double(gains[element]) / Double(Self.panningScale)
                    let weight = gain * gain
                    power += weight
                    effective.x += basisPositions[element].x * weight
                    effective.y += basisPositions[element].y * weight
                    effective.z += basisPositions[element].z * weight
                }
                if power > 0 {
                    effective.x /= power
                    effective.y /= power
                    effective.z /= power
                }
                let squaredError = Self.distanceSquared(source, effective)
                if squaredError < 1e-12 {
                    exactSourceIntervals += 1
                }
                maximumError = max(maximumError, sqrt(squaredError))
                weightedSquaredError += squaredError * activity[sourceIndex]
                totalEnergy += activity[sourceIndex]
            }
        }

        return TrueHDSpatialAccuracy(
            intervalCount: preparedSourceActivity.count,
            maximumActiveSpatialSources: maximumActive,
            groupedIntervalCount: 0,
            sourceIntervalCount: sourceIntervals,
            exactlyRepresentedSourceIntervals: exactSourceIntervals,
            assignmentChangeCount: 0,
            maximumQuantizedPositionError: maximumError,
            energyWeightedRMSQuantizedPositionError: totalEnergy > 0
                ? sqrt(weightedSquaredError / totalEnergy)
                : 0
        )
    }

    private func sourcePosition(channel: Int, at frame: UInt64) -> ADMPosition {
        let item = metadata.channels[channel]
        if !item.blocks.isEmpty { return item.position(at: frame) }
        switch item.channelFormatID {
        case "AC_00011009": return ADMPosition(x: -0.7, y: 0, z: 0.8)
        case "AC_0001100a": return ADMPosition(x: 0.7, y: 0, z: 0.8)
        default: return .centre
        }
    }

    private func limitElementSample(_ value: Int64) -> Int32 {
        Int32(max(minimumElementSample, min(maximumElementSample, value)))
    }

    private static func distanceSquared(_ lhs: ADMPosition, _ rhs: ADMPosition) -> Double {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        let z = lhs.z - rhs.z
        return x * x + y * y + z * z
    }

}
