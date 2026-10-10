// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Lossless 7.1 encoder using cumulative 2-, 6-, and 8-channel substreams with
// shared prediction, entropy selection, restart state, and DRC metadata.

import Foundation

final class TrueHDBitstreamEncoder {
    static let samplesPerAccessUnit = 40
    static let channelCount = 8

    private let restartInterval: Int
    private let peakBitRate: Int
    private let maximumInputFrames: UInt64
    private let firstFrameOfAction: String
    private let outputFrameRate: TrueHDOutputFrameRate
    private let drcProfile: TrueHDDRCProfile
    private let predictionMode: TrueHDPredictionMode
    private let stereoDialnorm: Int
    private let multichannelDialnorm: Int
    private var lpcAnalysis = [[MLPFIRParameters]](repeating: [], count: 8)
    private var huffmanOffsetsBySubstream = [[Int32]](
        repeating: [Int32](repeating: 0, count: 8), count: 3
    )
    private var filterHistoriesBySubstream = [[[Int32]]](
        repeating: [[Int32]](
            repeating: [Int32](repeating: 0, count: MLPPredictiveCoding.historyLength),
            count: 8
        ),
        count: 3
    )
    private var activeFIRBySubstream = [[MLPFIRParameters?]](
        repeating: [MLPFIRParameters?](repeating: nil, count: 8), count: 3
    )

    init(configuration: TrueHDEncoderConfiguration) throws {
        guard (0...31).contains(configuration.dialogueNormalization) else {
            throw TrueHDError.invalidConfiguration("Invalid dialogue normalization")
        }
        restartInterval = TrueHDCompliancePolicy.surroundRestartInterval
        peakBitRate = TrueHDCompliancePolicy.peakBitRate
        maximumInputFrames = 0
        firstFrameOfAction = configuration.firstFrameOfAction
        outputFrameRate = configuration.frameRate
        drcProfile = configuration.drcProfile
        predictionMode = configuration.predictionMode
        stereoDialnorm = configuration.dialogueNormalization == 0 ? 30 : configuration.dialogueNormalization
        multichannelDialnorm = configuration.dialogueNormalization == 0 ? 24 : configuration.dialogueNormalization
    }

    func encode(
        reader: TrueHDAudioReader,
        outputURL: URL,
        overwrite: Bool,
        progress: (@Sendable (TrueHDEncodingProgress) -> Void)?
    ) throws -> TrueHDEncodingResult {
        guard reader.format.sampleRate == 48_000 else {
            throw TrueHDError.unsupportedInput("The native encoder currently supports 48 kHz PCM")
        }
        guard reader.format.channelCount == Self.channelCount else {
            throw TrueHDError.unsupportedInput(
                "7.1 TrueHD input must contain exactly 8 PCM channels; input has \(reader.format.channelCount)"
            )
        }
        let standard71Mask: UInt32 = 0x063F
        guard reader.format.channelMask == 0 || reader.format.channelMask == standard71Mask else {
            throw TrueHDError.unsupportedInput(
                "Expected WAVE 7.1 channel order L R C LFE Lb Rb Ls Rs (mask 0x063f)"
            )
        }

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
            if !completed {
                try? fileManager.removeItem(at: outputURL)
            }
        }

        let inputFrameCount = maximumInputFrames == 0
            ? reader.frameCount
            : min(reader.frameCount, maximumInputFrames)
        let totalAccessUnits = (inputFrameCount + UInt64(Self.samplesPerAccessUnit - 1))
            / UInt64(Self.samplesPerAccessUnit)
        var outputBuffer = Data()
        outputBuffer.reserveCapacity(1_048_576)
        var bytesWritten: UInt64 = 0
        var accessUnitRecords = [MLPAccessUnitRecord]()
        accessUnitRecords.reserveCapacity(Int(totalAccessUnits))
        var frameIndex: UInt64 = 0
        var intervalLosslessChecks: [UInt32] = [0, 0, 0]
        var highResolutionTimingWriter = HighResolutionTimingWriter()
        var dynamicRangeControl = TrueHDDynamicRangeControl(
            profile: drcProfile,
            channelCount: Self.channelCount,
            presentationMaximumChannels: [1, 5, 7],
            dialogueNormalizations: [stereoDialnorm, multichannelDialnorm, multichannelDialnorm]
        )

