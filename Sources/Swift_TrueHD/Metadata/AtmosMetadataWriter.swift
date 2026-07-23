// SPDX-License-Identifier: AGPL-3.0-only
//
// Packs object-audio metadata, protected-section parity, and primary
// authentication bytes for insertion into immersive access units.

import CryptoKit
import Foundation

struct AtmosMetadataUpdate: Sendable {
    let blockOffsetFactor: Int
    let rampDuration: Int
    let positions: [ADMPosition]

    init(blockOffsetFactor: Int, rampDuration: Int, positions: [ADMPosition]) {
        precondition((0...63).contains(blockOffsetFactor))
        precondition((0...2_047).contains(rampDuration))
        precondition(AtmosSpatialCoder.supportedElementCounts.contains(positions.count))
        self.blockOffsetFactor = blockOffsetFactor
        self.rampDuration = rampDuration
        self.positions = positions
    }
}

enum AtmosMetadataWriter {
    struct PendingExtraData {
        fileprivate let oamd: [UInt8]
        fileprivate let canonicalEvolution: [UInt8]

        var byteCount: Int {
            AtmosMetadataWriter.wrapEvolution(canonicalEvolution).count
        }

        func finalize(accessUnitPrefix: [UInt8]) -> [UInt8] {
            let protection = AtmosMetadataWriter.primaryProtection(
                accessUnitPrefix: accessUnitPrefix,
                canonicalEvolution: canonicalEvolution
            )
            let evolution = AtmosMetadataWriter.makeEvolutionFrame(
                oamd: oamd,
                primaryProtection: protection
            )
            precondition(evolution.count == canonicalEvolution.count)
            return AtmosMetadataWriter.wrapEvolution(evolution)
        }
    }

    static func makeExtraData(
        positions: [ADMPosition],
        sampleOffset: Int = 0,
        accessUnitPrefix: [UInt8] = []
    ) -> [UInt8] {
        prepareExtraData(positions: positions, sampleOffset: sampleOffset)
            .finalize(accessUnitPrefix: accessUnitPrefix)
    }

    static func prepareExtraData(
        positions: [ADMPosition],
        sampleOffset: Int = 0
    ) -> PendingExtraData {
        prepareExtraData(
            updates: [
                AtmosMetadataUpdate(
                    blockOffsetFactor: 0,
                    rampDuration: 1_536,
                    positions: positions
                )
            ],
            sampleOffset: sampleOffset
        )
    }

    static func prepareExtraData(
        updates: [AtmosMetadataUpdate],
        sampleOffset: Int = 0
    ) -> PendingExtraData {
        let oamd = makeOAMDPayload(updates: updates, sampleOffset: sampleOffset)
        return PendingExtraData(
            oamd: oamd,
            canonicalEvolution: makeEvolutionFrame(oamd: oamd, primaryProtection: 0)
        )
    }

    private static func wrapEvolution(_ evolution: [UInt8]) -> [UInt8] {
        var protectedBytes = [UInt8](repeating: 0, count: 2)
        let evolutionLength = evolution.count
        precondition(evolutionLength <= 0x0FFF)
        protectedBytes[0] = UInt8((evolutionLength >> 8) & 0x0F)
        protectedBytes[1] = UInt8(evolutionLength & 0xFF)
        protectedBytes.append(contentsOf: evolution)

        // The final protection byte must leave the protected section on a word boundary.
        if (protectedBytes.count + 1) & 1 != 0 {
            protectedBytes.append(0)
        }
        let parity = protectedBytes.reduce(UInt8(0), ^) ^ 0xA9
        protectedBytes.append(parity)

        let extraLengthInWords = protectedBytes.count / 2
        precondition(extraLengthInWords <= 0x0FFF)
        let lengthHigh = UInt8((extraLengthInWords >> 8) & 0x0F)
        let lengthLow = UInt8(extraLengthInWords & 0xFF)
        let checkNibble = (0...15).first { candidate in
            foldedNibble(UInt8(candidate << 4) | lengthHigh, lengthLow) == 0x0F
        }!

        var result = [UInt8(UInt8(checkNibble << 4) | lengthHigh), lengthLow]
        result.append(contentsOf: protectedBytes)
        precondition(result.count & 1 == 0)
        return result
    }

