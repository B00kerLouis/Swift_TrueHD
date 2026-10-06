// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Bounds-checked RIFF/RF64 WAVE parsing and integer PCM conversion. Chunk data
// is streamed from the source file instead of being loaded as one allocation.

import Foundation

struct WaveFormat: Sendable, Equatable {
    let sampleRate: Int
    let channelCount: Int
    let bitsPerSample: Int
    let validBitsPerSample: Int
    let blockAlignment: Int
    let channelMask: UInt32
    let isBigEndian: Bool
}

struct PCMFrameBlock: Sendable {
    let samples: [Int32]
    let frameCount: Int
}

protocol TrueHDAudioReader: AnyObject {
    var format: WaveFormat { get }
    var frameCount: UInt64 { get }
    var admXML: Data? { get }
    var admChannelAssignment: Data? { get }
    var admMetadata: ADMMetadata? { get }
    var sourceFrameRate: TrueHDFrameRate? { get }

    func readFrames(maxCount: Int) throws -> PCMFrameBlock
    func seek(toFrame frame: UInt64) throws
}

final class WaveFileReader: TrueHDAudioReader {
    let format: WaveFormat
    let frameCount: UInt64
    let admXML: Data?
    let admChannelAssignment: Data?
    let admMetadata: ADMMetadata? = nil
    let sourceFrameRate: TrueHDFrameRate?

    private let handle: FileHandle
    private let dataOffset: UInt64
    private let dataByteCount: UInt64
    private var currentFrame: UInt64 = 0

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let header = try Self.readExactly(handle, offset: 0, count: 12)
        let container = Self.fourCC(header, at: 0)
        guard container == "RIFF" || container == "RF64" else {
            throw TrueHDError.invalidWaveFile("Expected a RIFF or RF64 WAVE file")
        }
        guard Self.fourCC(header, at: 8) == "WAVE" else {
            throw TrueHDError.invalidWaveFile("RIFF file is not WAVE audio")
        }

        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 12
        var rf64DataSize: UInt64?
        var parsedFormat: WaveFormat?
        var parsedDataOffset: UInt64?
        var parsedDataSize: UInt64?
        var parsedADMXML: Data?
        var parsedADMChannelAssignment: Data?
        var parsedDBMD: Data?

        while offset + 8 <= fileSize {
            let chunkHeader = try Self.readExactly(handle, offset: offset, count: 8)
            let chunkID = Self.fourCC(chunkHeader, at: 0)
            let size32 = Self.u32LE(chunkHeader, at: 4)
            let payloadOffset = offset + 8
            var chunkSize = UInt64(size32)

            if chunkID == "ds64" {
                let ds64 = try Self.readExactly(handle, offset: payloadOffset, count: Int(min(chunkSize, 28)))
                guard ds64.count >= 16 else {
                    throw TrueHDError.invalidWaveFile("RF64 ds64 chunk is truncated")
                }
                rf64DataSize = Self.u64LE(ds64, at: 8)
            } else if chunkID == "fmt " {
                let bytes = try Self.readExactly(handle, offset: payloadOffset, count: Int(chunkSize))
                parsedFormat = try Self.parseFormat(bytes)
            } else if chunkID == "data" {
                if size32 == UInt32.max, let rf64DataSize {
                    chunkSize = rf64DataSize
                }
                parsedDataOffset = payloadOffset
                parsedDataSize = min(chunkSize, fileSize - payloadOffset)
            } else if chunkID == "axml" {
                guard chunkSize <= 64 * 1_024 * 1_024 else {
                    throw TrueHDError.invalidWaveFile("ADM axml chunk is unexpectedly large")
                }
                parsedADMXML = try Self.readExactly(handle, offset: payloadOffset, count: Int(chunkSize))
            } else if chunkID == "chna" {
                guard chunkSize <= 1_024 * 1_024 else {
                    throw TrueHDError.invalidWaveFile("ADM chna chunk is unexpectedly large")
                }
                parsedADMChannelAssignment = try Self.readExactly(
                    handle,
                    offset: payloadOffset,
                    count: Int(chunkSize)
                )
            } else if chunkID == "dbmd" {
                guard chunkSize <= 1_024 * 1_024 else {
                    throw TrueHDError.invalidWaveFile("Dolby metadata chunk is unexpectedly large")
                }
                parsedDBMD = try Self.readExactly(handle, offset: payloadOffset, count: Int(chunkSize))
            }

            let paddedSize = chunkSize + (chunkSize & 1)
            guard payloadOffset <= UInt64.max - paddedSize else {
                throw TrueHDError.invalidWaveFile("WAVE chunk size overflows the file address space")
            }
            offset = payloadOffset + paddedSize
        }

        guard let parsedFormat else {
            throw TrueHDError.invalidWaveFile("WAVE file has no fmt chunk")
        }
        guard let parsedDataOffset, let parsedDataSize else {
            throw TrueHDError.invalidWaveFile("WAVE file has no data chunk")
        }
        guard parsedFormat.blockAlignment > 0 else {
            throw TrueHDError.invalidWaveFile("WAVE block alignment is zero")
        }

