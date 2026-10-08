// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Native readers expose DAMF, CAF, ADM, and IAB sources through one random-access
// PCM interface so the encoder does not require intermediate media files.

import Foundation

/// Selects one of the native PCM/IAB readers without creating an intermediate media file.
enum NativeMasterReader {
    static func open(url: URL) throws -> TrueHDAudioReader {
        let resolved = try resolveInput(url)
        switch resolved.pathExtension.lowercased() {
        case "wav", "wave", "rf64":
            return try WaveFileReader(url: resolved)
        case "atmos":
            let descriptor = try DAMFDescriptor(manifestURL: resolved)
            // Probe the CAF before resolving whether manifest IDs describe a
            // packed persistent-ID list or sparse physical channel slots.
            let probe = try CAFFileReader(url: descriptor.audioURL)
            return try CAFFileReader(
                url: descriptor.audioURL,
                admMetadata: descriptor.metadata(channelCount: probe.format.channelCount),
                sourceFrameRate: descriptor.frameRate
            )
        case "mxf":
            return try MXFIABReader(url: resolved)
        default:
            throw TrueHDError.unsupportedInput(
                "Supported native Atmos masters are ADM WAVE, DAMF .atmos, and IMF IAB MXF"
            )
        }
    }

    private static func resolveInput(_ url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw TrueHDError.unsupportedInput("Input master does not exist: \(url.path)")
        }
        guard isDirectory.boolValue else { return url }
        let files = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        if let manifest = files.first(where: { $0.pathExtension.lowercased() == "atmos" }) {
            return manifest
        }
        if let wave = files.first(where: { ["wav", "wave", "rf64"].contains($0.pathExtension.lowercased()) }) {
            return wave
        }
        if let mxf = files.first(where: { $0.pathExtension.lowercased() == "mxf" }) {
            return mxf
        }
        throw TrueHDError.unsupportedInput("Input directory contains no supported master")
    }
}

final class CAFFileReader: TrueHDAudioReader {
    let format: WaveFormat
    let frameCount: UInt64
    let admXML: Data? = nil
    let admChannelAssignment: Data? = nil
    let admMetadata: ADMMetadata?
    let sourceFrameRate: TrueHDFrameRate?

    private let handle: FileHandle
    private let dataOffset: UInt64
    private let dataByteCount: UInt64
    private var currentFrame: UInt64 = 0

    init(
        url: URL,
        admMetadata: ADMMetadata? = nil,
        sourceFrameRate: TrueHDFrameRate? = nil
    ) throws {
        handle = try FileHandle(forReadingFrom: url)
        let fileSize = try handle.seekToEnd()
        let header = try Self.readExactly(handle, offset: 0, count: 8)
        guard Self.fourCC(header, at: 0) == "caff" else {
            throw TrueHDError.invalidWaveFile("CAF file has no caff header")
        }

        var offset: UInt64 = 8
        var parsedFormat: WaveFormat?
        var parsedDataOffset: UInt64?
        var parsedDataSize: UInt64?
        while offset + 12 <= fileSize {
            let chunkHeader = try Self.readExactly(handle, offset: offset, count: 12)
            let chunkID = Self.fourCC(chunkHeader, at: 0)
            let chunkSize = Self.u64BE(chunkHeader, at: 4)
            let payloadOffset = offset + 12
            guard payloadOffset <= fileSize, chunkSize <= fileSize - payloadOffset else {
                throw TrueHDError.invalidWaveFile("CAF chunk exceeds the file")
            }
            switch chunkID {
            case "desc":
                guard chunkSize >= 32 else {
                    throw TrueHDError.invalidWaveFile("CAF desc chunk is truncated")
                }
                let desc = try Self.readExactly(handle, offset: payloadOffset, count: 32)
                let sampleRate = Int(Self.doubleBE(desc, at: 0).rounded())
                let formatID = Self.fourCC(desc, at: 8)
                let flags = Self.u32BE(desc, at: 12)
                let bytesPerPacket = Int(Self.u32BE(desc, at: 16))
                let framesPerPacket = Int(Self.u32BE(desc, at: 20))
                let bytesPerFrame = framesPerPacket > 0 ? bytesPerPacket / framesPerPacket : 0
                let channelCount = Int(Self.u32BE(desc, at: 24))
                let bitsPerSample = Int(Self.u32BE(desc, at: 28))
                let isFloat = flags & 1 != 0
                // CAF lpcm uses bit 1 for little-endian, unlike the generic
                // Core Audio PCM flag with the same numeric value.
                let isBigEndian = flags & 2 == 0
                // CAF lpcm files may omit the signed-integer flag; packed integer
                // PCM is the default when the float flag is clear.
                guard formatID == "lpcm", !isFloat,
                      sampleRate > 0, channelCount > 0,
                      (bitsPerSample == 16 || bitsPerSample == 24 || bitsPerSample == 32),
                      bytesPerFrame >= channelCount * (bitsPerSample / 8) else {
                    throw TrueHDError.unsupportedInput(
                        "CAF input must be signed integer lpcm with 16-, 24-, or 32-bit samples"
                    )
                }
                parsedFormat = WaveFormat(
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    bitsPerSample: bitsPerSample,
                    validBitsPerSample: bitsPerSample,
                    blockAlignment: bytesPerFrame,
                    channelMask: 0,
                    isBigEndian: isBigEndian
                )
            case "data":
                guard chunkSize >= 4 else {
                    throw TrueHDError.invalidWaveFile("CAF data chunk is truncated")
                }
                parsedDataOffset = payloadOffset + 4
                parsedDataSize = chunkSize - 4
            default:
                break
            }
            offset = payloadOffset + chunkSize
        }

        guard let parsedFormat, let parsedDataOffset, let parsedDataSize else {
            throw TrueHDError.invalidWaveFile("CAF file has no desc/data chunks")
        }
        guard parsedFormat.blockAlignment > 0 else {
            throw TrueHDError.invalidWaveFile("CAF block alignment is zero")
        }
        format = parsedFormat
        dataOffset = parsedDataOffset
        dataByteCount = parsedDataSize
        frameCount = parsedDataSize / UInt64(parsedFormat.blockAlignment)
        self.admMetadata = admMetadata
        self.sourceFrameRate = sourceFrameRate
    }

