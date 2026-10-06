// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Parallel immersive access-unit encoder. Restart intervals are optimized
// independently and committed in source order for deterministic output.

import Foundation

/// Builds the compatibility presentations carried ahead of the immersive
/// extension. Every layer reverses its required folds directly from the
/// shared transport basis, so it does not depend on another layer's matrix.
enum AtmosCompatibilityMatrix {
    static let fractionalBits = 14
    static let scale = Int64(1 << fractionalBits)
    static let centerCoefficient = Int64(11_599)
    static let halfCoefficient = Int64(1 << (fractionalBits - 1))

    // DEE's object-to-7.1 compatibility renderer uses full-scale front
    // speakers, a sqrt(3/4) side plane, and a 2^(-1/4) rear/height plane.
    // Interpolating squared gain between those planes preserves energy while
    // an Object moves through the room instead of snapping it to a fixed Bed
    // speaker for the complete programme.
    private static let sideRenderPower = 0.75
    private static let rearRenderPower = 1 / sqrt(2.0)

    struct Row {
        let speakerChannel: Int
        let outputChannel: Int
        let coefficients: [Int32]
        let coefficientMask: UInt16
    }

    /// Produces Q14 gains for the compatible `L R C LFE Ls Rs Lb Rb`
    /// presentation. The renderer follows the three horizontal rows observed
    /// in DEE reference streams: L-C-R at the front, Ls-Rs through the room,
    /// and Lb-Rb at the rear. Each row and the transition between rows use
    /// equal-power interpolation, retaining continuous left/right and
    /// front/rear position in 8-, 6-, and 2-channel presentations.
    static func renderCoefficients(for input: ADMPosition) -> [Int32] {
        let position = input.clamped()
        let x = position.x
        let y = position.y
        var unit = [Double](repeating: 0, count: 8)

        func equalPowerPair(
            first: Int,
            second: Int,
            fraction: Double
        ) -> [(Int, Double)] {
            let angle = min(1, max(0, fraction)) * .pi / 2
            return [(first, cos(angle)), (second, sin(angle))]
        }

        let front: [(Int, Double)]
        if x < 0 {
            front = equalPowerPair(first: 0, second: 2, fraction: x + 1)
        } else {
            front = equalPowerPair(first: 2, second: 1, fraction: x)
        }
        let side = equalPowerPair(first: 4, second: 5, fraction: (x + 1) / 2)
        let rear = equalPowerPair(first: 6, second: 7, fraction: (x + 1) / 2)

        let firstRow: [(Int, Double)]
        let secondRow: [(Int, Double)]
        let rowFraction: Double
        if y >= 0 {
            firstRow = side
            secondRow = front
            rowFraction = y
        } else {
            firstRow = side
            secondRow = rear
            rowFraction = -y
        }
        let rowAngle = rowFraction * .pi / 2
        let firstWeight = cos(rowAngle)
        let secondWeight = sin(rowAngle)
        for (speaker, gain) in firstRow { unit[speaker] += gain * firstWeight }
        for (speaker, gain) in secondRow { unit[speaker] += gain * secondWeight }

        let horizontalPower: Double
        if y >= 0 {
            horizontalPower = sideRenderPower
                + (1 - sideRenderPower) * y
        } else {
            horizontalPower = sideRenderPower
                + (sideRenderPower - rearRenderPower) * y
        }
        // DEE reaches its height/rear compatibility trim by z=0.5. Keeping the
        // transition continuous avoids a level step for rising Objects.
        let elevationBlend = max(0, 1 - 2 * abs(position.z))
        let renderPower = rearRenderPower
            + (horizontalPower - rearRenderPower) * elevationBlend
        let renderGain = sqrt(renderPower)

        return unit.map {
            Int32(($0 * renderGain * Double(scale)).rounded())
        }
    }

    /// Adds all spatial-element contributions before rounding upward. The
    /// inverse lossless matrix uses the same Q14 sum, so the rounding residual
    /// remains below one output unit and the immersive core is recovered.
    static func foldedContribution(
        spatialElements: ArraySlice<Int64>,
        renderCoefficients: [[Int32]],
        speaker: Int
    ) -> Int64 {
        precondition(spatialElements.count == renderCoefficients.count)
        var accumulator: Int64 = 0
        for (sample, coefficients) in zip(spatialElements, renderCoefficients) {
            precondition(coefficients.count == 8)
            accumulator += sample * Int64(coefficients[speaker])
        }
        return roundedUpAccumulator(accumulator)
    }

    /// Converts standard `L R C LFE Ls Rs Lb Rb` samples to the cumulative
    /// transport basis consumed by the first three substreams.
    static func transportSamples(
        standardSamples: [Int32],
        channelCount: Int
    ) -> [Int32] {
        precondition(channelCount >= 8)
        precondition(standardSamples.count.isMultiple(of: channelCount))
        var result = standardSamples
        for base in stride(from: 0, to: result.count, by: channelCount) {
            let core = standardSamples[base..<(base + 8)].map(Int64.init)
            let transport = transportCore(core)
            for channel in 0..<8 {
                result[base + channel] = Int32(transport[channel])
            }
        }
        return result
    }

    static func transportCore(_ standard: [Int64]) -> [Int64] {
        precondition(standard.count >= 8)
        let leftSurround = standard[4] + standard[6]
        let rightSurround = standard[5] + standard[7]
        let foldedCenter = roundedUpProduct(standard[2], centerCoefficient)
        return [
            standard[0] + foldedCenter + leftSurround,
            standard[1] + foldedCenter + rightSurround,
            leftSurround,
            standard[1],
            standard[2],
            standard[3],
            standard[4],
            standard[5],
        ]
    }

    /// Matrix-channel samples after the six-channel lifting stage.
    static func sixChannelOutput(_ transport: ArraySlice<Int32>) -> [Int32] {
        precondition(transport.count >= 8)
        let values = transport.map(Int64.init)
        return [
            rematrix(values[0] * scale - values[2] * scale
                - values[4] * centerCoefficient),
            rematrix(values[1] * scale - values[3] * scale
                - values[4] * centerCoefficient),
            Int32(values[2]), Int32(values[3]), Int32(values[4]), Int32(values[5]),
        ]
    }

    /// Matrix-channel samples after the eight-channel lifting stage.
    static func eightChannelOutput(_ transport: ArraySlice<Int32>) -> [Int32] {
        precondition(transport.count >= 8)
        let values = transport.map(Int64.init)
        return [
            rematrix(values[0] * scale - values[2] * scale
                - values[4] * centerCoefficient),
            rematrix(values[1] * scale - values[3] * scale
                - values[4] * centerCoefficient - values[7] * scale),
            rematrix(values[2] * scale - values[6] * scale),
            Int32(values[3]), Int32(values[4]), Int32(values[5]),
            Int32(values[6]), Int32(values[7]),
        ]
    }