    static func primaryProtection(
        accessUnitPrefix: [UInt8],
        canonicalEvolution: [UInt8]
    ) -> UInt8 {
        let encodedKey: [UInt8] = [
            0x2C, 0x16, 0x95, 0x1C, 0x38, 0x23, 0x20, 0x60,
            0xD8, 0x97, 0x5A, 0xA6, 0xCB, 0xDC, 0x54, 0x81,
            0x31, 0x42, 0xDC, 0x26, 0x9D, 0xCC, 0x5D, 0x43,
            0x76, 0x97, 0x20, 0x6C, 0x93, 0x87, 0x1D, 0xE4,
        ]
        let key = SymmetricKey(data: Data(encodedKey.map { $0 ^ 0x7A }))
        var message = Data(capacity: accessUnitPrefix.count + canonicalEvolution.count)
        message.append(contentsOf: accessUnitPrefix)
        message.append(contentsOf: canonicalEvolution)
        return Array(HMAC<SHA256>.authenticationCode(for: message, using: key))[0]
    }

    /// Re-authenticates an already wrapped Evolution frame after an access-unit
    /// prefix field (for example the declared peak rate in major sync) changes.
    static func reauthenticateWrappedEvolution(
        _ wrappedEvolution: [UInt8],
        accessUnitPrefix: [UInt8]
    ) -> [UInt8] {
        precondition(wrappedEvolution.count >= 6)
        let evolutionLength = (Int(wrappedEvolution[2] & 0x0F) << 8)
            | Int(wrappedEvolution[3])
        precondition(evolutionLength > 0)
        precondition(4 + evolutionLength < wrappedEvolution.count)

        var canonicalEvolution = Array(
            wrappedEvolution[4..<(4 + evolutionLength)]
        )
        var position = 33
        var oamdLength = 0
        while true {
            let group = Int(readBits(canonicalEvolution, at: position, count: 8))
            position += 8
            let continues = readBits(canonicalEvolution, at: position, count: 1) != 0
            position += 1
            oamdLength += group
            if !continues { break }
            oamdLength = (oamdLength + 1) << 8
        }
        position += oamdLength * 8
        position += 5 // end of payload list
        let primaryProtectionLength = readBits(
            canonicalEvolution, at: position, count: 2
        )
        position += 2
        let secondaryProtectionLength = readBits(
            canonicalEvolution, at: position, count: 2
        )
        position += 2
        precondition(primaryProtectionLength == 1)
        precondition(secondaryProtectionLength == 0)
        let protectionBitOffset = position
        writeBits(0, to: &canonicalEvolution, at: protectionBitOffset, count: 8)

        let protection = primaryProtection(
            accessUnitPrefix: accessUnitPrefix,
            canonicalEvolution: canonicalEvolution
        )
        var result = wrappedEvolution
        var authenticatedEvolution = canonicalEvolution
        writeBits(
            UInt64(protection), to: &authenticatedEvolution,
            at: protectionBitOffset, count: 8
        )
        result.replaceSubrange(
            4..<(4 + evolutionLength), with: authenticatedEvolution
        )

        let parityIndex = result.count - 1
        result[parityIndex] = result[2..<parityIndex].reduce(UInt8(0), ^) ^ 0xA9
        return result
    }

    static func makeOAMDPayload(
        positions: [ADMPosition],
        sampleOffset: Int = 0
    ) -> [UInt8] {
        makeOAMDPayload(
            updates: [
                AtmosMetadataUpdate(
                    blockOffsetFactor: 0,
                    rampDuration: 1_536,
                    positions: positions
                )
            ],
            sampleOffset: sampleOffset
        )
    }