        format = parsedFormat
        dataOffset = parsedDataOffset
        dataByteCount = parsedDataSize
        frameCount = parsedDataSize / UInt64(parsedFormat.blockAlignment)
        admXML = parsedADMXML
        admChannelAssignment = parsedADMChannelAssignment
        sourceFrameRate = parsedDBMD.flatMap(TrueHDFrameRate.fromDBMD)
    }

    deinit {
        try? handle.close()
    }

    func readFrames(maxCount: Int) throws -> PCMFrameBlock {
        precondition(maxCount > 0)
        let remaining = frameCount - currentFrame
        let requested = Int(min(UInt64(maxCount), remaining))
        guard requested > 0 else {
            return PCMFrameBlock(samples: [], frameCount: 0)
        }

        let byteCount = requested * format.blockAlignment
        let offset = dataOffset + currentFrame * UInt64(format.blockAlignment)
        let bytes = try Self.readExactly(handle, offset: offset, count: byteCount)
        var samples = [Int32]()
        samples.reserveCapacity(requested * format.channelCount)

        let bytesPerSample = format.bitsPerSample / 8
        for frame in 0..<requested {
            let frameOffset = frame * format.blockAlignment
            for channel in 0..<format.channelCount {
                let sampleOffset = frameOffset + channel * bytesPerSample
                samples.append(try decodeSample(bytes, at: sampleOffset))
            }
        }
        currentFrame += UInt64(requested)
        return PCMFrameBlock(samples: samples, frameCount: requested)
    }

    func seek(toFrame frame: UInt64) throws {
        guard frame <= frameCount else {
            throw TrueHDError.invalidConfiguration("Input start frame is beyond the end of the WAVE file")
        }
        currentFrame = frame
    }

    private func decodeSample(_ bytes: Data, at offset: Int) throws -> Int32 {
        switch format.bitsPerSample {
        case 16:
            let raw = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            return Int32(Int16(bitPattern: raw)) << 8
        case 24:
            var raw = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
            if raw & 0x0080_0000 != 0 {
                raw |= 0xFF00_0000
            }
            return Int32(bitPattern: raw)
        case 32:
            let raw = Self.u32LE(bytes, at: offset)
            let value = Int32(bitPattern: raw)
            let shift = max(0, format.bitsPerSample - min(format.validBitsPerSample, 24))
            return value >> Int32(shift)
        default:
            throw TrueHDError.unsupportedInput(
                "Only 16-, 24-, and 32-bit integer PCM WAVE files are supported"
            )
        }
    }

    private static func parseFormat(_ bytes: Data) throws -> WaveFormat {
        guard bytes.count >= 16 else {
            throw TrueHDError.invalidWaveFile("WAVE fmt chunk is truncated")
        }
        let formatTag = u16LE(bytes, at: 0)
        let channelCount = Int(u16LE(bytes, at: 2))
        let sampleRate = Int(u32LE(bytes, at: 4))
        let blockAlignment = Int(u16LE(bytes, at: 12))
        let bitsPerSample = Int(u16LE(bytes, at: 14))
        var validBits = bitsPerSample
        var channelMask: UInt32 = 0
        var effectiveTag = formatTag

        if formatTag == 0xFFFE {
            guard bytes.count >= 40 else {
                throw TrueHDError.invalidWaveFile("WAVE extensible fmt chunk is truncated")
            }
            validBits = Int(u16LE(bytes, at: 18))
            channelMask = u32LE(bytes, at: 20)
            effectiveTag = u16LE(bytes, at: 24)
        }
        guard effectiveTag == 1 else {
            throw TrueHDError.unsupportedInput("Only integer PCM WAVE input is supported")
        }
        guard channelCount > 0, sampleRate > 0 else {
            throw TrueHDError.invalidWaveFile("WAVE channel count or sample rate is invalid")
        }
        guard bitsPerSample % 8 == 0 else {
            throw TrueHDError.unsupportedInput("Packed non-byte-aligned PCM is not supported")
        }
        guard blockAlignment >= channelCount * (bitsPerSample / 8) else {
            throw TrueHDError.invalidWaveFile("WAVE block alignment is smaller than one PCM frame")
        }
        return WaveFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitsPerSample: bitsPerSample,
            validBitsPerSample: validBits,
            blockAlignment: blockAlignment,
            channelMask: channelMask,
            isBigEndian: false
        )
    }

    private static func readExactly(
        _ handle: FileHandle,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw TrueHDError.invalidWaveFile("Unexpected end of WAVE file")
        }
        return data
    }

    private static func fourCC(_ bytes: Data, at offset: Int) -> String {
        String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }

    private static func u16LE(_ bytes: Data, at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32LE(_ bytes: Data, at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func u64LE(_ bytes: Data, at offset: Int) -> UInt64 {
        UInt64(u32LE(bytes, at: offset)) | UInt64(u32LE(bytes, at: offset + 4)) << 32
    }
}