    deinit { try? handle.close() }

    func readFrames(maxCount: Int) throws -> PCMFrameBlock {
        precondition(maxCount > 0)
        let remaining = frameCount - currentFrame
        let requested = Int(min(UInt64(maxCount), remaining))
        guard requested > 0 else { return PCMFrameBlock(samples: [], frameCount: 0) }
        let byteCount = requested * format.blockAlignment
        let offset = dataOffset + currentFrame * UInt64(format.blockAlignment)
        let bytes = try Self.readExactly(handle, offset: offset, count: byteCount)
        let samples = Self.decodeSamples(bytes, frameCount: requested, format: format)
        currentFrame += UInt64(requested)
        return PCMFrameBlock(samples: samples, frameCount: requested)
    }

    func seek(toFrame frame: UInt64) throws {
        guard frame <= frameCount else {
            throw TrueHDError.invalidConfiguration("Input start frame is beyond the end of the CAF file")
        }
        currentFrame = frame
    }

    private static func decodeSamples(
        _ data: Data,
        frameCount: Int,
        format: WaveFormat
    ) -> [Int32] {
        let channelCount = format.channelCount
        let frameStride = format.blockAlignment
        var samples = [Int32](repeating: 0, count: frameCount * channelCount)

        data.withUnsafeBytes { rawBuffer in
            let source = rawBuffer.bindMemory(to: UInt8.self)
            samples.withUnsafeMutableBufferPointer { destination in
                var outputIndex = 0
                switch (format.bitsPerSample, format.isBigEndian) {
                case (16, false):
                    for frame in 0..<frameCount {
                        var inputOffset = frame * frameStride
                        for _ in 0..<channelCount {
                            let raw = UInt16(source[inputOffset])
                                | UInt16(source[inputOffset + 1]) << 8
                            destination[outputIndex] = Int32(Int16(bitPattern: raw)) << 8
                            inputOffset += 2
                            outputIndex += 1
                        }
                    }
                case (16, true):
                    for frame in 0..<frameCount {
                        var inputOffset = frame * frameStride
                        for _ in 0..<channelCount {
                            let raw = UInt16(source[inputOffset]) << 8
                                | UInt16(source[inputOffset + 1])
                            destination[outputIndex] = Int32(Int16(bitPattern: raw)) << 8
                            inputOffset += 2
                            outputIndex += 1
                        }
                    }
                case (24, false):
                    for frame in 0..<frameCount {
                        var inputOffset = frame * frameStride
                        for _ in 0..<channelCount {
                            var raw = UInt32(source[inputOffset])
                                | UInt32(source[inputOffset + 1]) << 8
                                | UInt32(source[inputOffset + 2]) << 16
                            if raw & 0x0080_0000 != 0 { raw |= 0xFF00_0000 }
                            destination[outputIndex] = Int32(bitPattern: raw)
                            inputOffset += 3
                            outputIndex += 1
                        }
                    }
                case (24, true):
                    for frame in 0..<frameCount {
                        var inputOffset = frame * frameStride
                        for _ in 0..<channelCount {
                            var raw = UInt32(source[inputOffset]) << 16
                                | UInt32(source[inputOffset + 1]) << 8
                                | UInt32(source[inputOffset + 2])
                            if raw & 0x0080_0000 != 0 { raw |= 0xFF00_0000 }
                            destination[outputIndex] = Int32(bitPattern: raw)
                            inputOffset += 3
                            outputIndex += 1
                        }
                    }
                case (32, false):
                    for frame in 0..<frameCount {
                        var inputOffset = frame * frameStride
                        for _ in 0..<channelCount {
                            let raw = UInt32(source[inputOffset])
                                | UInt32(source[inputOffset + 1]) << 8
                                | UInt32(source[inputOffset + 2]) << 16
                                | UInt32(source[inputOffset + 3]) << 24
                            destination[outputIndex] = Int32(bitPattern: raw) >> 8
                            inputOffset += 4
                            outputIndex += 1
                        }
                    }
                case (32, true):
                    for frame in 0..<frameCount {
                        var inputOffset = frame * frameStride
                        for _ in 0..<channelCount {
                            let raw = UInt32(source[inputOffset]) << 24
                                | UInt32(source[inputOffset + 1]) << 16
                                | UInt32(source[inputOffset + 2]) << 8
                                | UInt32(source[inputOffset + 3])
                            destination[outputIndex] = Int32(bitPattern: raw) >> 8
                            inputOffset += 4
                            outputIndex += 1
                        }
                    }
                default:
                    preconditionFailure("CAF format was not validated during initialization")
                }
            }
        }
        return samples
    }

    private static func readExactly(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw TrueHDError.invalidWaveFile("Unexpected end of CAF file")
        }
        return data
    }

    private static func fourCC(_ bytes: Data, at offset: Int) -> String {
        String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }

    private static func u32BE(_ bytes: Data, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func u64BE(_ bytes: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(bytes[offset + index]) }
        return value
    }

    private static func doubleBE(_ bytes: Data, at offset: Int) -> Double {
        Double(bitPattern: u64BE(bytes, at: offset))
    }
}

private struct DAMFDescriptor {
    private struct PositionEvent {
        let sample: UInt64
        let position: ADMPosition
        let rampLength: UInt64
    }