    static func makeOAMDPayload(
        updates: [AtmosMetadataUpdate],
        sampleOffset: Int = 0
    ) -> [UInt8] {
        // The native TrueHD OAMD profile carried by this encoder uses one
        // complete Object-info block per 1536-sample metadata frame. The
        // previously guessed multi-block status/update syntax was not accepted
        // by the Dolby decoder and caused the Object render to disappear.
        precondition(updates.count == 1)
        let update = updates[0]
        let firstPositions = update.positions
        precondition((0...39).contains(sampleOffset))

        // sample_offset is limited to 0...31. Values in the final eight
        // samples of a 40-sample access unit are represented by moving every
        // block forward once and keeping the exact residual offset.
        let encodedSampleOffset = sampleOffset & 31
        let accessUnitBlockOffset = sampleOffset >> 5
        precondition(update.blockOffsetFactor + accessUnitBlockOffset <= 63)

        var objectElement = BitWriter(reservingCapacity: 512)
        objectElement.write(0, count: 1) // OA element is required for object rendering
        switch encodedSampleOffset {
        case 0:
            objectElement.write(0, count: 2)
        case 8, 16, 18, 24:
            let indexes = [8: 0, 16: 1, 18: 2, 24: 3]
            objectElement.write(1, count: 2)
            objectElement.write(UInt64(indexes[encodedSampleOffset]!), count: 2)
        default:
            objectElement.write(2, count: 2)
            objectElement.write(UInt64(encodedSampleOffset), count: 5)
        }
        objectElement.write(0, count: 3) // one complete Object-info block
        objectElement.write(
            UInt64(update.blockOffsetFactor + accessUnitBlockOffset),
            count: 6
        )
        writeRampDuration(update.rampDuration, to: &objectElement)
        objectElement.write(1, count: 1) // no reserved object data

        for objectIndex in firstPositions.indices {
            objectElement.write(0, count: 1) // active
            // Code 3 selects the default 0 dB gain for positional signals.
            // The LFE entry has no positional payload and uses code 0.
            objectElement.write(objectIndex == 0 ? 0 : 3, count: 2)
            objectElement.write(1, count: 1) // default priority
            if objectIndex != 0 { // object zero is the LFE bed element
                writePosition(update.positions[objectIndex], to: &objectElement)
                objectElement.write(0, count: 3) // no zone constraint
                objectElement.write(1, count: 1) // elevation enabled
                objectElement.write(0, count: 2) // point object
                objectElement.write(0, count: 1) // no screen reference
                objectElement.write(0, count: 1) // no speaker snap
            }
            objectElement.write(0, count: 1) // no additional table data
        }
        objectElement.align(toMultipleOf: 8)
        objectElement.flush()

        var payload = BitWriter(reservingCapacity: objectElement.bytes.count + 8)
        payload.write(0, count: 2) // OAMD version 0
        payload.write(UInt64(firstPositions.count - 1), count: 5)
        payload.write(1, count: 1) // dynamic-object-only program
        payload.write(1, count: 1) // first element is LFE
        payload.write(0, count: 1) // no alternate object data
        payload.write(1, count: 4) // one OA metadata element
        payload.write(1, count: 4) // Object element
        // For a known Object element, oa_element_size_minus1 describes the
        // Object-element payload itself. There is no discard flag in front of
        // a recognized element. Inserting one shifts the complete OAMD syntax
        // by one bit; the Dolby decoder then rejects every metadata frame and
        // the Object render repeatedly drops out.
        writeVariable(objectElement.bytes.count - 1, groupBits: 4, to: &payload)
        for byte in objectElement.bytes {
            payload.write(UInt64(byte), count: 8)
        }
        payload.align(toMultipleOf: 8)
        payload.flush()
        return payload.bytes
    }

    private static func writeRampDuration(
        _ duration: Int,
        to writer: inout BitWriter
    ) {
        switch duration {
        case 0:
            writer.write(0, count: 2)
        case 512:
            writer.write(1, count: 2)
        case 1_536:
            writer.write(2, count: 2)
        default:
            precondition((0...2_047).contains(duration))
            writer.write(3, count: 2)
            writer.write(0, count: 1) // explicit 11-bit duration
            writer.write(UInt64(duration), count: 11)
        }
    }