    /// Returns dependency-ordered rows that recover the discrete core and
    /// remove the compatible object fold from the immersive presentation.
    static func immersiveRows(
        channelCount: Int,
        renderCoefficients: [[Int32]]
    ) -> [Row] {
        precondition(channelCount >= 8 + renderCoefficients.count)
        func makeRow(
            speaker: Int,
            inverseTransportFold: Bool,
            inverseObjectFold: Bool
        ) -> Row {
            let output = matrixChannel(forSpeakerChannel: speaker)
            var coefficients = [Int32](repeating: 0, count: channelCount)
            var coefficientMask: UInt16 = 0
            func set(_ channel: Int, _ coefficient: Int32, alwaysPresent: Bool = false) {
                coefficients[channel] = coefficient
                if coefficient != 0 || alwaysPresent {
                    coefficientMask |= 1 << UInt16(channel)
                }
            }
            switch (speaker, inverseTransportFold) {
            case (0, true):
                set(0, Int32(scale))
                set(2, -Int32(scale))
                set(4, -Int32(centerCoefficient))
            case (7, true):
                set(1, Int32(scale))
                set(3, -Int32(scale))
                set(4, -Int32(centerCoefficient))
                set(7, -Int32(scale))
            case (6, true):
                set(2, Int32(scale))
                set(6, -Int32(scale))
            default:
                set(output, Int32(scale))
            }
            if inverseObjectFold {
                for (cluster, render) in renderCoefficients.enumerated() {
                    // Every spatial coefficient remains in the configuration
                    // mask even while its current value is zero. Ordinary AUs
                    // can then update gains without repeatedly allocating new
                    // matrix configurations in strict decoders.
                    set(8 + cluster, -render[speaker], alwaysPresent: true)
                }
            }
            return Row(
                speakerChannel: speaker,
                outputChannel: output,
                coefficients: coefficients,
                coefficientMask: coefficientMask
            )
        }

        // Derived destinations precede rows that replace any of their source
        // channels. The centre fold and object fold use separate rows so their
        // independent fixed-point rounding is reversed without a one-unit bias.
        return [
            makeRow(speaker: 0, inverseTransportFold: true, inverseObjectFold: false),
            makeRow(speaker: 7, inverseTransportFold: true, inverseObjectFold: false),
            makeRow(speaker: 6, inverseTransportFold: true, inverseObjectFold: true),
            makeRow(speaker: 0, inverseTransportFold: false, inverseObjectFold: true),
            makeRow(speaker: 7, inverseTransportFold: false, inverseObjectFold: true),
            makeRow(speaker: 1, inverseTransportFold: false, inverseObjectFold: true),
            makeRow(speaker: 2, inverseTransportFold: false, inverseObjectFold: true),
            makeRow(speaker: 4, inverseTransportFold: false, inverseObjectFold: true),
            makeRow(speaker: 5, inverseTransportFold: false, inverseObjectFold: true),
        ]
    }

    static func immersiveOutput(
        _ transport: ArraySlice<Int32>,
        renderCoefficients: [[Int32]]
    ) -> [Int32] {
        var values = transport.map(Int64.init)
        for row in immersiveRows(
            channelCount: values.count,
            renderCoefficients: renderCoefficients
        ) {
            let accumulator = zip(values, row.coefficients).reduce(Int64(0)) {
                $0 + $1.0 * Int64($1.1)
            }
            values[row.outputChannel] = Int64(rematrix(accumulator))
        }
        return values.map(Int32.init)
    }

    /// Converts a standard speaker index to the matrix position used by the
    /// eight-channel transport basis.
    static func matrixChannel(forSpeakerChannel channel: Int) -> Int {
        precondition((0..<8).contains(channel))
        return [0, 3, 4, 5, 6, 7, 2, 1][channel]
    }

    private static func roundedUpProduct(_ value: Int64, _ coefficient: Int64) -> Int64 {
        roundedUpAccumulator(value * coefficient)
    }

    private static func roundedUpAccumulator(_ accumulator: Int64) -> Int64 {
        accumulator >= 0
            ? (accumulator + scale - 1) / scale
            : accumulator / scale
    }

    private static func rematrix(_ accumulator: Int64) -> Int32 {
        Int32(accumulator >> Int64(fractionalBits))
    }
}

private struct EncodedAtmosSubstream: Sendable {
    let bytes: [UInt8]
    let huffmanOffsets: [Int32]
    let filterHistories: [[Int32]]
    let activeFIR: [MLPFIRParameters?]
}

private enum AtmosCompatibilityStage {
    case sixChannel
    case eightChannel
}

private struct AtmosEntropyState: Sendable {
    var huffmanOffsets = [[Int32]](
        repeating: [Int32](repeating: 0, count: 16), count: 4
    )
    var filterHistories = [[[Int32]]](
        repeating: [[Int32]](
            repeating: [Int32](repeating: 0, count: MLPPredictiveCoding.historyLength),
            count: 16
        ),
        count: 4
    )
    var activeFIR = [[MLPFIRParameters?]](
        repeating: [MLPFIRParameters?](repeating: nil, count: 16), count: 4
    )
}

private struct PreparedAtmosAccessUnit: Sendable {
    let samples: [Int32]
    let metadataUpdates: [AtmosMetadataUpdate]?
    let metadataSampleOffset: Int
    let actualFrameCount: Int
    let frameIndex: UInt64
    let restartFrame: Bool
    let restartLosslessChecks: [UInt32]
    let restartNoiseGeneratorSeeds: [UInt32]
    let shortenBy: Int
    let matrixRenderCoefficients: [[Int32]]
    let highResolutionTiming: Bool
    let drcUpdates: [Int?]
}

private struct PreparedAtmosSpatialBlock: Sendable {
    let samples: [Int32]
    let actualFrameCount: Int
    let sourceFrame: UInt64
    let matrixRenderCoefficients: [[Int32]]
}

private final class PreparedAtmosSpatialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PreparedAtmosSpatialBlock?]

    init(count: Int) {
        values = [PreparedAtmosSpatialBlock?](repeating: nil, count: count)
    }

    func set(_ value: PreparedAtmosSpatialBlock, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func completedValues() -> [PreparedAtmosSpatialBlock] {
        lock.lock()
        defer { lock.unlock() }
        return values.map {
            precondition($0 != nil)
            return $0!
        }
    }
}

private final class EncodedAtmosIntervalStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[[UInt8]]?]

    init(count: Int) {
        values = [[[UInt8]]?](repeating: nil, count: count)
    }

    func set(_ value: [[UInt8]], at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func completedValues() -> [[[UInt8]]] {
        lock.lock()
        defer { lock.unlock() }
        return values.map {
            precondition($0 != nil)
            return $0!
        }
    }
}

private final class EncodedAtmosSubstreamStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [EncodedAtmosSubstream?](repeating: nil, count: 4)

    func set(_ value: EncodedAtmosSubstream, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func completedValues() -> [EncodedAtmosSubstream] {
        lock.lock()
        defer { lock.unlock() }
        return values.map {
            precondition($0 != nil)
            return $0!
        }
    }
}

final class AtmosBitstreamEncoder: @unchecked Sendable {
    private static let samplesPerAccessUnit = 40

    private let restartInterval: Int
    private let peakBitRate: Int
    private let elementBitDepth: Int
    private let maximumInputFrames: UInt64
    private let spatialClusterCount: Int
    private let firstFrameOfAction: String
    private let outputFrameRate: TrueHDOutputFrameRate
    private let drcProfile: TrueHDDRCProfile

    private var decodedOutputShift: Int { 24 - elementBitDepth }
    private var encodedChannelCount: Int { spatialClusterCount }
    private var oamdSignalPositionIndices: [Int] {
        Self.oamdPositionOrder(elementCount: spatialClusterCount)
    }