    let audioURL: URL
    private let positions: [Int: [PositionEvent]]
    private let bedChannelLabelsByID: [Int: String]
    private let objectIDs: [Int]
    private let ffoa: Double
    let frameRate: TrueHDFrameRate

    init(manifestURL: URL) throws {
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
        var audioName: String?
        var metadataName: String?
        var fps: Double?
        var ffoa = 0.0
        var inBed = false
        var inObjects = false
        var pendingBedChannel: String?
        var bedChannelLabelsByID = [Int: String]()
        var objectIDs = [Int]()
        var seenObjectIDs = Set<Int>()
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let value = String(line).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("audio:") {
                audioName = value.dropFirst("audio:".count).trimmingCharacters(in: .whitespaces)
            } else if value.hasPrefix("metadata:") {
                metadataName = value.dropFirst("metadata:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if value.hasPrefix("fps:") {
                fps = Double(value.dropFirst("fps:".count).trimmingCharacters(in: .whitespaces))
            } else if value.hasPrefix("ffoa:") {
                ffoa = Double(value.dropFirst("ffoa:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if value == "bedInstances:" {
                inBed = true
                inObjects = false
                pendingBedChannel = nil
            } else if value.hasPrefix("objects:") {
                inBed = false
                inObjects = true
                pendingBedChannel = nil
            } else if inBed && (value.hasPrefix("- channel:") || value.hasPrefix("channel:")) {
                pendingBedChannel = value
                    .split(separator: ":", maxSplits: 1)[1]
                    .trimmingCharacters(in: .whitespaces)
            } else if (inBed || inObjects) && (value.hasPrefix("- ID:") || value.hasPrefix("ID:")) {
                let idText = value.hasPrefix("- ID:")
                    ? value.dropFirst(5)
                    : value.dropFirst(3)
                if let id = Int(idText.trimmingCharacters(in: .whitespaces)) {
                    if inBed, let pendingBedChannel {
                        bedChannelLabelsByID[id] = pendingBedChannel
                    } else if inObjects, seenObjectIDs.insert(id).inserted {
                        objectIDs.append(id)
                    }
                    pendingBedChannel = nil
                }
            }
        }
        guard let audioName else {
            throw TrueHDError.invalidWaveFile("DAMF manifest has no audio reference")
        }
        let audioURL = manifestURL.deletingLastPathComponent().appendingPathComponent(audioName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TrueHDError.invalidWaveFile("DAMF audio file is missing: \(audioURL.path)")
        }
        let frameRate = try Self.frameRate(from: fps)
        let metadataURL = manifestURL.deletingLastPathComponent().appendingPathComponent(
            metadataName ?? (manifestURL.deletingPathExtension().lastPathComponent + ".atmos.metadata")
        )
        let metadataText = try String(contentsOf: metadataURL, encoding: .utf8)
        let sampleRate = Self.sampleRate(from: metadataText) ?? 48_000
        let positions = Self.positions(from: metadataText, sampleRate: sampleRate)
        // Validate the required Bed labels before the CAF channel count is
        // available to resolve packed persistent IDs versus physical slots.
        let bedFormatByLabel = [
            "L": "AC_00011001", "R": "AC_00011002", "C": "AC_00011003",
            "LFE": "AC_00011004", "Lss": "AC_00011005", "Rss": "AC_00011006",
            "Lrs": "AC_00011007", "Rrs": "AC_00011008", "Lts": "AC_00011009",
            "Rts": "AC_0001100a"
        ]
        guard bedChannelLabelsByID.count == bedFormatByLabel.count,
              Set(bedChannelLabelsByID.values) == Set(bedFormatByLabel.keys) else {
            throw TrueHDError.invalidWaveFile(
                "DAMF manifest does not describe all ten Bed channel labels"
            )
        }
        self.audioURL = audioURL
        self.positions = positions
        self.bedChannelLabelsByID = bedChannelLabelsByID
        self.objectIDs = objectIDs
        self.ffoa = ffoa
        self.frameRate = frameRate
    }

    func metadata(channelCount: Int) throws -> ADMMetadata {
        guard channelCount > 0 else {
            throw TrueHDError.invalidWaveFile("DAMF CAF has no PCM channels")
        }
        let bedFormatByLabel = [
            "L": "AC_00011001", "R": "AC_00011002", "C": "AC_00011003",
            "LFE": "AC_00011004", "Lss": "AC_00011005", "Rss": "AC_00011006",
            "Lrs": "AC_00011007", "Rrs": "AC_00011008", "Lts": "AC_00011009",
            "Rts": "AC_0001100a"
        ]
        let bedIDs = bedChannelLabelsByID.keys.sorted()
        let trackIDs = bedIDs + objectIDs
        guard Set(trackIDs).count == trackIDs.count else {
            throw TrueHDError.invalidWaveFile("DAMF reuses a source ID")
        }
        guard trackIDs.count <= channelCount else {
            throw TrueHDError.invalidWaveFile(
                "DAMF describes \(trackIDs.count) sources for \(channelCount) CAF channels"
            )
        }

        let sourceIDByChannel: [Int?]
        if trackIDs.count == channelCount {
            // DAMF IDs are normally persistent identifiers. The CAF stores the
            // corresponding sources contiguously in Bed/object manifest order.
            sourceIDByChannel = trackIDs.map(Optional.some)
        } else {
            // Some producers preserve a larger physical CAF slot array. This
            // representation is only unambiguous when every declared ID fits
            // directly in that array; otherwise the manifest is inconsistent.
            guard trackIDs.allSatisfy({ (0..<channelCount).contains($0) }) else {
                throw TrueHDError.invalidWaveFile(
                    "DAMF source IDs cannot be mapped to the CAF channel array"
                )
            }
            var physicalSlots = [Int?](repeating: nil, count: channelCount)
            for sourceID in trackIDs { physicalSlots[sourceID] = sourceID }
            sourceIDByChannel = physicalSlots
        }

        let objectIDSet = Set(objectIDs)
        var channels = [ADMChannelMetadata]()
        channels.reserveCapacity(channelCount)
        for (channel, sourceID) in sourceIDByChannel.enumerated() {
            let label = sourceID.flatMap { bedChannelLabelsByID[$0] }
            let isObject = sourceID.map(objectIDSet.contains) ?? false
            let formatID: String
            if let label {
                guard let mapped = bedFormatByLabel[label] else {
                    throw TrueHDError.invalidWaveFile(
                        "DAMF manifest contains unsupported Bed label: \(label)"
                    )
                }
                formatID = mapped
            } else if let sourceID {
                formatID = String(format: "AC_0003%04x", sourceID + 1)
            } else {
                formatID = String(format: "AC_0003%04x", channel + 1)
            }
            channels.append(ADMChannelMetadata(
                channelFormatID: formatID,
                isObject: isObject,
                blocks: Self.makeBlocks(sourceID.flatMap { positions[$0] } ?? []),
                isPresent: sourceID != nil
            ))
        }
        return ADMMetadata(channels: channels, programmeStartSeconds: ffoa)
    }

    private static func frameRate(from value: Double?) throws -> TrueHDFrameRate {
        guard let value else { throw TrueHDError.unsupportedInput("DAMF manifest has no fps") }
        guard let frameRate = TrueHDFrameRate.fromFramesPerSecond(value) else {
            throw TrueHDError.unsupportedInput("Unsupported DAMF frame rate: \(value)")
        }
        return frameRate
    }

    private static func sampleRate(from text: String) -> Int? {
        for line in text.split(whereSeparator: { $0.isNewline }) where line.trimmingCharacters(in: .whitespaces).hasPrefix("sampleRate:") {
            return Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func positions(from text: String, sampleRate: Int) -> [Int: [PositionEvent]] {
        var result = [Int: [PositionEvent]]()
        var currentID: Int?
        var currentSample: UInt64 = 0
        var currentPosition: ADMPosition?
        var currentRampLength: UInt64 = 0
        func flush() {
            guard let currentID, let currentPosition else { return }
            result[currentID, default: []].append(PositionEvent(
                sample: currentSample,
                position: currentPosition,
                rampLength: currentRampLength
            ))
        }
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ID:") || line.hasPrefix("ID:") {
                flush()
                let number = line.split(separator: ":", maxSplits: 1)[1]
                currentID = Int(number.trimmingCharacters(in: .whitespaces))
                // DAMF emits samplePos once for a metadata instant and then
                // lists the remaining Object IDs with the same inherited
                // timestamp. Resetting here collapses those updates onto
                // sample zero and destroys the original frame trajectory.
                currentPosition = nil
                currentRampLength = 0
            } else if line.hasPrefix("samplePos:") {
                currentSample = UInt64(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("pos:") {
                let values = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if values.count == 3 {
                    currentPosition = ADMPosition(x: values[0], y: values[1], z: values[2]).clamped()
                }
            } else if line.hasPrefix("rampLength:") {
                currentRampLength = UInt64(
                    line.split(separator: ":", maxSplits: 1)[1]
                        .trimmingCharacters(in: .whitespaces)
                ) ?? 0
            }
        }
        flush()
        _ = sampleRate
        return result
    }

    private static func makeBlocks(
        _ values: [PositionEvent]
    ) -> [ADMPositionBlock] {
        let sorted = values.sorted { $0.sample < $1.sample }
        guard let first = sorted.first else { return [] }
        var keyframes: [(UInt64, ADMPosition, Bool)] = [
            (first.sample, first.position, false)
        ]
        for event in sorted.dropFirst() {
            if event.rampLength > 0, event.sample <= UInt64.max - event.rampLength {
                let previous = keyframes.last!.1
                if keyframes.last!.0 == event.sample {
                    keyframes[keyframes.count - 1] = (event.sample, previous, true)
                } else {
                    keyframes.append((event.sample, previous, true))
                }
                keyframes.append((event.sample + event.rampLength, event.position, false))
            } else if keyframes.last!.0 == event.sample {
                keyframes[keyframes.count - 1] = (event.sample, event.position, false)
            } else {
                // A zero ramp is an instantaneous state update, followed by a
                // hold until this Object's next event.
                keyframes.append((event.sample, event.position, false))
            }
        }
        return keyframes.enumerated().map { index, item in
            ADMPositionBlock(
                startFrame: item.0,
                endFrame: index + 1 < keyframes.count ? keyframes[index + 1].0 : .max,
                position: item.1,
                interpolatesToNext: item.2
            )
        }
    }
}

enum IABPositionConverter {
    private static let minimumXYCode: UInt64 = 32_767
    private static let maximumCode: UInt64 = 65_535

    static func admPosition(
        iabX: UInt64,
        iabY: UInt64,
        iabZ: UInt64
    ) throws -> ADMPosition {
        guard (minimumXYCode...maximumCode).contains(iabX),
              (minimumXYCode...maximumCode).contains(iabY),
              iabZ <= maximumCode else {
            throw TrueHDError.malformedBitstream(
                "IAB object position is outside the ST 2098-2 coordinate code range"
            )
        }

        // ST 2098-2 uses a [0, 1] unit cube with X increasing left-to-right
        // and Y increasing front-to-rear. The encoder's ADM Cartesian space is
        // [-1, 1], with positive Y toward the front and Z already in [0, 1].
        let relativeX = Double(iabX - minimumXYCode) / 32_768.0
        let relativeY = Double(iabY - minimumXYCode) / 32_768.0
        return ADMPosition(
            x: relativeX * 2 - 1,
            y: 1 - relativeY * 2,
            z: Double(iabZ) / Double(maximumCode)
        )
    }
}

private final class MXFIABReader: TrueHDAudioReader {
    private struct FrameDescriptor {
        let offset: UInt64
        let length: Int
    }

    let format: WaveFormat
    let frameCount: UInt64
    let admXML: Data? = nil
    let admChannelAssignment: Data? = nil
    let admMetadata: ADMMetadata?
    let sourceFrameRate: TrueHDFrameRate?

    private let handle: FileHandle
    private let frames: [FrameDescriptor]
    private let samplesPerFrame: Int
    private let objectChannelByMetaID: [Int: Int]
    private var currentSample: UInt64 = 0
    private var cachedFrameIndex: Int?
    private var cachedSamples: [Int32] = []

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let fileSize = try handle.seekToEnd()
        let essence = try Self.findEssence(handle: handle, fileSize: fileSize)
        var parsedFrames = [FrameDescriptor]()
        var offset = essence.offset
        let end = essence.offset + essence.length
        while offset + 10 <= end {
            let header = try Self.readExactly(handle, offset: offset, count: 5)
            guard header[0] == 1 else { break }
            let preambleLength = Int(Self.u32BE(header, at: 1))
            let iaHeaderOffset = offset + 5 + UInt64(preambleLength)
            guard iaHeaderOffset + 5 <= end else { throw Self.malformed("IAB preamble exceeds essence") }
            let iaHeader = try Self.readExactly(handle, offset: iaHeaderOffset, count: 5)
            guard iaHeader[0] == 2 else { throw Self.malformed("IAB frame tag is not 0x02") }
            let iaLength = Int(Self.u32BE(iaHeader, at: 1))
            let total = 5 + preambleLength + 5 + iaLength
            guard total > 0, offset + UInt64(total) <= end else { throw Self.malformed("IAB frame exceeds essence") }
            parsedFrames.append(FrameDescriptor(offset: offset, length: total))
            offset += UInt64(total)
        }
        guard !parsedFrames.isEmpty else { throw Self.malformed("MXF contains no IAB frames") }

        let first = try Self.readExactly(handle, offset: parsedFrames[0].offset, count: parsedFrames[0].length)
        let firstInfo = try Self.parseFrame(first, collectPCM: false)
        guard firstInfo.sampleRate == 48_000, firstInfo.bitDepth == 24 else {
            throw TrueHDError.unsupportedInput("MXF IAB input must be 48 kHz, 24-bit PCM")
        }
        guard firstInfo.frameRate != nil else { throw Self.malformed("IAB frame rate is unsupported") }
        samplesPerFrame = firstInfo.sampleCount
        frames = parsedFrames
        format = WaveFormat(
            sampleRate: firstInfo.sampleRate,
            channelCount: 128,
            bitsPerSample: 24,
            validBitsPerSample: 24,
            blockAlignment: 128 * 3,
            channelMask: 0,
            isBigEndian: false
        )
        frameCount = UInt64(parsedFrames.count * samplesPerFrame)
        sourceFrameRate = firstInfo.frameRate
        var positions = Array(repeating: [(UInt64, ADMPosition)](), count: 128)
        var presentBedChannelIDs = Set(firstInfo.bedChannelIDs)
        var objectSlotByMetaID = [Int: Int]()
        for (index, frame) in parsedFrames.enumerated() {
            let bytes = try Self.readExactly(handle, offset: frame.offset, count: frame.length)
            let info = try Self.parseFrame(bytes, collectPCM: false)
            presentBedChannelIDs.formUnion(info.bedChannelIDs)
            let sampleStart = UInt64(index * samplesPerFrame)
            for object in info.objects {
                let slot: Int
                if let existing = objectSlotByMetaID[object.metaID] {
                    slot = existing
                } else {
                    slot = objectSlotByMetaID.count
                    guard slot < 118 else {
                        throw Self.malformed("IAB contains more than 118 persistent object tracks")
                    }
                    objectSlotByMetaID[object.metaID] = slot
                }
                let channel = 10 + slot
                for update in object.panUpdates {
                    let updateFrame = sampleStart + UInt64(update.sampleOffset)
                    if positions[channel].last?.1 != update.position {
                        positions[channel].append((updateFrame, update.position))
                    }
                }
            }
        }
        objectChannelByMetaID = objectSlotByMetaID.mapValues { 10 + $0 }
        var channels = [ADMChannelMetadata]()
        let bedIDs = [
            "AC_00011001", "AC_00011002", "AC_00011003", "AC_00011004",
            "AC_00011005", "AC_00011006", "AC_00011007", "AC_00011008",
            "AC_00011009", "AC_0001100a"
        ]
        let iabBedChannelIDs = [0, 4, 2, 0xD, 5, 9, 7, 8, 0xB, 0xC]
        for index in 0..<128 {
            channels.append(ADMChannelMetadata(
                channelFormatID: index < bedIDs.count
                    ? bedIDs[index]
                    : String(format: "AC_0003%04x", index - 9),
                isObject: index >= bedIDs.count,
                // PanInfoExists=0 explicitly retains the preceding IAB state;
                // only transmitted sub-blocks create new position keyframes.
                blocks: Self.makeBlocks(positions[index]),
                isPresent: index < bedIDs.count
                    ? presentBedChannelIDs.contains(iabBedChannelIDs[index])
                    : index < bedIDs.count + objectSlotByMetaID.count
            ))
        }
        admMetadata = ADMMetadata(channels: channels, programmeStartSeconds: 3_600)
    }

    deinit { try? handle.close() }

    func readFrames(maxCount: Int) throws -> PCMFrameBlock {
        precondition(maxCount > 0)
        guard currentSample < frameCount else { return PCMFrameBlock(samples: [], frameCount: 0) }
        let requested = Int(min(UInt64(maxCount), frameCount - currentSample))
        var output = [Int32]()
        output.reserveCapacity(requested * format.channelCount)
        var remaining = requested
        while remaining > 0 {
            let frameIndex = Int(currentSample / UInt64(samplesPerFrame))
            let offsetInFrame = Int(currentSample % UInt64(samplesPerFrame))
            if cachedFrameIndex != frameIndex {
                let descriptor = frames[frameIndex]
                let bytes = try Self.readExactly(handle, offset: descriptor.offset, count: descriptor.length)
                let info = try Self.parseFrame(bytes, collectPCM: true)
                cachedSamples = try Self.interleavedSamples(
                    from: info,
                    objectChannelByMetaID: objectChannelByMetaID
                )
                cachedFrameIndex = frameIndex
            }
            let take = min(remaining, samplesPerFrame - offsetInFrame)
            let start = offsetInFrame * format.channelCount
            output.append(contentsOf: cachedSamples[start..<(start + take * format.channelCount)])
            currentSample += UInt64(take)
            remaining -= take
        }
        return PCMFrameBlock(samples: output, frameCount: requested)
    }

    func seek(toFrame frame: UInt64) throws {
        guard frame <= frameCount else {
            throw TrueHDError.invalidConfiguration("Input start frame is beyond the end of the MXF IAB file")
        }
        currentSample = frame
        cachedFrameIndex = nil
        cachedSamples.removeAll(keepingCapacity: true)
    }

    private struct FrameInfo {
        let sampleRate: Int
        let bitDepth: Int
        let sampleCount: Int
        let frameRate: TrueHDFrameRate?
        let samples: [Int: [Int32]]
        let objects: [IABObject]
        let bedMap: [(channelID: Int, audioID: Int, gain: Double)]

        var bedChannelIDs: [Int] { bedMap.map(\.channelID) }
    }

    private struct IABPanUpdate {
        let sampleOffset: Int
        let position: ADMPosition
        let gain: Double
    }

    private struct IABObject {
        let metaID: Int
        let audioID: Int
        let panUpdates: [IABPanUpdate]
    }

    private struct IABBitReader {
        let data: Data
        var bitOffset: Int = 0

        mutating func read(_ count: Int) throws -> UInt64 {
            guard count >= 0, bitOffset + count <= data.count * 8 else { throw MXFIABReader.malformed("IAB bitstream is truncated") }
            var value: UInt64 = 0
            for _ in 0..<count {
                value = (value << 1) | UInt64((data[bitOffset / 8] >> (7 - bitOffset % 8)) & 1)
                bitOffset += 1
            }
            return value
        }

        mutating func align() { bitOffset = (bitOffset + 7) / 8 * 8 }

        mutating func plex(_ base: Int) throws -> Int {
            var width = base
            var value = try read(width)
            while true {
                let escape = width == 64 ? UInt64.max : (UInt64(1) << UInt64(width)) - 1
                guard value == escape else { return Int(value) }
                width *= 2
                guard width <= 32 else { throw MXFIABReader.malformed("IAB Plex field is too large") }
                value = try read(width)
            }
        }

        var byteOffset: Int { bitOffset / 8 }
    }

    private static func parseFrame(_ frame: Data, collectPCM: Bool) throws -> FrameInfo {
        guard frame.count >= 10, frame[0] == 1 else { throw malformed("IAB frame is truncated") }
        let preambleLength = Int(u32BE(frame, at: 1))
        let iaTagOffset = 5 + preambleLength
        guard iaTagOffset + 5 <= frame.count, frame[iaTagOffset] == 2 else {
            throw malformed("IAB frame tag is invalid")
        }
        let iaLength = Int(u32BE(frame, at: iaTagOffset + 1))
        let iaStart = iaTagOffset + 5
        guard iaStart + iaLength <= frame.count, iaLength >= 4 else {
            throw malformed("IAB frame payload is truncated")
        }
        let element = frame.subdata(in: iaStart..<iaStart + iaLength)
        var reader = IABBitReader(data: element)
        guard try reader.plex(8) == 0x08 else { throw malformed("IAB IAFrame element is missing") }
        _ = try reader.plex(8)
        let version = Int(try reader.read(8))
        guard version == 1 else { throw malformed("Unsupported IAB version \(version)") }
        let sampleRateCode = Int(try reader.read(2))
        let bitDepthCode = Int(try reader.read(2))
        let frameRateCode = Int(try reader.read(4))
        let sampleRate = sampleRateCode == 0 ? 48_000 : sampleRateCode == 1 ? 96_000 : 0
        let bitDepth = bitDepthCode == 0 ? 16 : bitDepthCode == 1 ? 24 : 0
        let sampleCount = sampleCount(rateCode: frameRateCode, sampleRate: sampleRate)
        guard sampleRate > 0, bitDepth > 0, sampleCount > 0 else {
            throw malformed("Unsupported IAB sample or frame rate")
        }
        _ = try reader.plex(8)
        reader.align()
        let childCount = try reader.plex(8)
        var samplesByID = [Int: [Int32]]()
        var bedMap = [(channelID: Int, audioID: Int, gain: Double)]()
        var objects = [IABObject]()
        for _ in 0..<childCount {
            let elementID = try reader.plex(8)
            let elementSize = try reader.plex(8)
            let payloadStart = reader.byteOffset
            let payloadEnd = payloadStart + elementSize
            guard payloadEnd <= element.count else { throw malformed("IAB child exceeds IAFrame") }
            let payload = element.subdata(in: payloadStart..<payloadEnd)
            reader.bitOffset = payloadEnd * 8
            switch elementID {
            case 0x10:
                bedMap.append(contentsOf: try parseBed(payload))
            case 0x40:
                objects.append(
                    try parseObject(
                        payload,
                        frameRateCode: frameRateCode,
                        sampleRate: sampleRate
                    )
                )
            case 0x400:
                if collectPCM {
                    let (audioID, samples) = try parsePCM(payload, sampleCount: sampleCount, bitDepth: bitDepth)
                    samplesByID[audioID] = samples
                }
            case 0x200:
                throw TrueHDError.unsupportedInput("MXF IAB uses DLC audio; native reader currently accepts PCM IAB only")
            default:
                break
            }
        }
        return FrameInfo(
            sampleRate: sampleRate, bitDepth: bitDepth, sampleCount: sampleCount,
            frameRate: frameRate(from: frameRateCode), samples: collectPCM ? samplesByID : [:],
            objects: objects, bedMap: bedMap
        )
    }

    private static func interleavedSamples(
        from info: FrameInfo,
        objectChannelByMetaID: [Int: Int]
    ) throws -> [Int32] {
        var output = [Int32](repeating: 0, count: info.sampleCount * 128)
        let bedIndexByChannelID: [Int: Int] = [
            0: 0, 4: 1, 2: 2, 0xD: 3, 5: 4,
            9: 5, 7: 6, 8: 7, 0xB: 8, 0xC: 9
        ]
        for item in info.bedMap {
            guard let channel = bedIndexByChannelID[item.channelID],
                  let source = info.samples[item.audioID] else { continue }
            copy(
                source: source, to: &output, channel: channel,
                sampleCount: info.sampleCount, gain: item.gain
            )
        }
        for object in info.objects {
            guard let channel = objectChannelByMetaID[object.metaID],
                  let source = info.samples[object.audioID] else { continue }
            copy(
                source: source, to: &output, channel: channel,
                sampleCount: info.sampleCount, panUpdates: object.panUpdates
            )
        }
        return output
    }

    private static func parseBed(
        _ payload: Data
    ) throws -> [(channelID: Int, audioID: Int, gain: Double)] {
        var r = IABBitReader(data: payload)
        _ = try r.plex(8)
        let conditional = try r.read(1)
        if conditional == 1 { _ = try r.read(8) }
        let count = try r.plex(4)
        var result = [(Int, Int, Double)]()
        for _ in 0..<count {
            let channel = try r.plex(4)
            let audio = try r.plex(8)
            let gainPrefix = try r.read(2)
            let gainCode = gainPrefix > 1 ? try r.read(10) : nil
            if try r.read(1) == 1 {
                _ = try r.read(4)
                let prefix = try r.read(2)
                if prefix > 1 { _ = try r.read(8) }
            }
            result.append((channel, audio, gain(prefix: gainPrefix, code: gainCode)))
        }
        return result
    }

    private static func parseObject(
        _ payload: Data,
        frameRateCode: Int,
        sampleRate: Int
    ) throws -> IABObject {
        var r = IABBitReader(data: payload)
        let metaID = try r.plex(8)
        let audioID = try r.plex(8)
        let conditional = try r.read(1)
        if conditional == 1 { _ = try r.read(1); _ = try r.read(8) }
        _ = try r.read(1)
        let panBlocks = panBlockCount(frameRateCode)
        let sampleOffsets = panSubBlockOffsets(
            frameRateCode: frameRateCode,
            sampleRate: sampleRate
        )
        var updates = [IABPanUpdate]()
        for block in 0..<panBlocks {
            let exists = block == 0 ? 1 : Int(try r.read(1))
            if exists == 0 { continue }
            let gainPrefix = try r.read(2)
            let gainCode = gainPrefix > 1 ? try r.read(10) : nil
            _ = try r.read(3)
            let x = try r.read(16)
            let y = try r.read(16)
            let z = try r.read(16)
            updates.append(
                IABPanUpdate(
                    sampleOffset: sampleOffsets[block],
                    position: try IABPositionConverter.admPosition(
                        iabX: x, iabY: y, iabZ: z
                    ),
                    gain: gain(prefix: gainPrefix, code: gainCode)
                )
            )
            if try r.read(1) == 1 {
                if try r.read(1) == 1 { _ = try r.read(12) }
                _ = try r.read(1)
            }
            if try r.read(1) == 1 {
                for _ in 0..<9 {
                    let prefix = try r.read(2)
                    if prefix > 1 { _ = try r.read(10) }
                }
            }
            let spread = try r.read(2)
            if spread == 1 { _ = try r.read(8) }
            else if spread == 2 { _ = try r.read(12) }
            else if spread == 3 { _ = try r.read(36) }
            _ = try r.read(4)
            let decor = try r.read(2)
            if decor > 1 { _ = try r.read(8) }
        }
        return IABObject(metaID: metaID, audioID: audioID, panUpdates: updates)
    }

    private static func parsePCM(_ payload: Data, sampleCount: Int, bitDepth: Int) throws -> (Int, [Int32]) {
        var r = IABBitReader(data: payload)
        let audioID = try r.plex(8)
        var values = [Int32]()
        values.reserveCapacity(sampleCount)
        let bytesPerSample = bitDepth / 8
        let start = r.byteOffset
        guard start + sampleCount * bytesPerSample <= payload.count else {
            throw malformed("IAB PCM element is shorter than its declared sample count")
        }
        for index in 0..<sampleCount {
            let offset = start + index * bytesPerSample
            if bitDepth == 24 {
                var raw = UInt32(payload[offset])
                    | UInt32(payload[offset + 1]) << 8
                    | UInt32(payload[offset + 2]) << 16
                if raw & 0x0080_0000 != 0 { raw |= 0xFF00_0000 }
                values.append(Int32(bitPattern: raw))
            } else {
                let raw = UInt16(payload[offset]) | UInt16(payload[offset + 1]) << 8
                values.append(Int32(Int16(bitPattern: raw)) << 8)
            }
        }
        return (audioID, values)
    }

    private static func copy(
        source: [Int32],
        to output: inout [Int32],
        channel: Int,
        sampleCount: Int,
        gain: Double
    ) {
        let count = min(source.count, sampleCount)
        for index in 0..<count {
            output[index * 128 + channel] = scaled(source[index], by: gain)
        }
    }

    private static func copy(
        source: [Int32],
        to output: inout [Int32],
        channel: Int,
        sampleCount: Int,
        panUpdates: [IABPanUpdate]
    ) {
        let count = min(source.count, sampleCount)
        var updateIndex = 0
        var currentGain = panUpdates.first?.gain ?? 1
        for index in 0..<count {
            while updateIndex + 1 < panUpdates.count,
                  panUpdates[updateIndex + 1].sampleOffset <= index {
                updateIndex += 1
                currentGain = panUpdates[updateIndex].gain
            }
            output[index * 128 + channel] = scaled(source[index], by: currentGain)
        }
    }

    private static func sampleCount(rateCode: Int, sampleRate: Int) -> Int {
        let values = [2_000, 1_920, 1_600, 1_000, 960, 800, 500, 480, 400, 2_002]
        guard (0..<values.count).contains(rateCode) else { return 0 }
        return sampleRate == 96_000 ? values[rateCode] * 2 : values[rateCode]
    }

    private static func panBlockCount(_ rateCode: Int) -> Int {
        switch rateCode { case 0...2: return 8; case 3...5: return 4; default: return 2 }
    }

    private static func panSubBlockOffsets(
        frameRateCode: Int,
        sampleRate: Int
    ) -> [Int] {
        let sizes48: [Int]
        switch frameRateCode {
        case 0: sizes48 = Array(repeating: 250, count: 8)
        case 1: sizes48 = Array(repeating: 240, count: 8)
        case 2: sizes48 = Array(repeating: 200, count: 8)
        case 3: sizes48 = Array(repeating: 250, count: 4)
        case 4: sizes48 = Array(repeating: 240, count: 4)
        case 5: sizes48 = Array(repeating: 200, count: 4)
        case 6: sizes48 = Array(repeating: 250, count: 2)
        case 7: sizes48 = Array(repeating: 240, count: 2)
        case 8: sizes48 = Array(repeating: 200, count: 2)
        case 9: sizes48 = [251, 250, 250, 250, 251, 250, 250, 250]
        default: return [0]
        }
        let scale = sampleRate / 48_000
        var offset = 0
        return sizes48.map { size in
            defer { offset += size * scale }
            return offset
        }
    }

    private static func frameRate(from code: Int) -> TrueHDFrameRate? {
        switch code {
        case 0: return .fps24
        case 1: return .fps25
        case 2: return .fps30
        case 3: return .fps48
        case 4: return .fps50
        case 5: return .fps60
        case 9: return .fps23976
        default: return nil
        }
    }

    private static func gain(prefix: UInt64, code: UInt64?) -> Double {
        switch prefix {
        case 0: return 1
        case 1: return 0
        case 2:
            guard let code, code != 0x3FF else { return 0 }
            return pow(2, -Double(code) / 64)
        default: return 0
        }
    }

    private static func scaled(_ sample: Int32, by gain: Double) -> Int32 {
        guard gain != 1 else { return sample }
        let value = (Double(sample) * gain).rounded()
        return Int32(max(Double(Int32.min), min(Double(Int32.max), value)))
    }

    private static func makeBlocks(
        _ values: [(UInt64, ADMPosition)],
        interpolate: Bool = false
    ) -> [ADMPositionBlock] {
        let sorted = values.sorted { $0.0 < $1.0 }
        return sorted.enumerated().map { index, item in
            ADMPositionBlock(
                startFrame: item.0,
                endFrame: index + 1 < sorted.count ? sorted[index + 1].0 : .max,
                position: item.1,
                interpolatesToNext: interpolate
            )
        }
    }

    private static func findEssence(handle: FileHandle, fileSize: UInt64) throws -> (offset: UInt64, length: UInt64) {
        let key = Data([0x06, 0x0E, 0x2B, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x16, 0x01, 0x0D, 0x01])
        var offset: UInt64 = 0
        while offset + 17 <= fileSize {
            let candidate = try readExactly(handle, offset: offset, count: 16)
            let firstLength = try readExactly(handle, offset: offset + 16, count: 1)[0]
            let lengthBytes: Int
            let value: UInt64
            if firstLength & 0x80 == 0 {
                lengthBytes = 1; value = UInt64(firstLength)
            } else {
                lengthBytes = Int(firstLength & 0x7F)
                guard lengthBytes > 0, lengthBytes <= 8, offset + 17 + UInt64(lengthBytes) <= fileSize else { break }
                let encoded = try readExactly(handle, offset: offset + 17, count: lengthBytes)
                var parsed: UInt64 = 0
                for byte in encoded { parsed = (parsed << 8) | UInt64(byte) }
                value = parsed
            }
            let valueOffset = offset + 17 + UInt64(lengthBytes)
            guard valueOffset <= fileSize, value <= fileSize - valueOffset else { break }
            if candidate == key {
                return (valueOffset, value)
            }
            offset = valueOffset + value
        }
        throw TrueHDError.unsupportedInput("MXF contains no IMF IAB essence KLV")
    }

    private static func readExactly(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw malformed("Unexpected end of MXF")
        }
        return data
    }

    private static func u32BE(_ bytes: Data, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func malformed(_ message: String) -> TrueHDError {
        .malformedBitstream(message)
    }
}
