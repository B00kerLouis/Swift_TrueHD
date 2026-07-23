// SPDX-License-Identifier: AGPL-3.0-only
//
// Reduces bed and object sources to a stable transport-element set while
// maintaining time-varying positions and a compatible 7.1 render.

import Foundation

struct AtmosPreparedElementCache: Sendable {
    let url: URL
    let headroomShift: Int
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
        ADMPosition(x: -0.7, y: 0.8, z: 0.8),
        ADMPosition(x: 0.7, y: 0.8, z: 0.8),
        ADMPosition(x: -0.9, y: 0.1, z: 0.5),
        ADMPosition(x: 0.9, y: 0.1, z: 0.5),
        ADMPosition(x: -0.7, y: -0.8, z: 0.8),
        ADMPosition(x: 0.7, y: -0.8, z: 0.8),
        ADMPosition(x: 0, y: 0.8, z: 0.75),
        ADMPosition(x: 0, y: -0.8, z: 0.75)
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
    private var additionalHeadroomShift = 0
    private var preparedProgrammeStart: UInt64?
    private var preparedProgrammeEnd: UInt64?
    private var preparedSourceActivity = [[Double]]()
    private var preparedClusterAssignments = [[Int]]()

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
        )
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
            let shift: Int
            do {
                shift = try scanHeadroom(
                    reader: reader, startFrame: startFrame, frameCount: frameCount,
                    cacheOutput: output
                )
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            return AtmosPreparedElementCache(url: url, headroomShift: shift)
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
    ) throws -> Int {
        try reader.seek(toFrame: startFrame)
        var maximumAbs: Int64 = 0
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
                    for value in rendered {
                        maximumAbs = max(
                            maximumAbs,
                            value == Int64.min ? Int64.max : abs(value)
                        )
                    }
                    for base in stride(from: 0, to: rendered.count, by: elementCount) {
                        let core = Array(rendered[base..<(base + 8)])
                        for value in AtmosCompatibilityMatrix.transportCore(core) {
                            maximumAbs = max(
                                maximumAbs,
                                value == Int64.min ? Int64.max : abs(value)
                            )
                        }
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
        return shift
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
        preparedClusterAssignments.removeAll(keepingCapacity: true)
        guard frameCount > 0, !spatialSourceChannels.isEmpty else {
            preparedClusterAssignments = Array(
                repeating: [Int](repeating: -1, count: spatialSourceChannels.count),
                count: intervalCount
            )
            return
        }

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
        preparedClusterAssignments = makeStableClusterAssignments(
            programmeStart: startFrame,
            programmeEnd: endFrame,
            activity: preparedSourceActivity
        )
    }

    private func makeStableClusterAssignments(
        programmeStart: UInt64,
        programmeEnd: UInt64,
        activity: [[Double]]
    ) -> [[Int]] {
        var previous = [Int](repeating: -1, count: spatialSourceChannels.count)
        var previousCentres = clusterCentres
        var assignments = [[Int]]()
        assignments.reserveCapacity(activity.count)

        for interval in activity.indices {
            let active = activity[interval].indices.filter {
                activity[interval][$0] > 0
            }
            var current = [Int](repeating: -1, count: spatialSourceChannels.count)
            let intervalStart = programmeStart
                + UInt64(interval) * Self.metadataIntervalSamples
            let targetFrame = interval == 0
                ? intervalStart
                : min(intervalStart + Self.metadataIntervalSamples, programmeEnd)

            if active.count <= clusterCentres.count {
                var used = Set<Int>()
                // Keep persistent Objects on the same transport element. This
                // avoids changing signal identity while its OAMD position moves.
                for sourceIndex in active.sorted(by: {
                    activity[interval][$0] > activity[interval][$1]
                }) {
                    let prior = previous[sourceIndex]
                    guard prior >= 0, !used.contains(prior) else { continue }
                    current[sourceIndex] = prior
                    used.insert(prior)
                }
                for sourceIndex in active where current[sourceIndex] < 0 {
                    let position = sourcePosition(
                        channel: spatialSourceChannels[sourceIndex], at: targetFrame
                    )
                    let available = clusterCentres.indices.filter { !used.contains($0) }
                    let cluster = available.min {
                        Self.distanceSquared(position, clusterCentres[$0])
                            < Self.distanceSquared(position, clusterCentres[$1])
                    }!
                    current[sourceIndex] = cluster
                    used.insert(cluster)
                }
            } else {
                // More audible sources than transport elements requires lossy
                // grouping. Weighted Lloyd iterations minimize source-to-group
                // XYZ error, while a small prior-slot penalty prevents unstable
                // identity swaps for Objects near a cluster boundary.
                let positions = Dictionary(uniqueKeysWithValues: active.map {
                    (
                        $0,
                        sourcePosition(
                            channel: spatialSourceChannels[$0], at: targetFrame
                        )
                    )
                })
                var seeds = [positions[active.max {
                    activity[interval][$0] < activity[interval][$1]
                }!]!]
                while seeds.count < clusterCentres.count {
                    let next = active.max { lhs, rhs in
                        let lhsDistance = seeds.map {
                            Self.distanceSquared(positions[lhs]!, $0)
                        }.min()!
                        let rhsDistance = seeds.map {
                            Self.distanceSquared(positions[rhs]!, $0)
                        }.min()!
                        return lhsDistance < rhsDistance
                    }!
                    seeds.append(positions[next]!)
                }

                // Match new geometric seeds onto the preceding physical slots
                // so k-center reinitialization does not arbitrarily permute
                // transport-element identity between metadata intervals.
                var centres = previousCentres
                var unmatchedSeeds = Set(seeds.indices)
                var unmatchedSlots = Set(centres.indices)
                while let pair = unmatchedSeeds.flatMap({ seed in
                    unmatchedSlots.map { slot in
                        (seed, slot, Self.distanceSquared(seeds[seed], previousCentres[slot]))
                    }
                }).min(by: { $0.2 < $1.2 }) {
                    centres[pair.1] = seeds[pair.0]
                    unmatchedSeeds.remove(pair.0)
                    unmatchedSlots.remove(pair.1)
                }
                for _ in 0..<8 {
                    for sourceIndex in active {
                        let position = positions[sourceIndex]!
                        current[sourceIndex] = centres.indices.min {
                            let lhsPenalty = previous[sourceIndex] >= 0
                                && previous[sourceIndex] != $0 ? 0.01 : 0
                            let rhsPenalty = previous[sourceIndex] >= 0
                                && previous[sourceIndex] != $1 ? 0.01 : 0
                            return Self.distanceSquared(position, centres[$0]) + lhsPenalty
                                < Self.distanceSquared(position, centres[$1]) + rhsPenalty
                        }!
                    }

                    // Do not waste transport capacity. Seed an empty group with
                    // the highest-error source from a group that has a spare.
                    var counts = [Int](repeating: 0, count: centres.count)
                    for sourceIndex in active { counts[current[sourceIndex]] += 1 }
                    for empty in counts.indices where counts[empty] == 0 {
                        let candidate = active.filter {
                            counts[current[$0]] > 1
                        }.max {
                            let lhs = Self.distanceSquared(
                                positions[$0]!, centres[current[$0]]
                            )
                            let rhs = Self.distanceSquared(
                                positions[$1]!, centres[current[$1]]
                            )
                            return lhs < rhs
                        }!
                        counts[current[candidate]] -= 1
                        current[candidate] = empty
                        counts[empty] = 1
                    }

                    var weights = [Double](repeating: 0, count: centres.count)
                    var sums = Array(
                        repeating: ADMPosition.centre, count: centres.count
                    )
                    for sourceIndex in active {
                        let cluster = current[sourceIndex]
                        let weight = activity[interval][sourceIndex]
                        let position = positions[sourceIndex]!
                        weights[cluster] += weight
                        sums[cluster].x += position.x * weight
                        sums[cluster].y += position.y * weight
                        sums[cluster].z += position.z * weight
                    }
                    for cluster in centres.indices where weights[cluster] > 0 {
                        centres[cluster] = ADMPosition(
                            x: sums[cluster].x / weights[cluster],
                            y: sums[cluster].y / weights[cluster],
                            z: sums[cluster].z / weights[cluster]
                        ).clamped()
                    }
                }
                previousCentres = centres
            }

            for sourceIndex in active { previous[sourceIndex] = current[sourceIndex] }
            if active.count <= clusterCentres.count {
                for sourceIndex in active {
                    previousCentres[current[sourceIndex]] = sourcePosition(
                        channel: spatialSourceChannels[sourceIndex], at: targetFrame
                    )
                }
            }
            assignments.append(current)
        }
        return assignments
    }

    func setAdditionalHeadroomShift(_ shift: Int) {
        additionalHeadroomShift = max(0, shift)
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
        let result = quantize(unscaledSamples: unscaled)
        return AtmosElementBlock(
            samples: result,
            positions: positions(at: metadataFrame)
        )
    }

    func quantize(unscaledSamples: [Int64]) -> [Int32] {
        unscaledSamples.map {
            limitElementSample($0 >> Int64(additionalHeadroomShift))
        }
    }

    func positions(
        at metadataFrame: UInt64,
        sourceActivity: [Double]? = nil,
        clusterAssignments: [Int]? = nil
    ) -> [ADMPosition] {
        precondition(sourceActivity == nil || sourceActivity!.count == spatialSourceChannels.count)
        precondition(
            clusterAssignments == nil
                || clusterAssignments!.count == spatialSourceChannels.count
        )
        var result = Array(Self.fixedElementPositions)
        var totalWeights = [Double](repeating: 0, count: clusterCentres.count)
        var x = [Double](repeating: 0, count: clusterCentres.count)
        var y = [Double](repeating: 0, count: clusterCentres.count)
        var z = [Double](repeating: 0, count: clusterCentres.count)
        for (sourceIndex, channel) in spatialSourceChannels.enumerated() {
            let activity = sourceActivity?[sourceIndex] ?? 1
            guard activity > 0 else { continue }
            let position = sourcePosition(channel: channel, at: metadataFrame)
            let preparedCluster = clusterAssignments?[sourceIndex] ?? -1
            let cluster = preparedCluster >= 0
                ? preparedCluster
                : nearestCluster(to: position)
            // Activity is accumulated as PCM energy. A transport element that
            // must carry several Objects therefore follows their audible energy
            // centroid rather than silent declarations or track count.
            totalWeights[cluster] += activity
            x[cluster] += position.x * activity
            y[cluster] += position.y * activity
            z[cluster] += position.z * activity
        }
        for cluster in clusterCentres.indices {
            if totalWeights[cluster] > 0 {
                result.append(
                    ADMPosition(
                        x: x[cluster] / totalWeights[cluster],
                        y: y[cluster] / totalWeights[cluster],
                        z: z[cluster] / totalWeights[cluster]
                    ).clamped()
                )
            } else {
                result.append(clusterCentres[cluster])
            }
        }
        return result
    }

    /// Produces one decoder-valid complete OAMD state for a 1536-sample frame.
    /// The state targets the real interpolated source trajectory at the frame
    /// boundary, so consecutive metadata frames form a continuous ramp without
    /// the unsupported multi-block syntax that caused Object-audio dropouts.
    func metadataUpdates(
        frameStart: UInt64,
        programmeStart: UInt64,
        programmeEnd: UInt64
    ) throws -> [AtmosMetadataUpdate] {
        let frameEnd = min(frameStart + Self.metadataIntervalSamples, programmeEnd)
        guard frameEnd > frameStart else { return [] }
        let firstFrame = frameStart == programmeStart
        let activity: [Double]?
        let assignments: [Int]?
        if preparedProgrammeStart == programmeStart,
           frameStart >= programmeStart {
            let interval = Int((frameStart - programmeStart) / Self.metadataIntervalSamples)
            activity = preparedSourceActivity.indices.contains(interval)
                ? preparedSourceActivity[interval]
                : nil
            assignments = preparedClusterAssignments.indices.contains(interval)
                ? preparedClusterAssignments[interval]
                : nil
        } else {
            activity = nil
            assignments = nil
        }
        return [
            AtmosMetadataUpdate(
                blockOffsetFactor: 0,
                rampDuration: firstFrame ? 0 : Int(frameEnd - frameStart),
                positions: positions(
                    at: firstFrame ? frameStart : frameEnd,
                    sourceActivity: activity,
                    clusterAssignments: assignments
                )
            )
        ]
    }

    func matrixRenderCoefficients(at metadataFrame: UInt64) -> [[Int32]] {
        let activity: [Double]?
        let assignments: [Int]?
        if let start = preparedProgrammeStart,
           let end = preparedProgrammeEnd,
           metadataFrame >= start, metadataFrame < end {
            let interval = Int(
                (metadataFrame - start) / Self.metadataIntervalSamples
            )
            activity = preparedSourceActivity.indices.contains(interval)
                ? preparedSourceActivity[interval]
                : nil
            assignments = preparedClusterAssignments.indices.contains(interval)
                ? preparedClusterAssignments[interval]
                : nil
        } else {
            activity = nil
            assignments = nil
        }
        return positions(
            at: metadataFrame,
            sourceActivity: activity,
            clusterAssignments: assignments
        ).dropFirst(Self.coreChannelCount).map {
            AtmosCompatibilityMatrix.renderCoefficients(for: $0)
        }
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
        let metadataFrame = sourceStartFrame + UInt64(frameCount / 2)
        let renderCoefficients = matrixRenderCoefficients(at: metadataFrame)
        var result = [Int64](repeating: 0, count: frameCount * elementCount)
        var elements = [Int64](repeating: 0, count: elementCount)

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
            let absoluteFrame = sourceStartFrame + UInt64(frame)
            for (sourceIndex, channel) in activeSpatialSources {
                let sample = Int64(source[sourceBase + channel])
                    >> Int64(baseInputShift)
                guard sample != 0 else { continue }
                let cluster = clusterAssignment(
                    sourceIndex: sourceIndex,
                    channel: channel,
                    at: absoluteFrame
                )
                elements[Self.coreChannelCount + cluster] += sample
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

    private func clusterAssignment(
        sourceIndex: Int,
        channel: Int,
        at frame: UInt64
    ) -> Int {
        if let start = preparedProgrammeStart,
           let end = preparedProgrammeEnd,
           frame >= start, frame < end {
            let interval = Int((frame - start) / Self.metadataIntervalSamples)
            if preparedClusterAssignments.indices.contains(interval) {
                let cluster = preparedClusterAssignments[interval][sourceIndex]
                if cluster >= 0 { return cluster }
            }
        }
        return nearestCluster(to: sourcePosition(channel: channel, at: frame))
    }

    private func nearestCluster(to position: ADMPosition) -> Int {
        clusterCentres.indices.min {
            Self.distanceSquared(position, clusterCentres[$0])
                < Self.distanceSquared(position, clusterCentres[$1])
        } ?? 0
    }

    func spatialAccuracyReport() -> TrueHDSpatialAccuracy {
        var maximumActive = 0
        var groupedIntervals = 0
        var sourceIntervals = 0
        var exactSourceIntervals = 0
        var assignmentChanges = 0
        var maximumError = 0.0
        var weightedSquaredError = 0.0
        var totalEnergy = 0.0

        for interval in preparedSourceActivity.indices {
            let activity = preparedSourceActivity[interval]
            let assignments = preparedClusterAssignments[interval]
            let active = activity.indices.filter { activity[$0] > 0 }
            maximumActive = max(maximumActive, active.count)
            if active.count > clusterCentres.count { groupedIntervals += 1 }
            sourceIntervals += active.count

            let start = preparedProgrammeStart ?? 0
            let intervalStart = start
                + UInt64(interval) * Self.metadataIntervalSamples
            let targetFrame = interval == 0
                ? intervalStart
                : min(
                    intervalStart + Self.metadataIntervalSamples,
                    preparedProgrammeEnd ?? .max
                )
            let clusterPositions = positions(
                at: targetFrame,
                sourceActivity: activity,
                clusterAssignments: assignments
            )

            for sourceIndex in active {
                let source = sourcePosition(
                    channel: spatialSourceChannels[sourceIndex], at: targetFrame
                )
                let cluster = assignments[sourceIndex]
                let unquantized = clusterPositions[Self.coreChannelCount + cluster]
                if Self.distanceSquared(source, unquantized) < 1e-12 {
                    exactSourceIntervals += 1
                }
                let encoded = Self.quantizedOAMDPosition(unquantized)
                let squaredError = Self.distanceSquared(source, encoded)
                maximumError = max(maximumError, sqrt(squaredError))
                weightedSquaredError += squaredError * activity[sourceIndex]
                totalEnergy += activity[sourceIndex]

                if interval > 0,
                   preparedSourceActivity[interval - 1][sourceIndex] > 0,
                   preparedClusterAssignments[interval - 1][sourceIndex] != cluster {
                    assignmentChanges += 1
                }
            }
        }

        return TrueHDSpatialAccuracy(
            intervalCount: preparedSourceActivity.count,
            maximumActiveSpatialSources: maximumActive,
            groupedIntervalCount: groupedIntervals,
            sourceIntervalCount: sourceIntervals,
            exactlyRepresentedSourceIntervals: exactSourceIntervals,
            assignmentChangeCount: assignmentChanges,
            maximumQuantizedPositionError: maximumError,
            energyWeightedRMSQuantizedPositionError: totalEnergy > 0
                ? sqrt(weightedSquaredError / totalEnergy)
                : 0
        )
    }

    private static func quantizedOAMDPosition(_ input: ADMPosition) -> ADMPosition {
        let position = input.clamped()
        let xCode = min(62, max(0, Int(((position.x + 1) * 31).rounded())))
        let yCode = min(62, max(0, Int(((1 - position.y) * 31).rounded())))
        let zCode = min(15, max(0, Int((abs(position.z) * 15).rounded())))
        return ADMPosition(
            x: Double(xCode) / 31 - 1,
            y: 1 - Double(yCode) / 31,
            z: position.z >= 0 ? Double(zCode) / 15 : -Double(zCode) / 15
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