    private static func makeEvolutionFrame(
        oamd: [UInt8],
        primaryProtection: UInt8
    ) -> [UInt8] {
        var writer = BitWriter(reservingCapacity: oamd.count + 8)
        writer.write(0, count: 2) // EMDF version
        writer.write(0, count: 3) // Select the default OAMD authentication key ID.
        writer.write(11, count: 5) // OAMD payload ID
        writer.write(0, count: 1) // no sample offset
        writer.write(0, count: 1) // no duration
        writer.write(0, count: 1) // no group ID
        writer.write(1, count: 1) // codec data is present
        writer.write(8, count: 8) // frame-aligned OAMD codec configuration
        writer.write(0, count: 1) // OAMD payload must be processed
        writer.write(1, count: 1) // payload is frame aligned
        writer.write(0, count: 1) // do not create a duplicate payload
        writer.write(0, count: 1) // do not remove a duplicate payload
        writer.write(0, count: 5) // highest processing priority
        writer.write(0, count: 2) // processing is unrestricted
        writeVariable(oamd.count, groupBits: 8, to: &writer)
        for byte in oamd {
            writer.write(UInt64(byte), count: 8)
        }
        writer.write(0, count: 5) // end of payload list
        writer.write(1, count: 2) // one-byte primary protection value
        writer.write(0, count: 2) // no secondary protection bytes
        writer.write(UInt64(primaryProtection), count: 8)
        writer.align(toMultipleOf: 8)
        writer.flush()
        return writer.bytes
    }

    private static func writePosition(_ input: ADMPosition, to writer: inout BitWriter) {
        let position = input.clamped()
        let encodedX = Int(((position.x + 1) * 31).rounded()).clamped(to: 0...62)
        let encodedY = Int(((1 - position.y) * 31).rounded()).clamped(to: 0...62)
        let encodedZ = Int((abs(position.z) * 15).rounded()).clamped(to: 0...15)
        writer.write(UInt64(encodedX), count: 6)
        writer.write(UInt64(encodedY), count: 6)
        writer.write(position.z >= 0 ? 1 : 0, count: 1)
        writer.write(UInt64(encodedZ), count: 4)
        writer.write(0, count: 1) // distance is not specified
    }

    private static func writeVariable(
        _ value: Int,
        groupBits: Int,
        to writer: inout BitWriter
    ) {
        precondition(value >= 0)
        let mask = (1 << groupBits) - 1
        var groups = [Int]()
        var remaining = value
        while remaining > mask {
            groups.append(remaining & mask)
            remaining = (remaining >> groupBits) - 1
        }
        groups.append(remaining)
        groups.reverse()
        for (index, group) in groups.enumerated() {
            writer.write(UInt64(group), count: groupBits)
            writer.write(index + 1 < groups.count ? 1 : 0, count: 1)
        }
    }

    private static func foldedNibble(_ first: UInt8, _ second: UInt8) -> UInt8 {
        var parity = first ^ second
        parity ^= parity >> 4
        return parity & 0x0F
    }

    private static func readBits(
        _ bytes: [UInt8], at position: Int, count: Int
    ) -> UInt64 {
        precondition(position >= 0 && count >= 0 && position + count <= bytes.count * 8)
        var value: UInt64 = 0
        for bit in position..<(position + count) {
            value = (value << 1) | UInt64((bytes[bit / 8] >> (7 - bit % 8)) & 1)
        }
        return value
    }

    private static func writeBits(
        _ value: UInt64,
        to bytes: inout [UInt8],
        at position: Int,
        count: Int
    ) {
        precondition(position >= 0 && count >= 0 && position + count <= bytes.count * 8)
        for offset in 0..<count {
            let bit = position + offset
            let mask = UInt8(1 << (7 - bit % 8))
            if (value >> UInt64(count - 1 - offset)) & 1 == 0 {
                bytes[bit / 8] &= ~mask
            } else {
                bytes[bit / 8] |= mask
            }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