        var intervalSamples = [Int32]()
        var intervalFrames = 0
        var intervalOffset = 0
        while frameIndex < totalAccessUnits {
            if frameIndex & 0xFF == 0 {
                try Task.checkCancellation()
            }
            let encodedFrames = frameIndex * UInt64(Self.samplesPerAccessUnit)
            let remainingFrames = inputFrameCount - encodedFrames
            if intervalOffset == intervalFrames {
                let interval = try reader.readFrames(maxCount: Int(min(
                    UInt64(restartInterval * Self.samplesPerAccessUnit), remainingFrames
                )))
                guard interval.frameCount > 0 else {
                    throw TrueHDError.unsupportedInput("Input ended before its declared sample count")
                }
                intervalSamples = interval.samples
                intervalFrames = interval.frameCount
                intervalOffset = 0
                if predictionMode.includesLPC {
                    lpcAnalysis = MLPPredictiveCoding.analyzeInterval(
                        samples: intervalSamples, channels: Self.channelCount
                    )
                }
            }
            let count = min(Self.samplesPerAccessUnit, intervalFrames - intervalOffset)
            let start = intervalOffset * Self.channelCount
            let block = PCMFrameBlock(
                samples: Array(intervalSamples[start..<(start + count * Self.channelCount)]),
                frameCount: count
            )
            intervalOffset += count

            var samples = block.samples
            samples.append(
                contentsOf: repeatElement(
                    0,
                    count: (Self.samplesPerAccessUnit - block.frameCount) * Self.channelCount
                )
            )

            let restartFrame = frameIndex % UInt64(restartInterval) == 0
            let highResolutionTiming = restartFrame
                ? highResolutionTimingWriter.nextBit(
                    outputSample: frameIndex * UInt64(Self.samplesPerAccessUnit)
                )
                : false
            let restartChecks: [UInt32]
            if restartFrame {
                restartChecks = intervalLosslessChecks
                intervalLosslessChecks = [0, 0, 0]
            } else {
                restartChecks = [0, 0, 0]
            }

            let shortenBy = Self.samplesPerAccessUnit - block.frameCount
            let drcUpdates = dynamicRangeControl.updates(
                samples: samples,
                frameCount: block.frameCount,
                accessUnit: frameIndex,
                forceUpdate: frameIndex + 1 == totalAccessUnits
            )
            let accessUnit = makeAccessUnit(
                samples: samples,
                actualFrameCount: block.frameCount,
                frameIndex: frameIndex,
                restartFrame: restartFrame,
                restartLosslessChecks: restartChecks,
                shortenBy: shortenBy,
                highResolutionTiming: highResolutionTiming,
                drcUpdates: drcUpdates
            )
            let instantaneousRate = accessUnit.count * 8 * reader.format.sampleRate
                / Self.samplesPerAccessUnit
            guard instantaneousRate <= peakBitRate else {
                throw TrueHDError.peakBitRateExceeded(
                    required: instantaneousRate,
                    limit: peakBitRate
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

            intervalLosslessChecks[0] ^= frameLosslessCheck(
                samples: samples,
                frameCount: block.frameCount,
                maximumChannel: 1
            )
            intervalLosslessChecks[1] ^= frameLosslessCheck(
                samples: samples,
                frameCount: block.frameCount,
                maximumChannel: 5
            )
            intervalLosslessChecks[2] ^= frameLosslessCheck(
                samples: samples,
                frameCount: block.frameCount,
                maximumChannel: 7
            )

            frameIndex += 1
            if outputBuffer.count >= 1_048_576 {
                try output.write(contentsOf: outputBuffer)
                outputBuffer.removeAll(keepingCapacity: true)
            }
            if frameIndex == totalAccessUnits || frameIndex % 256 == 0 {
                progress?(
                    TrueHDEncodingProgress(
                        completedFrames: frameIndex,
                        totalFrames: totalAccessUnits,
                        encodedBytes: bytesWritten
                    )
                )
            }
        }

        if !outputBuffer.isEmpty {
            try output.write(contentsOf: outputBuffer)
        }
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
            substreamCount: 3,
            authenticateEvolution: false
        )
        completed = true

        return TrueHDEncodingResult(
            outputURL: outputURL,
            profile: .surround71,
            sampleRate: reader.format.sampleRate,
            channelCount: Self.channelCount,
            inputFrameCount: inputFrameCount,
            outputByteCount: bytesWritten,
            sourceFrameRate: reader.sourceFrameRate,
            outputFrameRate: outputFrameRate.resolve(input: reader.sourceFrameRate),
            firstFrameOfAction: firstFrameOfAction,
            spatialClusterCount: 0,
            elementBitDepth: reader.format.bitsPerSample,
            drcProfile: drcProfile,
            spatialAccuracy: nil
        )
    }