    init(configuration: TrueHDEncoderConfiguration, elementBitDepth: Int = 20) throws {
        guard AtmosSpatialCoder.supportedElementCounts.contains(configuration.spatialClusterCount) else {
            throw TrueHDError.invalidConfiguration("Spatial clusters must be 12, 14, or 16")
        }
        guard TrueHDCompliancePolicy.atmosElementBitDepths.contains(elementBitDepth) else {
            throw TrueHDError.invalidConfiguration("Atmos element bit depth is outside the compliance policy")
        }
        restartInterval = TrueHDCompliancePolicy.atmosRestartInterval
        peakBitRate = TrueHDCompliancePolicy.peakBitRate
        self.elementBitDepth = elementBitDepth
        maximumInputFrames = 0
        spatialClusterCount = configuration.spatialClusterCount
        firstFrameOfAction = configuration.firstFrameOfAction
        outputFrameRate = configuration.frameRate
        drcProfile = configuration.drcProfile
    }

    func encode(
        reader: TrueHDAudioReader,
        outputURL: URL,
        overwrite: Bool,
        progress: (@Sendable (TrueHDEncodingProgress) -> Void)?
    ) throws -> TrueHDEncodingResult {
        guard reader.format.sampleRate == 48_000 else {
            throw TrueHDError.unsupportedInput("Native TrueHD Atmos encoding currently supports 48 kHz ADM")
        }
        let metadata: ADMMetadata
        if let nativeMetadata = reader.admMetadata {
            metadata = nativeMetadata
        } else {
            guard let xml = reader.admXML, let channelAssignment = reader.admChannelAssignment else {
                throw TrueHDError.unsupportedInput("Atmos input must contain ADM metadata")
            }
            metadata = try ADMMetadata.parse(
                xml: xml,
                channelAssignment: channelAssignment,
                channelCount: reader.format.channelCount,
                sampleRate: reader.format.sampleRate
            )
        }
        let sourceTiming = try TrueHDSourceTiming.resolve(
            frameRate: outputFrameRate.resolve(input: reader.sourceFrameRate),
            firstFrameOfAction: firstFrameOfAction,
            availableFrames: reader.frameCount
        )
        let spatialCoder = try AtmosSpatialCoder(
            metadata: metadata,
            sourceChannelCount: reader.format.channelCount,
            elementBitDepth: elementBitDepth,
            spatialClusterCount: spatialClusterCount
        )

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            guard overwrite else { throw TrueHDError.outputExists(outputURL) }
            try fileManager.removeItem(at: outputURL)
        }
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: outputURL)
        var outputIsOpen = true
        var completed = false
        defer {
            if outputIsOpen { try? output.close() }
            if !completed { try? fileManager.removeItem(at: outputURL) }
        }

        let availableInputFrames = reader.frameCount - sourceTiming.inputStartFrame
        let inputFrameCount = maximumInputFrames == 0
            ? availableInputFrames
            : min(availableInputFrames, maximumInputFrames)
        let elementCache = try spatialCoder.prepareElementCache(
            reader: reader,
            startFrame: sourceTiming.inputStartFrame,
            frameCount: inputFrameCount
        )
        let spatialAccuracy = spatialCoder.spatialAccuracyReport()
        let cachedElements = try FileHandle(forReadingFrom: elementCache.url)
        defer {
            try? cachedElements.close()
            try? FileManager.default.removeItem(at: elementCache.url)
        }
        let inputEndFrame = sourceTiming.inputStartFrame + inputFrameCount
        let totalAccessUnits = (inputFrameCount + UInt64(Self.samplesPerAccessUnit - 1))
            / UInt64(Self.samplesPerAccessUnit)
        var outputBuffer = Data()
        outputBuffer.reserveCapacity(1_048_576)
        var bytesWritten: UInt64 = 0
        var accessUnitRecords = [MLPAccessUnitRecord]()
        accessUnitRecords.reserveCapacity(Int(totalAccessUnits))
        var frameIndex: UInt64 = 0
        var sourceFrame: UInt64 = sourceTiming.inputStartFrame
        var intervalLosslessChecks = [UInt32](repeating: 0, count: 4)
        var noiseGeneratorSeeds: [UInt32] = [1, 2, 3, 4]
        var highResolutionTimingWriter = HighResolutionTimingWriter()
        var nextMetadataSample: UInt64 = sourceTiming.inputStartFrame
        var compatibilityDRC = TrueHDDynamicRangeControl(
            profile: drcProfile,
            channelCount: encodedChannelCount,
            presentationMaximumChannels: [1, 5, 7],
            decodedOutputShift: decodedOutputShift
        )

        let parallelIntervalCount = max(
            1, min(16, ProcessInfo.processInfo.activeProcessorCount)
        )
        let batchAccessUnitCapacity = restartInterval * parallelIntervalCount

        while frameIndex < totalAccessUnits {
            try Task.checkCancellation()
            let remainingFrames = inputEndFrame - sourceFrame
            let requestedFrames = Int(
                min(
                    UInt64(batchAccessUnitCapacity * Self.samplesPerAccessUnit),
                    remainingFrames
                )
            )
            let cachedByteCount = requestedFrames * encodedChannelCount
                * MemoryLayout<Int64>.stride
            guard let cachedData = try cachedElements.read(upToCount: cachedByteCount),
                  cachedData.count == cachedByteCount else {
                throw TrueHDError.invalidConfiguration(
                    "Prepared Atmos element cache ended before the selected input range"
                )
            }
            let unscaledElements = cachedData.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Int64.self))
            }
            let batchStartFrame = sourceFrame
            let batchGainOffset = Int(batchStartFrame - sourceTiming.inputStartFrame)
            let spatialBlockCount = (requestedFrames + Self.samplesPerAccessUnit - 1)
                / Self.samplesPerAccessUnit
            let spatialStore = PreparedAtmosSpatialStore(count: spatialBlockCount)
            let spatialWorkerCount = min(
                max(1, ProcessInfo.processInfo.activeProcessorCount), spatialBlockCount
            )
            DispatchQueue.concurrentPerform(iterations: spatialWorkerCount) { worker in
                for blockIndex in stride(
                    from: worker, to: spatialBlockCount, by: spatialWorkerCount
                ) {
                    let frameOffset = blockIndex * Self.samplesPerAccessUnit
                    let blockFrameCount = min(
                        Self.samplesPerAccessUnit, requestedFrames - frameOffset
                    )
                    let sampleStart = frameOffset * encodedChannelCount
                    let sampleEnd = (frameOffset + blockFrameCount) * encodedChannelCount
                    let gainStart = batchGainOffset + frameOffset
                    let gainEnd = gainStart + blockFrameCount
                    let blockSourceFrame = batchStartFrame + UInt64(frameOffset)
                    let standardSamples = spatialCoder.quantize(
                        unscaledSamples: Array(unscaledElements[sampleStart..<sampleEnd]),
                        limiterGains: elementCache.limiterGains[gainStart..<gainEnd]
                    )
                    let quantizedSamples = AtmosCompatibilityMatrix.transportSamples(
                        standardSamples: standardSamples,
                        channelCount: encodedChannelCount
                    )
                    let renderCoefficients = spatialCoder.matrixRenderCoefficients(
                        at: blockSourceFrame + UInt64(blockFrameCount / 2)
                    )
                    var samples = quantizedSamples
                    samples.append(
                        contentsOf: repeatElement(
                            0,
                            count: (Self.samplesPerAccessUnit - blockFrameCount)
                                * encodedChannelCount
                        )
                    )
                    spatialStore.set(
                        PreparedAtmosSpatialBlock(
                            samples: samples,
                            actualFrameCount: blockFrameCount,
                            sourceFrame: blockSourceFrame,
                            matrixRenderCoefficients: renderCoefficients
                        ),
                        at: blockIndex
                    )
                }
            }

            var prepared = [PreparedAtmosAccessUnit]()
            prepared.reserveCapacity(spatialBlockCount)
            for spatialBlock in spatialStore.completedValues() {
                let restartFrame = frameIndex % UInt64(restartInterval) == 0
                let highResolutionTiming = restartFrame
                    ? highResolutionTimingWriter.nextBit(
                        outputSample: frameIndex * UInt64(Self.samplesPerAccessUnit)
                    )
                    : false
                let restartChecks: [UInt32]
                let restartNoiseGeneratorSeeds: [UInt32]
                if restartFrame {
                    restartChecks = intervalLosslessChecks
                    intervalLosslessChecks = [UInt32](repeating: 0, count: 4)
                    restartNoiseGeneratorSeeds = noiseGeneratorSeeds
                    noiseGeneratorSeeds[0] = Self.advancingNoiseGeneratorSeed(
                        noiseGeneratorSeeds[0], iterations: restartInterval * 120,
                        leftShift: 16
                    )
                    for index in 1...2 {
                        noiseGeneratorSeeds[index] = Self.advancingNoiseGeneratorSeed(
                            noiseGeneratorSeeds[index], iterations: restartInterval * 64,
                            leftShift: 16
                        )
                    }
                    noiseGeneratorSeeds[3] = Self.advancingNoiseGeneratorSeed(
                        noiseGeneratorSeeds[3], iterations: restartInterval * 64,
                        leftShift: 8
                    )
                } else {
                    restartChecks = [UInt32](repeating: 0, count: 4)
                    restartNoiseGeneratorSeeds = [UInt32](repeating: 0, count: 4)
                }

                let metadataEndFrame = spatialBlock.sourceFrame
                    + UInt64(spatialBlock.actualFrameCount)
                let metadataUpdates: [AtmosMetadataUpdate]?
                let metadataSampleOffset: Int
                if nextMetadataSample < metadataEndFrame {
                    metadataUpdates = try spatialCoder.metadataUpdates(
                        frameStart: nextMetadataSample,
                        programmeStart: sourceTiming.inputStartFrame,
                        programmeEnd: inputEndFrame
                    )
                    metadataSampleOffset = Int(nextMetadataSample - spatialBlock.sourceFrame)
                    nextMetadataSample += 1_536
                } else {
                    metadataUpdates = nil
                    metadataSampleOffset = 0
                }

                let compatibilityUpdates = compatibilityDRC.updates(
                    samples: spatialBlock.samples,
                    frameCount: spatialBlock.actualFrameCount,
                    accessUnit: frameIndex,
                    forceUpdate: frameIndex + 1 == totalAccessUnits
                )
                prepared.append(
                    PreparedAtmosAccessUnit(
                        samples: spatialBlock.samples,
                        metadataUpdates: metadataUpdates,
                        metadataSampleOffset: metadataSampleOffset,
                        actualFrameCount: spatialBlock.actualFrameCount,
                        frameIndex: frameIndex,
                        restartFrame: restartFrame,
                        restartLosslessChecks: restartChecks,
                        restartNoiseGeneratorSeeds: restartNoiseGeneratorSeeds,
                        shortenBy: Self.samplesPerAccessUnit - spatialBlock.actualFrameCount,
                        matrixRenderCoefficients: spatialBlock.matrixRenderCoefficients,
                        highResolutionTiming: highResolutionTiming,
                        // The immersive presentation uses the 7.1 compatibility
                        // render as its broadband DRC sidechain. Object signals
                        // are already folded into that render by the spatial coder.
                        drcUpdates: compatibilityUpdates + [compatibilityUpdates[2]]
                    )
                )
                updateLosslessChecks(
                    &intervalLosslessChecks,
                    samples: spatialBlock.samples,
                    frameCount: spatialBlock.actualFrameCount,
                    matrixRenderCoefficients: spatialBlock.matrixRenderCoefficients
                )
                sourceFrame = spatialBlock.sourceFrame + UInt64(spatialBlock.actualFrameCount)
                frameIndex += 1
            }
            guard !prepared.isEmpty else { break }

            let batch = prepared
            let intervalCount = (batch.count + restartInterval - 1) / restartInterval
            let predictionConfigurations = [
                (maximumOrder: 2, enableLPC: false),
                (maximumOrder: 4, enableLPC: false),
                (maximumOrder: 8, enableLPC: true),
            ]
            let variantCount = predictionConfigurations.count
            let intervalStore = EncodedAtmosIntervalStore(count: intervalCount * variantCount)
            DispatchQueue.concurrentPerform(iterations: intervalCount * variantCount) { work in
                let interval = work / variantCount
                let prediction = predictionConfigurations[work % variantCount]
                let start = interval * restartInterval
                let end = min(batch.count, start + restartInterval)
                var entropyState = AtmosEntropyState()
                var encoded = [[UInt8]]()
                encoded.reserveCapacity(end - start)
                for item in batch[start..<end] {
                    encoded.append(
                        self.makeAccessUnit(
                            samples: item.samples,
                            metadataUpdates: item.metadataUpdates,
                            metadataSampleOffset: item.metadataSampleOffset,
                            actualFrameCount: item.actualFrameCount,
                            frameIndex: item.frameIndex,
                            restartFrame: item.restartFrame,
                            restartLosslessChecks: item.restartLosslessChecks,
                            restartNoiseGeneratorSeeds: item.restartNoiseGeneratorSeeds,
                            shortenBy: item.shortenBy,
                            matrixRenderCoefficients: item.matrixRenderCoefficients,
                            highResolutionTiming: item.highResolutionTiming,
                            drcUpdates: item.drcUpdates,
                            entropyState: &entropyState,
                            maximumPredictionOrder: prediction.maximumOrder,
                            enableLPC: prediction.enableLPC
                        )
                    )
                }
                intervalStore.set(encoded, at: work)
            }

            let variants = intervalStore.completedValues()
            var accessUnits = [[UInt8]]()
            accessUnits.reserveCapacity(batch.count)
            for interval in 0..<intervalCount {
                let candidates = variants[
                    (interval * variantCount)..<((interval + 1) * variantCount)
                ]
                let best = candidates.min { lhs, rhs in
                    lhs.reduce(0) { $0 + $1.count }
                        < rhs.reduce(0) { $0 + $1.count }
                }
                accessUnits.append(contentsOf: best!)
            }
            precondition(accessUnits.count == batch.count)
            for (item, accessUnit) in zip(batch, accessUnits) {
                let instantaneousRate = accessUnit.count * 8 * reader.format.sampleRate
                    / Self.samplesPerAccessUnit
                guard instantaneousRate <= peakBitRate else {
                    throw TrueHDError.peakBitRateExceeded(
                        required: instantaneousRate, limit: peakBitRate
                    )
                }
                accessUnitRecords.append(
                    MLPAccessUnitRecord(
                        offset: bytesWritten,
                        byteCount: accessUnit.count
                    )
                )
                outputBuffer.append(contentsOf: accessUnit)
                bytesWritten += UInt64(accessUnit.count)

                if outputBuffer.count >= 1_048_576 {
                    try output.write(contentsOf: outputBuffer)
                    outputBuffer.removeAll(keepingCapacity: true)
                }
                let completedFrames = item.frameIndex + 1
                if completedFrames == totalAccessUnits || completedFrames % 256 == 0 {
                    progress?(
                        TrueHDEncodingProgress(
                            completedFrames: completedFrames,
                            totalFrames: totalAccessUnits,
                            encodedBytes: bytesWritten
                        )
                    )
                }
            }
        }

        if !outputBuffer.isEmpty { try output.write(contentsOf: outputBuffer) }
        try output.synchronize()
        try output.close()
        outputIsOpen = false
        let transportPlan = try MLPTransportTiming.makePlan(
            byteCounts: accessUnitRecords.map(\.byteCount)
        )
        try MLPTransportRewriter.rewrite(
            outputURL: outputURL,
            records: accessUnitRecords,
            plan: transportPlan,
            majorSync: makeMajorSync(
                declaredCodedPeakRate: transportPlan.codedPeakRate
            ),
            substreamCount: 4,
            authenticateEvolution: true
        )
        completed = true
        return TrueHDEncodingResult(
            outputURL: outputURL,
            profile: .atmos,
            sampleRate: reader.format.sampleRate,
            channelCount: encodedChannelCount,
            inputFrameCount: inputFrameCount,
            outputByteCount: bytesWritten,
            sourceFrameRate: reader.sourceFrameRate,
            outputFrameRate: sourceTiming.frameRate,
            firstFrameOfAction: sourceTiming.firstFrameOfAction,
            spatialClusterCount: spatialClusterCount,
            elementBitDepth: elementBitDepth,
            drcProfile: drcProfile,
            spatialAccuracy: spatialAccuracy
        )
    }

    private func makeAccessUnit(
        samples: [Int32],
        metadataUpdates: [AtmosMetadataUpdate]?,
        metadataSampleOffset: Int,
        actualFrameCount: Int,
        frameIndex: UInt64,
        restartFrame: Bool,
        restartLosslessChecks: [UInt32],
        restartNoiseGeneratorSeeds: [UInt32],
        shortenBy: Int,
        matrixRenderCoefficients: [[Int32]],
        highResolutionTiming: Bool,
        drcUpdates: [Int?],
        entropyState: inout AtmosEntropyState,
        maximumPredictionOrder: Int,
        enableLPC: Bool
    ) -> [UInt8] {
        let outputTiming = UInt16(truncatingIfNeeded: frameIndex * UInt64(Self.samplesPerAccessUnit))
        let inputTiming = outputTiming &- UInt16(Self.samplesPerAccessUnit)
        let frameInInterval = Int(frameIndex % UInt64(restartInterval))
        let initialOffsets = entropyState.huffmanOffsets
        let initialFilterHistories = entropyState.filterHistories
        let initialActiveFIR = entropyState.activeFIR
        let resultStore = EncodedAtmosSubstreamStore()
        for index in 0..<4 {
            var offsets = initialOffsets[index]
            var filterHistories = initialFilterHistories[index]
            var activeFIR = initialActiveFIR[index]
            let bytes: [UInt8]
            switch index {
            case 0:
                bytes = makeSubstream(
                    samples: samples, minimumChannel: 0, maximumChannel: 1,
                    maximumMatrixChannel: 1, restartType: 0x31EA,
                    channelAssignments: Array(0...1), timing: outputTiming,
                    frameInInterval: frameInInterval, restartFrame: restartFrame,
                    losslessCheck: restartLosslessChecks[0],
                    noiseGeneratorSeed: restartNoiseGeneratorSeeds[0], shortenBy: shortenBy,
                    compatibilityStage: nil, matrixRenderCoefficients: nil,
                    highResolutionTiming: highResolutionTiming,
                    huffmanOffsets: &offsets, filterHistories: &filterHistories,
                    activeFIR: &activeFIR,
                    maximumPredictionOrder: maximumPredictionOrder,
                    enableLPC: enableLPC
                )
            case 1:
                bytes = makeSubstream(
                    samples: samples, minimumChannel: 2, maximumChannel: 5,
                    maximumMatrixChannel: 5, restartType: 0x31EB,
                    channelAssignments: [0, 5, 4, 1, 2, 3], timing: outputTiming,
                    frameInInterval: frameInInterval, restartFrame: restartFrame,
                    losslessCheck: restartLosslessChecks[1],
                    noiseGeneratorSeed: restartNoiseGeneratorSeeds[1], shortenBy: shortenBy,
                    compatibilityStage: .sixChannel, matrixRenderCoefficients: nil,
                    highResolutionTiming: highResolutionTiming,
                    huffmanOffsets: &offsets, filterHistories: &filterHistories,
                    activeFIR: &activeFIR,
                    maximumPredictionOrder: maximumPredictionOrder,
                    enableLPC: enableLPC
                )
            case 2:
                bytes = makeSubstream(
                    samples: samples, minimumChannel: 6, maximumChannel: 7,
                    maximumMatrixChannel: 7, restartType: 0x31EB,
                    channelAssignments: [0, 7, 6, 1, 2, 3, 4, 5], timing: outputTiming,
                    frameInInterval: frameInInterval, restartFrame: restartFrame,
                    losslessCheck: restartLosslessChecks[2],
                    noiseGeneratorSeed: restartNoiseGeneratorSeeds[2], shortenBy: shortenBy,
                    compatibilityStage: .eightChannel, matrixRenderCoefficients: nil,
                    highResolutionTiming: highResolutionTiming,
                    huffmanOffsets: &offsets, filterHistories: &filterHistories,
                    activeFIR: &activeFIR,
                    maximumPredictionOrder: maximumPredictionOrder,
                    enableLPC: enableLPC
                )
            default:
                bytes = makeSubstream(
                    samples: samples, minimumChannel: 8,
                    maximumChannel: encodedChannelCount - 1,
                    maximumMatrixChannel: encodedChannelCount - 1,
                    restartType: 0x31EC,
                    channelAssignments: Self.canonical16ChannelAssignments.filter {
                        $0 < encodedChannelCount
                    },
                    timing: outputTiming, frameInInterval: frameInInterval,
                    restartFrame: restartFrame, losslessCheck: restartLosslessChecks[3],
                    noiseGeneratorSeed: restartNoiseGeneratorSeeds[3],
                    shortenBy: shortenBy, compatibilityStage: nil,
                    matrixRenderCoefficients: matrixRenderCoefficients,
                    highResolutionTiming: highResolutionTiming,
                    huffmanOffsets: &offsets, filterHistories: &filterHistories,
                    activeFIR: &activeFIR,
                    maximumPredictionOrder: maximumPredictionOrder,
                    enableLPC: enableLPC
                )
            }
            resultStore.set(
                EncodedAtmosSubstream(
                    bytes: bytes, huffmanOffsets: offsets,
                    filterHistories: filterHistories, activeFIR: activeFIR
                ), at: index
            )
        }
        let encodedSubstreams = resultStore.completedValues()
        entropyState.huffmanOffsets = encodedSubstreams.map(\.huffmanOffsets)
        entropyState.filterHistories = encodedSubstreams.map(\.filterHistories)
        entropyState.activeFIR = encodedSubstreams.map(\.activeFIR)
        let substreams = encodedSubstreams.map(\.bytes)

        let pendingExtraData = metadataUpdates.map { updates in
            AtmosMetadataWriter.prepareExtraData(
                updates: updates.map { update in
                    AtmosMetadataUpdate(
                        blockOffsetFactor: update.blockOffsetFactor,
                        rampDuration: update.rampDuration,
                        positions: oamdSignalPositionIndices.map { update.positions[$0] }
                    )
                },
                sampleOffset: metadataSampleOffset
            )
        }

        var body = [UInt8]()
        if restartFrame { body.append(contentsOf: makeMajorSync()) }
        let directoryOffset = body.count
        precondition(drcUpdates.count == substreams.count)
        let directoryEntrySizes = drcUpdates.map { $0 == nil ? 2 : 4 }
        let directoryByteCount = directoryEntrySizes.reduce(0, +)
        body.append(contentsOf: repeatElement(0, count: directoryByteCount))
        for substream in substreams { body.append(contentsOf: substream) }
        let extraDataOffset = body.count
        if let pendingExtraData {
            body.append(contentsOf: repeatElement(0, count: pendingExtraData.byteCount))
        }

        let totalByteCount = 4 + body.count
        precondition(totalByteCount & 1 == 0)
        let lengthInWords = totalByteCount / 2
        precondition(lengthInWords <= 0x0FFF)

        var cumulativeByteCount = 0
        let commonFlags: UInt16 = (restartFrame ? 0 : 1 << 14)
            | (1 << 13)
        var entryOffset = directoryOffset
        for (index, substream) in substreams.enumerated() {
            cumulativeByteCount += substream.count
            let reserved = index == 0 ? UInt16(1 << 12) : 0
            let extraWordFlag: UInt16 = drcUpdates[index] == nil ? 0 : 1 << 15
            let entry = extraWordFlag | commonFlags | reserved
                | UInt16((cumulativeByteCount / 2) & 0x0FFF)
            writeUInt16BE(entry, into: &body, at: entryOffset)
            if let gainCode = drcUpdates[index] {
                writeUInt16BE(
                    TrueHDDynamicRangeControl.extraWord(gainCode: gainCode),
                    into: &body,
                    at: entryOffset + 2
                )
            }
            entryOffset += directoryEntrySizes[index]
        }

        var parity = inputTiming ^ UInt16(lengthInWords)
        for byte in body[directoryOffset..<(directoryOffset + directoryByteCount)] {
            parity ^= UInt16(byte)
        }
        parity ^= parity >> 8
        parity ^= parity >> 4
        parity &= 0x0F

        let accessHeader = ((parity ^ 0x0F) << 12) | UInt16(lengthInWords)
        let headerBytes = [
            UInt8(accessHeader >> 8), UInt8(truncatingIfNeeded: accessHeader),
            UInt8(inputTiming >> 8), UInt8(truncatingIfNeeded: inputTiming)
        ]

        if let pendingExtraData {
            let prefix = headerBytes + body[..<extraDataOffset]
            let extraData = pendingExtraData.finalize(accessUnitPrefix: Array(prefix))
            precondition(extraData.count == body.count - extraDataOffset)
            body.replaceSubrange(extraDataOffset..., with: extraData)
        }
        return headerBytes + body
    }

    private func makeMajorSync(declaredCodedPeakRate: Int? = nil) -> [UInt8] {
        var writer = BitWriter(reservingCapacity: 32)
        writer.write(0xF8726FBA, count: 32)
        writer.write(0, count: 4) // 48 kHz
        writer.write(0, count: 1)
        writer.write(0, count: 1)
        writer.write(0, count: 2)
        writer.write(0, count: 2)
        writer.write(1, count: 2)
        writer.write(0x0F, count: 5)
        writer.write(0, count: 2)
        writer.write(0x04F, count: 13)
        writer.write(0xB752, count: 16)
        writer.write(0x1000, count: 16) // Evolution metadata is present
        writer.write(0, count: 16)
        writer.write(1, count: 1)
        let codedPeak = declaredCodedPeakRate ?? Self.codedPeakRate(peakBitRate)
        writer.write(UInt64(codedPeak), count: 15)
        writer.write(4, count: 4)
        writer.write(3, count: 4)
        writer.write(0xFC, count: 8)

        writer.write(0, count: 6) // heavy DRC start-up gain
        writer.write(8, count: 4) // stereo DRC control enabled by default
        writer.write(0, count: 7) // DRC start-up gain
        writer.write(30, count: 6)
        writer.write(29, count: 6)
        writer.write(24, count: 5)
        writer.write(35, count: 6)
        writer.write(0, count: 5)
        writer.write(24, count: 5)
        writer.write(35, count: 6)
        writer.write(0, count: 6)
        writer.write(0, count: 1)
        writer.write(1, count: 1) // extra channel meaning follows

        writer.write(1, count: 4) // 32 bits including this length field
        writer.write(24, count: 5)
        writer.write(35, count: 6)
        writer.write(UInt64(encodedChannelCount - 1), count: 5)
        writer.write(1, count: 1) // dynamic objects only
        writer.write(1, count: 1) // LFE bed is present
        writer.write(0, count: 10)
        writer.flush()
        precondition(writer.bytes.count == 30)

        var bytes = writer.bytes
        let checksum = MLPChecksums.checksum16(bytes)
        bytes.append(UInt8(truncatingIfNeeded: checksum))
        bytes.append(UInt8(checksum >> 8))
        return bytes
    }

    /// Canonical FBA matrix-output order used by 16-channel streams.
    /// Filtering the permutation preserves valid 12- and 14-channel subsets.
    private static let canonical16ChannelAssignments = [
        2, 10, 7, 8, 3, 0, 4, 5, 9, 11, 12, 13, 14, 15, 6, 1
    ]

    /// OAMD object-metadata blocks address decoded output channels in
    /// ascending order, while the spatial coder lists positions in its matrix
    /// layout (LFE, L, R, C, Lb, Rb, Ls, Rs, then clusters). Decoded outputs
    /// receive matrix channels through the canonical ch_assign permutation,
    /// so each output channel's declared position must be looked up through
    /// that permutation. Writing the matrix-ordered list directly attaches
    /// every position to the wrong signal and scrambles the object render.
    static func oamdPositionOrder(elementCount: Int) -> [Int] {
        precondition(AtmosSpatialCoder.supportedElementCounts.contains(elementCount))
        // Matrix channels 0...7 recover L, Rb, Lb, R, C, LFE, Ls, Rs, which
        // sit at these indices of the spatial coder's position list.
        let matrixPositionIndex = [1, 5, 4, 2, 3, 0, 6, 7]
        let assignments = canonical16ChannelAssignments.filter { $0 < elementCount }
        var order = [Int](repeating: 0, count: elementCount)
        for (matrixChannel, outputChannel) in assignments.enumerated() {
            order[outputChannel] = matrixChannel < matrixPositionIndex.count
                ? matrixPositionIndex[matrixChannel]
                : matrixChannel
        }
        precondition(order[0] == 0, "The LFE bed element must remain the first OAMD signal")
        return order
    }

    /// TrueHD stores peak data rate in 3 kbps units at 48 kHz. The value is a
    /// ceiling: rounding down can declare a rate lower than an emitted AU.
    static func codedPeakRate(_ bitRate: Int) -> Int {
        max(1, (bitRate + 2_999) / 3_000)
    }

    /// Advances the decoder's normative MLP noise-generator state. The
    /// temporary in each recurrence has the same width as FFmpeg's reference
    /// decoder (`uint16_t` for the two-channel path, `uint8_t` for FBA).
    static func advancingNoiseGeneratorSeed(
        _ initialSeed: UInt32,
        iterations: Int,
        leftShift: Int
    ) -> UInt32 {
        precondition(leftShift == 8 || leftShift == 16)
        var seed = initialSeed
        if leftShift == 16 {
            for _ in 0..<iterations {
                let shifted = UInt32(UInt16(truncatingIfNeeded: seed >> 7))
                seed = (seed << 16) ^ shifted ^ (shifted << 5)
            }
        } else {
            for _ in 0..<iterations {
                let shifted = UInt32(UInt8(truncatingIfNeeded: seed >> 15))
                seed = (seed << 8) ^ shifted ^ (shifted << 5)
            }
        }
        return seed
    }

    private func makeSubstream(
        samples: [Int32],
        minimumChannel: Int,
        maximumChannel: Int,
        maximumMatrixChannel: Int,
        restartType: Int,
        channelAssignments: [Int],
        timing: UInt16,
        frameInInterval: Int,
        restartFrame: Bool,
        losslessCheck: UInt32,
        noiseGeneratorSeed: UInt32,
        shortenBy: Int,
        compatibilityStage: AtmosCompatibilityStage?,
        matrixRenderCoefficients: [[Int32]]?,
        highResolutionTiming: Bool,
        huffmanOffsets: inout [Int32],
        filterHistories: inout [[Int32]],
        activeFIR: inout [MLPFIRParameters?],
        maximumPredictionOrder: Int,
        enableLPC: Bool
    ) -> [UInt8] {
        var writer = BitWriter(reservingCapacity: 1024)
        if restartFrame {
            for channel in minimumChannel...maximumChannel {
                huffmanOffsets[channel] = 0
                activeFIR[channel] = nil
            }
            writer.write(1, count: 1)
            writer.write(1, count: 1)
            writeRestartHeader(
                to: &writer, minimumChannel: minimumChannel, maximumChannel: maximumChannel,
                maximumMatrixChannel: maximumMatrixChannel, restartType: restartType,
                channelAssignments: channelAssignments, timing: timing,
                losslessCheck: losslessCheck,
                noiseGeneratorSeed: noiseGeneratorSeed,
                highResolutionTiming: highResolutionTiming
            )
            writeBlock(
                to: &writer, samples: samples, frameRange: 0..<8,
                minimumChannel: minimumChannel, maximumChannel: maximumChannel,
                compatibilityStage: compatibilityStage,
                matrixRenderCoefficients: matrixRenderCoefficients,
                matrixHasNewConfiguration: matrixRenderCoefficients != nil,
                outputShift: decodedOutputShift,
                huffmanOffsets: &huffmanOffsets,
                filterHistories: &filterHistories, activeFIR: &activeFIR,
                allowPrediction: false,
                maximumPredictionOrder: maximumPredictionOrder,
                enableLPC: enableLPC
            )
            writer.write(0, count: 1)
            writer.write(1, count: 1)
            writer.write(0, count: 1)
            writeBlock(
                to: &writer, samples: samples, frameRange: 8..<40,
                minimumChannel: minimumChannel, maximumChannel: maximumChannel,
                compatibilityStage: nil,
                matrixRenderCoefficients: nil,
                huffmanOffsets: &huffmanOffsets,
                filterHistories: &filterHistories, activeFIR: &activeFIR,
                allowPrediction: true,
                maximumPredictionOrder: maximumPredictionOrder,
                enableLPC: enableLPC
            )
            writer.write(1, count: 1)
        } else {
            writer.write(1, count: 1)
            writer.write(0, count: 1)
            writeBlock(
                to: &writer, samples: samples, frameRange: 0..<40,
                minimumChannel: minimumChannel, maximumChannel: maximumChannel,
                compatibilityStage: nil,
                // Reuse the persistent row/mask configuration while replacing
                // only its coefficients. This is the FBA path intended for a
                // time-varying Object downmix and does not consume another
                // strict-decoder configuration slot on every access unit.
                matrixRenderCoefficients: matrixRenderCoefficients,
                matrixHasNewConfiguration: false,
                huffmanOffsets: &huffmanOffsets,
                filterHistories: &filterHistories, activeFIR: &activeFIR,
                allowPrediction: true,
                maximumPredictionOrder: maximumPredictionOrder,
                enableLPC: enableLPC
            )
            writer.write(1, count: 1)
        }

        writer.align(toMultipleOf: 16)
        if shortenBy > 0 {
            writer.write(0xD234, count: 16)
            writer.write(UInt64(0xE000 | (shortenBy & 0x1FFF)), count: 16)
        }
        writer.flush()
        var bytes = writer.bytes
        let parity = MLPChecksums.parity(bytes) ^ 0xA9
        let checksum = MLPChecksums.checksum8(bytes)
        bytes.append(parity)
        bytes.append(checksum)
        return bytes
    }

    private func writeRestartHeader(
        to writer: inout BitWriter,
        minimumChannel: Int,
        maximumChannel: Int,
        maximumMatrixChannel: Int,
        restartType: Int,
        channelAssignments: [Int],
        timing: UInt16,
        losslessCheck: UInt32,
        noiseGeneratorSeed: UInt32,
        highResolutionTiming: Bool
    ) {
        let startBitCount = writer.bitCount
        writer.write(UInt64(restartType), count: 14)
        writer.write(UInt64(timing), count: 16)
        writer.write(UInt64(minimumChannel), count: 4)
        writer.write(UInt64(maximumChannel), count: 4)
        writer.write(UInt64(maximumMatrixChannel), count: 4)
        writer.write(0, count: 4)
        writer.write(UInt64(noiseGeneratorSeed & 0x007F_FFFF), count: 23)
        writer.write(UInt64(decodedOutputShift), count: 4)
        writer.write(restartType == 0x31EC ? 31 : 24, count: 5)
        writer.write(24, count: 5)
        writer.write(24, count: 5)
        writer.write(0, count: 1)
        writer.write(UInt64(xorBytes(losslessCheck)), count: 8)
        writer.write(highResolutionTiming ? 1 : 0, count: 1)
        writer.write(0, count: 15)
        for channel in 0...maximumMatrixChannel {
            writer.write(UInt64(channelAssignments[channel]), count: 6)
        }
        let restartBitCount = writer.bitCount - startBitCount
        let checksum = MLPChecksums.restartChecksum(
            bytes: Array(writer.paddedBytes().dropFirst(startBitCount / 8)),
            bitCount: restartBitCount
        )
        writer.write(UInt64(checksum), count: 8)
    }

    private func writeBlock(
        to writer: inout BitWriter,
        samples: [Int32],
        frameRange: Range<Int>,
        minimumChannel: Int,
        maximumChannel: Int,
        compatibilityStage: AtmosCompatibilityStage?,
        matrixRenderCoefficients: [[Int32]]?,
        matrixHasNewConfiguration: Bool = false,
        outputShift: Int? = nil,
        huffmanOffsets: inout [Int32],
        filterHistories: inout [[Int32]],
        activeFIR: inout [MLPFIRParameters?],
        allowPrediction: Bool,
        maximumPredictionOrder: Int,
        enableLPC: Bool
    ) {
        let channelRange = minimumChannel...maximumChannel
        var codedSamples = [[Int32]]()
        codedSamples.reserveCapacity(channelRange.count)
        for channel in channelRange {
            var values = [Int32]()
            values.reserveCapacity(frameRange.count)
            for frame in frameRange {
                let sample = samples[frame * encodedChannelCount + channel]
                values.append(sample)
            }
            codedSamples.append(values)
        }
        var decisions = [MLPChannelCodingDecision]()
        decisions.reserveCapacity(codedSamples.count)
        for (index, rawSamples) in codedSamples.enumerated() {
            let channel = minimumChannel + index
            let decision = MLPPredictiveCoding.select(
                rawSamples: rawSamples,
                history: filterHistories[channel],
                previousOffset: huffmanOffsets[channel],
                activeFIR: activeFIR[channel],
                allowPrediction: allowPrediction,
                maximumOrder: maximumPredictionOrder,
                includeLPC: enableLPC
            )
            decisions.append(decision)
            filterHistories[channel] = decision.finalHistory
            activeFIR[channel] = decision.fir
            huffmanOffsets[channel] = decision.entropy.offset
        }
        let entropyParameters = decisions.map(\.entropy)
        writer.write(0, count: 1) // retain default parameter guards
        writer.write(1, count: 1)
        writer.write(UInt64(frameRange.count), count: 9)
        if let compatibilityStage {
            writer.write(1, count: 1)
            writeCompatibilityMatrix(to: &writer, stage: compatibilityStage)
        } else if let matrixRenderCoefficients {
            writer.write(1, count: 1)
            writeAtmosMatrix(
                to: &writer,
                renderCoefficients: matrixRenderCoefficients,
                newConfiguration: matrixHasNewConfiguration
            )
        } else {
            writer.write(0, count: 1)
        }
        if let outputShift {
            writer.write(1, count: 1)
            for _ in 0...maximumChannel {
                writer.writeSigned(Int32(outputShift), count: 4)
            }
        } else {
            writer.write(0, count: 1)
        }
        writer.write(0, count: 1)
        for decision in decisions {
            let parameters = decision.entropy
            writer.write(1, count: 1)
            MLPPredictiveCoding.writeFIR(decision: decision, to: &writer)
            writer.write(0, count: 1)
            writer.write(parameters.writesOffset ? 1 : 0, count: 1)
            if parameters.writesOffset {
                writer.writeSigned(parameters.offset, count: 15)
            }
            writer.write(UInt64(parameters.codebook), count: 2)
            writer.write(UInt64(parameters.lsbBits), count: 5)
        }
        writeEntropyCodedSamples(
            to: &writer, codedSamples: decisions.map(\.samples),
            parameters: entropyParameters
        )
    }

    private func writeCompatibilityMatrix(
        to writer: inout BitWriter,
        stage: AtmosCompatibilityStage
    ) {
        let scale = Int32(AtmosCompatibilityMatrix.scale)
        let center = Int32(AtmosCompatibilityMatrix.centerCoefficient)
        let rows: [(output: Int, coefficients: [Int32])]
        switch stage {
        case .sixChannel:
            rows = [
                (0, [scale, 0, -scale, 0, -center, 0]),
                (1, [0, scale, 0, -scale, -center, 0]),
            ]
        case .eightChannel:
            rows = [
                (0, [scale, 0, -scale, 0, -center, 0, 0, 0]),
                (1, [0, scale, 0, -scale, -center, 0, 0, -scale]),
                (2, [0, 0, scale, 0, 0, 0, -scale, 0]),
            ]
        }

        writer.write(UInt64(rows.count), count: 4)
        for row in rows {
            writer.write(UInt64(row.output), count: 4)
            writer.write(UInt64(AtmosCompatibilityMatrix.fractionalBits), count: 4)
            writer.write(0, count: 1) // all matrix-output LSBs are derived
            for coefficient in row.coefficients {
                writer.write(coefficient == 0 ? 0 : 1, count: 1)
                if coefficient != 0 {
                    writer.writeSigned(coefficient, count: 16)
                }
            }
            writer.write(0, count: 4) // no matrix noise
        }
    }

    private func writeAtmosMatrix(
        to writer: inout BitWriter,
        renderCoefficients: [[Int32]],
        newConfiguration: Bool
    ) {
        let matrixRows = AtmosCompatibilityMatrix.immersiveRows(
            channelCount: encodedChannelCount,
            renderCoefficients: renderCoefficients
        )
        writer.write(1, count: 1) // new matrix
        writer.write(newConfiguration ? 1 : 0, count: 1)
        if newConfiguration {
            writer.write(UInt64(matrixRows.count - 1), count: 4)
            for row in matrixRows {
                writer.write(UInt64(row.outputChannel), count: 4)
                writer.write(UInt64(AtmosCompatibilityMatrix.fractionalBits), count: 4)
                writer.write(1, count: 3) // coefficient shift zero, encoded with a +1 bias
                writer.write(0, count: 2) // no bypassed LSBs
                writer.write(0, count: 4) // no dither
                writer.write(UInt64(row.coefficientMask), count: encodedChannelCount)
            }
        }
        for row in matrixRows {
            for (channel, coefficient) in row.coefficients.enumerated()
                where row.coefficientMask & (1 << UInt16(channel)) != 0 {
                writer.writeSigned(
                    coefficient,
                    count: AtmosCompatibilityMatrix.fractionalBits + 2
                )
            }
        }
        writer.write(0, count: 1) // no coefficient interpolation
    }

    private func writeEntropyCodedSamples(
        to writer: inout BitWriter,
        codedSamples: [[Int32]],
        parameters: [MLPHuffmanParameters]
    ) {
        guard let frameCount = codedSamples.first?.count else { return }
        for frame in 0..<frameCount {
            for channel in codedSamples.indices {
                MLPHuffman.write(
                    sample: codedSamples[channel][frame],
                    parameters: parameters[channel],
                    to: &writer
                )
            }
        }
    }

    private func updateLosslessChecks(
        _ checks: inout [UInt32],
        samples: [Int32],
        frameCount: Int,
        matrixRenderCoefficients: [[Int32]]
    ) {
        for frame in 0..<frameCount {
            let base = frame * encodedChannelCount
            let transport = samples[base..<(base + encodedChannelCount)]
            let sixChannel = AtmosCompatibilityMatrix.sixChannelOutput(transport)
            let eightChannel = AtmosCompatibilityMatrix.eightChannelOutput(transport)
            let compatibilityOutputs = [
                Array(transport.prefix(2)), sixChannel, eightChannel,
            ]
            for (presentation, output) in compatibilityOutputs.enumerated() {
                for (channel, value) in output.enumerated() {
                    let decoded = value &<< decodedOutputShift
                    let sample = UInt32(bitPattern: decoded) & 0x00FF_FFFF
                    checks[presentation] ^= sample &<< UInt32(channel & 7)
                }
            }

            let matrixOutput = AtmosCompatibilityMatrix.immersiveOutput(
                transport,
                renderCoefficients: matrixRenderCoefficients
            )
            for channel in 0..<encodedChannelCount {
                let decoded = matrixOutput[channel] &<< decodedOutputShift
                let sample = UInt32(bitPattern: decoded) & 0x00FF_FFFF
                checks[3] ^= sample &<< UInt32(channel & 7)
            }
        }
    }

    private func xorBytes(_ input: UInt32) -> UInt8 {
        var value = input
        value ^= value >> 16
        value ^= value >> 8
        return UInt8(truncatingIfNeeded: value)
    }

    private func writeUInt16BE(_ value: UInt16, into bytes: inout [UInt8], at index: Int) {
        bytes[index] = UInt8(value >> 8)
        bytes[index + 1] = UInt8(truncatingIfNeeded: value)
    }
}
