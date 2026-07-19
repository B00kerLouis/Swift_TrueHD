// SPDX-License-Identifier: AGPL-3.0-only
//
// Reduces bed and object sources to a stable transport-element set while
// maintaining time-varying positions and a compatible 7.1 render.

import Foundation

struct AtmosPreparedElementCache: Sendable {
    let url: URL
    let headroomShift: Int
}

private final class UnscaledElementBlockStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[Int64]?]

    init(count: Int) {
        values = [[Int64]?](repeating: nil, count: count)
    }

    func set(_ value: [Int64], at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func completedValues() -> [[Int64]] {
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
    private(set) var matrixRenderTargets: [[Int]]

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
    private var clusteredSourceChannels = [[Int]]()
    private var additionalHeadroomShift = 0

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
        var directCoreSources = [
            [bedChannels[1]], [bedChannels[2]], [bedChannels[3]], [bedChannels[0]],
            [bedChannels[6]], [bedChannels[7]], [bedChannels[4]], [bedChannels[5]]
        ]
        var bedAlignedObjects = Set<Int>()
        for channel in 0..<sourceChannelCount {
            let item = metadata.channels[channel]
            guard item.isPresent, item.isObject,
                  let coreElement = Self.bedAlignedCoreElement(item) else { continue }
            directCoreSources[coreElement].append(channel)
            bedAlignedObjects.insert(channel)
        }
        coreSourceChannels = directCoreSources
        let coreBedChannels = Set(bedChannels)
        spatialSourceChannels = (0..<sourceChannelCount).filter { channel in
            guard !coreBedChannels.contains(channel),
                  !bedAlignedObjects.contains(channel) else { return false }
            let item = metadata.channels[channel]
            guard item.isPresent else { return false }
            let isHeightBed = item.channelFormatID == "AC_00011009"
                || item.channelFormatID == "AC_0001100a"
            return isHeightBed || (item.isObject && !item.blocks.isEmpty)
        }

        let heightCount = spatialClusterCount - Self.coreChannelCount
        let heightIndices: [Int]
        switch heightCount {
        case 4: heightIndices = [0, 1, 4, 5]
        case 6: heightIndices = [0, 1, 2, 3, 4, 5]
        case 8: heightIndices = Array(Self.heightCentres.indices)
        default: preconditionFailure("Unsupported spatial cluster count")
        }
        clusterCentres = heightIndices.map { Self.heightCentres[$0] }

        self.matrixRenderTargets = []
        var assignment = [Int: Int]()
        for channel in spatialSourceChannels {
            let position = sourcePosition(channel: channel, at: 0)
            assignment[channel] = clusterCentres.indices.min {
                Self.distanceSquared(position, clusterCentres[$0])
                    < Self.distanceSquared(position, clusterCentres[$1])
            } ?? 0
        }
        var clustered = Array(repeating: [Int](), count: clusterCentres.count)
        for channel in spatialSourceChannels {
            clustered[assignment[channel] ?? 0].append(channel)
        }
        clusteredSourceChannels = clustered
        matrixRenderTargets = makeMatrixRenderTargets(at: 0)
    }

    /// Scans the selected input once and returns one fixed headroom value for the whole encode.
    /// A single gain avoids the discontinuities caused by block-local clipping or gain changes.
    func requiredHeadroomShift(
        reader: TrueHDAudioReader,
        startFrame: UInt64,
        frameCount: UInt64
    ) throws -> Int {
        try scanHeadroom(
            reader: reader, startFrame: startFrame, frameCount: frameCount,
            cacheOutput: nil
        )
    }

    func prepareElementCache(
        reader: TrueHDAudioReader,
        startFrame: UInt64,
        frameCount: UInt64
    ) throws -> AtmosPreparedElementCache {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-truehd-elements-\(UUID().uuidString).pcm64"
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
                DispatchQueue.concurrentPerform(iterations: blockCount) { block in
                    let frameOffset = block * 40
                    let accessUnitFrameCount = min(40, source.frameCount - frameOffset)
                    let rendered = self.unscaledSamples(
                        source: source.samples,
                        frameCount: accessUnitFrameCount,
                        sourceStartFrame: chunkStartFrame + UInt64(frameOffset),
                        sourceFrameOffset: frameOffset
                    )
                    blockStore.set(rendered, at: block)
                }
                let blocks = blockStore.completedValues()
                var cachedChunk = [Int64]()
                if cacheOutput != nil {
                    cachedChunk.reserveCapacity(source.frameCount * elementCount)
                }
                for rendered in blocks {
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
        )
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

    func positions(at metadataFrame: UInt64) -> [ADMPosition] {
        let groups = clusteredSourceChannels
        var result = Array(Self.fixedElementPositions)
        for (cluster, channels) in groups.enumerated() {
            guard !channels.isEmpty else {
                result.append(clusterCentres[cluster])
                continue
            }
            var sum = ADMPosition.centre
            for channel in channels {
                let position = sourcePosition(channel: channel, at: metadataFrame)
                sum.x += position.x
                sum.y += position.y
                sum.z += position.z
            }
            let scale = 1 / Double(channels.count)
            result.append(
                ADMPosition(x: sum.x * scale, y: sum.y * scale, z: sum.z * scale).clamped()
            )
        }
        return result
    }

    func matrixRenderTargets(at metadataFrame: UInt64) -> [[Int]] {
        makeMatrixRenderTargets(at: metadataFrame)
    }

    private func unscaledSamples(
        source: [Int32],
        frameCount: Int,
        sourceStartFrame: UInt64,
        sourceFrameOffset: Int = 0
    ) -> [Int64] {
        let metadataFrame = sourceStartFrame + UInt64(frameCount / 2)
        let groups = clusteredSourceChannels
        let targets = makeMatrixRenderTargets(at: metadataFrame)
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
            for (cluster, channels) in groups.enumerated() {
                var sum: Int64 = 0
                for channel in channels {
                    sum += Int64(source[sourceBase + channel]) >> Int64(baseInputShift)
                }
                elements[Self.coreChannelCount + cluster] = sum
            }

            // The compatible core carries a rounded half-sum of the spatial
            // elements assigned to each speaker. Summing before rounding lets
            // the inverse matrix remove that fold without a one-sample bias.
            for target in 0..<Self.coreChannelCount where target != 3 {
                var renderedSum: Int64 = 0
                for (cluster, clusterTargets) in targets.enumerated()
                    where clusterTargets.contains(target) {
                    renderedSum += elements[Self.coreChannelCount + cluster]
                }
                elements[target] += (renderedSum + 1) >> 1
            }

            // The coded PCM elements remain in TrueHD presentation order. OAMD has
            // its own LFE-first signal mapping and must not reorder these samples.
            for element in 0..<elementCount {
                result[outputBase + element] = elements[element]
            }
        }
        return result
    }

    private func makeMatrixRenderTargets(at metadataFrame: UInt64) -> [[Int]] {
        let extras = Array(positions(at: metadataFrame).dropFirst(Self.coreChannelCount))
        let corePositions = [
            Self.fixedElementPositions[1], Self.fixedElementPositions[2],
            Self.fixedElementPositions[3], Self.fixedElementPositions[6],
            Self.fixedElementPositions[7], Self.fixedElementPositions[4],
            Self.fixedElementPositions[5]
        ]
        let outputChannels = [0, 1, 2, 6, 7, 4, 5]
        return extras.map { position in
            let ranked = corePositions.indices.sorted {
                Self.horizontalDistanceSquared(position, corePositions[$0])
                    < Self.horizontalDistanceSquared(position, corePositions[$1])
            }
            let nearest = ranked.first ?? 0
            let nearestDistance = Self.horizontalDistanceSquared(position, corePositions[nearest])
            let selected = nearestDistance < 0.05 ? [nearest] : Array(ranked.prefix(2))
            return selected.map { outputChannels[$0] }
        }
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

    private static func horizontalDistanceSquared(_ lhs: ADMPosition, _ rhs: ADMPosition) -> Double {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        return x * x + y * y
    }

    private static func bedAlignedCoreElement(_ item: ADMChannelMetadata) -> Int? {
        guard let first = item.blocks.first?.position,
              item.blocks.allSatisfy({ distanceSquared($0.position, first) < 0.000_001 }) else {
            return nil
        }
        let positions: [(ADMPosition, Int)] = [
            (ADMPosition(x: -1, y: 1, z: 0), 0),
            (ADMPosition(x: 1, y: 1, z: 0), 1),
            (ADMPosition(x: 0, y: 1, z: 0), 2),
            (ADMPosition(x: -1, y: 0, z: 0), 4),
            (ADMPosition(x: 1, y: 0, z: 0), 5),
            (ADMPosition(x: -1, y: -1, z: 0), 6),
            (ADMPosition(x: 1, y: -1, z: 0), 7)
        ]
        return positions.first {
            distanceSquared(first, $0.0) < 0.000_001
        }?.1
    }
}