    private func makeAccessUnit(
        samples: [Int32],
        actualFrameCount: Int,
        frameIndex: UInt64,
        restartFrame: Bool,
        restartLosslessChecks: [UInt32],
        shortenBy: Int,
        highResolutionTiming: Bool,
        drcUpdates: [Int?]
    ) -> [UInt8] {
        let outputTiming = UInt16(truncatingIfNeeded: frameIndex * UInt64(Self.samplesPerAccessUnit))
        let inputTiming = outputTiming &- UInt16(Self.samplesPerAccessUnit)
        var substream0Offsets = huffmanOffsetsBySubstream[0]
        var substream0FilterHistories = filterHistoriesBySubstream[0]
        var substream0ActiveFIR = activeFIRBySubstream[0]
        let substream0 = makeSubstream(
            samples: samples,
            minimumChannel: 0,
            maximumChannel: 1,
            maximumMatrixChannel: 1,
            timing: outputTiming,
            restartFrame: restartFrame,
            losslessCheck: restartLosslessChecks[0],
            shortenBy: shortenBy,
            highResolutionTiming: highResolutionTiming,
            huffmanOffsets: &substream0Offsets,
            filterHistories: &substream0FilterHistories,
            activeFIR: &substream0ActiveFIR
        )
        huffmanOffsetsBySubstream[0] = substream0Offsets
        filterHistoriesBySubstream[0] = substream0FilterHistories
        activeFIRBySubstream[0] = substream0ActiveFIR
        var substream1Offsets = huffmanOffsetsBySubstream[1]
        var substream1FilterHistories = filterHistoriesBySubstream[1]
        var substream1ActiveFIR = activeFIRBySubstream[1]
        let substream1 = makeSubstream(
            samples: samples,
            minimumChannel: 2,
            maximumChannel: 5,
            maximumMatrixChannel: 5,
            timing: outputTiming,
            restartFrame: restartFrame,
            losslessCheck: restartLosslessChecks[1],
            shortenBy: shortenBy,
            highResolutionTiming: highResolutionTiming,
            huffmanOffsets: &substream1Offsets,
            filterHistories: &substream1FilterHistories,
            activeFIR: &substream1ActiveFIR
        )
        huffmanOffsetsBySubstream[1] = substream1Offsets
        filterHistoriesBySubstream[1] = substream1FilterHistories
        activeFIRBySubstream[1] = substream1ActiveFIR
        var substream2Offsets = huffmanOffsetsBySubstream[2]
        var substream2FilterHistories = filterHistoriesBySubstream[2]
        var substream2ActiveFIR = activeFIRBySubstream[2]
        let substream2 = makeSubstream(
            samples: samples,
            minimumChannel: 6,
            maximumChannel: 7,
            maximumMatrixChannel: 7,
            timing: outputTiming,
            restartFrame: restartFrame,
            losslessCheck: restartLosslessChecks[2],
            shortenBy: shortenBy,
            highResolutionTiming: highResolutionTiming,
            huffmanOffsets: &substream2Offsets,
            filterHistories: &substream2FilterHistories,
            activeFIR: &substream2ActiveFIR
        )
        huffmanOffsetsBySubstream[2] = substream2Offsets
        filterHistoriesBySubstream[2] = substream2FilterHistories
        activeFIRBySubstream[2] = substream2ActiveFIR

        var body = [UInt8]()
        if restartFrame {
            body.append(contentsOf: makeMajorSync())
        }
        let substreamHeaderOffset = body.count
        precondition(drcUpdates.count == 3)
        let directoryEntrySizes = drcUpdates.map { $0 == nil ? 2 : 4 }
        let directoryByteCount = directoryEntrySizes.reduce(0, +)
        body.append(contentsOf: repeatElement(0, count: directoryByteCount))
        body.append(contentsOf: substream0)
        body.append(contentsOf: substream1)
        body.append(contentsOf: substream2)

        let totalByteCount = 4 + body.count
        precondition(totalByteCount & 1 == 0)
        let lengthInWords = totalByteCount / 2
        precondition(lengthInWords <= 0x0FFF)

        let substream0End = substream0.count / 2
        let substream1End = (substream0.count + substream1.count) / 2
        let substream2End = (substream0.count + substream1.count + substream2.count) / 2
        let commonFlags: UInt16 = (restartFrame ? 0 : 1 << 14) | (1 << 13)
        let substreamEnds = [substream0End, substream1End, substream2End]
        var entryOffset = substreamHeaderOffset
        for index in substreamEnds.indices {
            let extraWordFlag: UInt16 = drcUpdates[index] == nil ? 0 : 1 << 15
            let header = extraWordFlag | commonFlags
                | UInt16(substreamEnds[index] & 0x0FFF)
            writeUInt16BE(header, into: &body, at: entryOffset)
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
        for byte in body[substreamHeaderOffset..<(substreamHeaderOffset + directoryByteCount)] {
            parity ^= UInt16(byte)
        }
        parity ^= parity >> 8
        parity ^= parity >> 4
        parity &= 0x0F

        let accessHeader = ((parity ^ 0x0F) << 12) | UInt16(lengthInWords)
        var result = [UInt8]()
        result.reserveCapacity(totalByteCount)
        result.append(UInt8(accessHeader >> 8))
        result.append(UInt8(truncatingIfNeeded: accessHeader))
        result.append(UInt8(inputTiming >> 8))
        result.append(UInt8(truncatingIfNeeded: inputTiming))
        result.append(contentsOf: body)
        return result
    }

    private func makeMajorSync(declaredCodedPeakRate: Int? = nil) -> [UInt8] {
        var writer = BitWriter(reservingCapacity: 28)
        writer.write(0xF8726F, count: 24)
        writer.write(0xBA, count: 8)
        writer.write(0, count: 4) // 48 kHz
        writer.write(0, count: 1) // 6-channel multichannel type
        writer.write(0, count: 1) // 8-channel multichannel type
        writer.write(0, count: 2)
        writer.write(0, count: 2) // 2-channel presentation modifier
        writer.write(1, count: 2) // Select the standard 5.1 channel assignment.
        writer.write(0x0F, count: 5) // L R C LFE Ls Rs
        writer.write(0, count: 2) // 8-channel presentation modifier
        writer.write(0x04F, count: 13) // plus Lb Rb
        writer.write(0xB752, count: 16)
        writer.write(0, count: 16)
        writer.write(0, count: 16)
        writer.write(1, count: 1) // variable bit rate
        let codedPeak = declaredCodedPeakRate
            ?? MLPTransportTiming.maximumCodedPeakRate
        writer.write(UInt64(codedPeak), count: 15)
        writer.write(3, count: 4) // 2-, 6-, and 8-channel cumulative substreams
        writer.write(0, count: 2)
        writer.write(0, count: 2) // no extended spatial substream
        // Bit 6 admits the third audio substream in the eight-channel
        // presentation. With 0x3C DRP accepts transport but outputs silence.
        writer.write(0x7C, count: 8)
        writer.write(0, count: 6) // heavy DRC start-up gain
        writer.write(8, count: 4) // stereo DRC control enabled by default
        writer.write(0, count: 7) // DRC start-up gain
        writer.write(UInt64(stereoDialnorm), count: 6)
        writer.write(29, count: 6) // stereo mix level
        writer.write(UInt64(multichannelDialnorm), count: 5)
        writer.write(35, count: 6) // 5.1 mix level
        writer.write(0, count: 5) // 5.1 source format
        writer.write(UInt64(multichannelDialnorm), count: 5)
        writer.write(35, count: 6) // 7.1 mix level
        writer.write(0, count: 6) // 7.1 source format
        writer.write(0, count: 1)
        writer.write(0, count: 1) // no extra channel meaning
        writer.flush()
        precondition(writer.bytes.count == 26)

        var bytes = writer.bytes
        let checksum = MLPChecksums.checksum16(bytes)
        bytes.append(UInt8(truncatingIfNeeded: checksum))
        bytes.append(UInt8(checksum >> 8))
        return bytes
    }

    private func makeSubstream(
        samples: [Int32],
        minimumChannel: Int,
        maximumChannel: Int,
        maximumMatrixChannel: Int,
        timing: UInt16,
        restartFrame: Bool,
        losslessCheck: UInt32,
        shortenBy: Int,
        highResolutionTiming: Bool,
        huffmanOffsets: inout [Int32],
        filterHistories: inout [[Int32]],
        activeFIR: inout [MLPFIRParameters?]
    ) -> [UInt8] {
        var writer = BitWriter(reservingCapacity: 768)

        if restartFrame {
            for channel in minimumChannel...maximumChannel {
                huffmanOffsets[channel] = 0
                activeFIR[channel] = nil
            }
            writer.write(1, count: 1)
            writer.write(1, count: 1)
            writeRestartHeader(
                to: &writer,
                minimumChannel: minimumChannel,
                maximumChannel: maximumChannel,
                maximumMatrixChannel: maximumMatrixChannel,
                timing: timing,
                losslessCheck: losslessCheck,
                highResolutionTiming: highResolutionTiming
            )
            writeEntropyBlock(
                to: &writer,
                samples: samples,
                frameRange: 0..<8,
                blockSize: 8,
                minimumChannel: minimumChannel,
                maximumChannel: maximumChannel,
                huffmanOffsets: &huffmanOffsets,
                filterHistories: &filterHistories,
                activeFIR: &activeFIR,
                allowPrediction: false
            )
            writer.write(0, count: 1)

            writer.write(1, count: 1)
            writer.write(0, count: 1)
            writeEntropyBlock(
                to: &writer,
                samples: samples,
                frameRange: 8..<40,
                blockSize: 32,
                minimumChannel: minimumChannel,
                maximumChannel: maximumChannel,
                huffmanOffsets: &huffmanOffsets,
                filterHistories: &filterHistories,
                activeFIR: &activeFIR,
                allowPrediction: true
            )
            writer.write(1, count: 1)
        } else {
            writer.write(1, count: 1)
            writer.write(0, count: 1)
            writeEntropyBlock(
                to: &writer,
                samples: samples,
                frameRange: 0..<40,
                blockSize: 40,
                minimumChannel: minimumChannel,
                maximumChannel: maximumChannel,
                huffmanOffsets: &huffmanOffsets,
                filterHistories: &filterHistories,
                activeFIR: &activeFIR,
                allowPrediction: true
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
        precondition(bytes.count & 1 == 0)
        return bytes
    }

    private func writeRestartHeader(
        to writer: inout BitWriter,
        minimumChannel: Int,
        maximumChannel: Int,
        maximumMatrixChannel: Int,
        timing: UInt16,
        losslessCheck: UInt32,
        highResolutionTiming: Bool
    ) {
        let startBitCount = writer.bitCount
        let restartType = maximumMatrixChannel > 1 ? 0x31EB : 0x31EA
        writer.write(UInt64(restartType), count: 14)
        writer.write(UInt64(timing), count: 16)
        writer.write(UInt64(minimumChannel), count: 4)
        writer.write(UInt64(maximumChannel), count: 4)
        writer.write(UInt64(maximumMatrixChannel), count: 4)
        writer.write(0, count: 4)
        writer.write(0, count: 23)
        writer.write(0, count: 4)
        writer.write(24, count: 5)
        writer.write(24, count: 5)
        writer.write(24, count: 5)
        writer.write(0, count: 1)
        writer.write(UInt64(xorBytes(losslessCheck)), count: 8)
        writer.write(highResolutionTiming ? 1 : 0, count: 1)
        writer.write(0, count: 15)

        let channelAssignments: [Int]
        switch maximumMatrixChannel {
        case 1:
            channelAssignments = [0, 1]
        case 5:
            channelAssignments = Array(0...5)
        default:
            channelAssignments = [0, 1, 2, 3, 6, 7, 4, 5]
        }
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

    private func writeEntropyBlock(
        to writer: inout BitWriter,
        samples: [Int32],
        frameRange: Range<Int>,
        blockSize: Int,
        minimumChannel: Int,
        maximumChannel: Int,
        huffmanOffsets: inout [Int32],
        filterHistories: inout [[Int32]],
        activeFIR: inout [MLPFIRParameters?],
        allowPrediction: Bool
    ) {
        let channelRange = minimumChannel...maximumChannel
        let codedSamples = channelRange.map { channel in
            frameRange.map { frame in samples[frame * Self.channelCount + channel] }
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
                allowPrediction: allowPrediction && predictionMode != .none,
                maximumOrder: predictionMode.maximumOrder,
                includeLPC: predictionMode.includesLPC,
                analysisCandidates: lpcAnalysis[channel]
            )
            decisions.append(decision)
            filterHistories[channel] = decision.finalHistory
            activeFIR[channel] = decision.fir
            huffmanOffsets[channel] = decision.entropy.offset
        }

        writer.write(0, count: 1) // keep default parameter-presence flags
        writer.write(1, count: 1)
        writer.write(UInt64(blockSize), count: 9)
        writer.write(0, count: 1) // unchanged matrix parameters
        writer.write(0, count: 1) // unchanged output shifts
        writer.write(0, count: 1) // unchanged quantization steps

        for decision in decisions {
            let value = decision.entropy
            writer.write(1, count: 1)
            MLPPredictiveCoding.writeFIR(decision: decision, to: &writer)
            writer.write(0, count: 1) // unchanged IIR
            writer.write(value.writesOffset ? 1 : 0, count: 1)
            if value.writesOffset { writer.writeSigned(value.offset, count: 15) }
            writer.write(UInt64(value.codebook), count: 2)
            writer.write(UInt64(value.lsbBits), count: 5)
        }

        for frame in decisions[0].samples.indices {
            for decision in decisions {
                MLPHuffman.write(
                    sample: decision.samples[frame],
                    parameters: decision.entropy,
                    to: &writer
                )
            }
        }
    }

    private func frameLosslessCheck(
        samples: [Int32],
        frameCount: Int,
        maximumChannel: Int
    ) -> UInt32 {
        var result: UInt32 = 0
        for frame in 0..<frameCount {
            let base = frame * Self.channelCount
            for channel in 0...maximumChannel {
                let sample = UInt32(bitPattern: samples[base + channel]) & 0x00FF_FFFF
                result ^= sample &<< UInt32(channel)
            }
        }
        return result
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
