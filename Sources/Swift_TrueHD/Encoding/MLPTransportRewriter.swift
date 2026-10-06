// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Rewrites provisional MLP access headers with the final transport schedule
// and peak declaration. Atmos Evolution authentication is renewed whenever
// its authenticated access-unit prefix changes.

import Foundation

enum MLPTransportRewriter {
    private static let targetChunkByteCount = 4 * 1_024 * 1_024

    static func rewrite(
        outputURL: URL,
        records: [MLPAccessUnitRecord],
        plan: MLPTransportPlan,
        majorSync: [UInt8],
        substreamCount: Int,
        authenticateEvolution: Bool
    ) throws {
        guard records.count == plan.inputTimings.count,
              !records.isEmpty,
              substreamCount > 0 else {
            throw TrueHDError.malformedBitstream(
                "Transport rewrite records do not match the timing plan"
            )
        }

        let output = try FileHandle(forUpdating: outputURL)
        defer { try? output.close() }
        var firstRecord = 0

        while firstRecord < records.count {
            let chunkOffset = records[firstRecord].offset
            var endRecord = firstRecord
            var chunkEnd = chunkOffset
            repeat {
                let record = records[endRecord]
                guard record.offset == chunkEnd, record.byteCount >= 4 else {
                    throw TrueHDError.malformedBitstream(
                        "Access-unit records are not contiguous"
                    )
                }
                chunkEnd = record.offset + UInt64(record.byteCount)
                endRecord += 1
            } while endRecord < records.count
                && Int(chunkEnd - chunkOffset) < targetChunkByteCount

            let chunkByteCount = Int(chunkEnd - chunkOffset)
            try output.seek(toOffset: chunkOffset)
            var bytes = [UInt8](try readExactly(output, count: chunkByteCount))

            for recordIndex in firstRecord..<endRecord {
                let record = records[recordIndex]
                let base = Int(record.offset - chunkOffset)
                try rewriteAccessUnit(
                    in: &bytes,
                    base: base,
                    byteCount: record.byteCount,
                    inputTiming: plan.inputTimings[recordIndex],
                    majorSync: majorSync,
                    substreamCount: substreamCount,
                    authenticateEvolution: authenticateEvolution
                )
            }

            try output.seek(toOffset: chunkOffset)
            try output.write(contentsOf: Data(bytes))
            firstRecord = endRecord
        }
        try output.synchronize()
    }

    private static func rewriteAccessUnit(
        in bytes: inout [UInt8],
        base: Int,
        byteCount: Int,
        inputTiming: UInt16,
        majorSync: [UInt8],
        substreamCount: Int,
        authenticateEvolution: Bool
    ) throws {
        guard base >= 0, byteCount >= 4, base + byteCount <= bytes.count else {
            throw TrueHDError.malformedBitstream(
                "Access unit exceeds its transport rewrite chunk"
            )
        }
        let lengthInWords = (Int(bytes[base] & 0x0F) << 8)
            | Int(bytes[base + 1])
        guard lengthInWords * 2 == byteCount else {
            throw TrueHDError.malformedBitstream(
                "Access-unit record length does not match its header"
            )
        }

        bytes[base + 2] = UInt8(inputTiming >> 8)
        bytes[base + 3] = UInt8(truncatingIfNeeded: inputTiming)

        let hasMajorSync = byteCount >= 8
            && bytes[(base + 4)..<(base + 8)].elementsEqual([0xF8, 0x72, 0x6F, 0xBA])
        let directoryOffset: Int
        if hasMajorSync {
            guard byteCount >= 4 + majorSync.count else {
                throw TrueHDError.malformedBitstream(
                    "Major-sync access unit is truncated"
                )
            }
            bytes.replaceSubrange(
                (base + 4)..<(base + 4 + majorSync.count),
                with: majorSync
            )
            directoryOffset = 4 + majorSync.count
        } else {
            directoryOffset = 4
        }

        var directoryEnd = directoryOffset
        var finalSubstreamEnd = 0
        for substream in 0..<substreamCount {
            let entryBase = base + directoryEnd
            guard entryBase + 1 < base + byteCount else {
                throw TrueHDError.malformedBitstream(
                    "Substream directory is truncated"
                )
            }
            let entry = (UInt16(bytes[entryBase]) << 8)
                | UInt16(bytes[entryBase + 1])
            if substream == substreamCount - 1 {
                finalSubstreamEnd = Int(entry & 0x0FFF) * 2
            }
            directoryEnd += entry & 0x8000 == 0 ? 2 : 4
        }
        guard directoryEnd + finalSubstreamEnd <= byteCount else {
            throw TrueHDError.malformedBitstream(
                "Substream directory points beyond the access unit"
            )
        }

        var parity = inputTiming ^ UInt16(lengthInWords)
        for byte in bytes[
            (base + directoryOffset)..<(base + directoryEnd)
        ] {
            parity ^= UInt16(byte)
        }
        parity ^= parity >> 8
        parity ^= parity >> 4
        let accessHeader = (((parity & 0x0F) ^ 0x0F) << 12)
            | UInt16(lengthInWords)
        bytes[base] = UInt8(accessHeader >> 8)
        bytes[base + 1] = UInt8(truncatingIfNeeded: accessHeader)

        let extraDataOffset = directoryEnd + finalSubstreamEnd
        if authenticateEvolution, extraDataOffset < byteCount {
            let prefix = Array(bytes[base..<(base + extraDataOffset)])
            let wrappedEvolution = Array(
                bytes[(base + extraDataOffset)..<(base + byteCount)]
            )
            let authenticated = AtmosMetadataWriter.reauthenticateWrappedEvolution(
                wrappedEvolution,
                accessUnitPrefix: prefix
            )
            guard authenticated.count == wrappedEvolution.count else {
                throw TrueHDError.malformedBitstream(
                    "Evolution authentication changed access-unit length"
                )
            }
            bytes.replaceSubrange(
                (base + extraDataOffset)..<(base + byteCount),
                with: authenticated
            )
        }
    }

    private static func readExactly(
        _ handle: FileHandle,
        count: Int
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count),
                  !part.isEmpty else {
                throw TrueHDError.malformedBitstream(
                    "Encoded output ended during transport rewrite"
                )
            }
            result.append(part)
        }
        return result
    }
}
