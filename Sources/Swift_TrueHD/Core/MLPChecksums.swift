// SPDX-License-Identifier: AGPL-3.0-only
//
// Checksum and parity primitives used while assembling access units and
// protected metadata sections. All arithmetic is intentionally width-bounded.

import Foundation

enum MLPChecksums {
    private static let crc63 = makeTable(bits: 8, polynomial: 0x63)
    private static let crc2D = makeTable(bits: 16, polynomial: 0x002D)
    private static let crc1D = makeTable(bits: 8, polynomial: 0x1D)

    static func checksum8(_ bytes: some Collection<UInt8>) -> UInt8 {
        let input = Array(bytes)
        precondition(!input.isEmpty)
        let crc = update(table: crc63, initial: 0x3C, bytes: input.dropLast())
        return UInt8(truncatingIfNeeded: crc) ^ input[input.count - 1]
    }

    static func checksum16(_ bytes: some Collection<UInt8>) -> UInt16 {
        let input = Array(bytes)
        precondition(input.count >= 2)
        let crc = update(table: crc2D, initial: 0, bytes: input.dropLast(2))
        let tail = UInt16(input[input.count - 2]) | UInt16(input[input.count - 1]) << 8
        return UInt16(truncatingIfNeeded: crc) ^ tail
    }

    static func restartChecksum(bytes: [UInt8], bitCount: Int) -> UInt8 {
        precondition(bitCount >= 0)
        let byteCount = (bitCount + 2) / 8
        precondition(bytes.count > byteCount)

        var crc: UInt32
        if byteCount > 1 {
            crc = update(
                table: crc1D,
                initial: UInt32(bytes[0] & 0xC0),
                bytes: bytes[0..<(byteCount - 1)]
            )
        } else {
            crc = UInt32(bytes[0] & 0xC0)
        }
        crc ^= UInt32(bytes[byteCount - 1])

        for index in 0..<((bitCount + 2) & 7) {
            crc <<= 1
            if crc & 0x100 != 0 {
                crc ^= 0x11D
            }
            crc ^= UInt32((bytes[byteCount] >> UInt8(7 - index)) & 1)
        }
        return UInt8(truncatingIfNeeded: crc)
    }

    static func parity(_ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(0, ^)
    }

    private static func update<C: Collection>(
        table: [UInt32],
        initial: UInt32,
        bytes: C
    ) -> UInt32 where C.Element == UInt8 {
        var crc = initial
        for byte in bytes {
            crc = table[Int(UInt8(truncatingIfNeeded: crc) ^ byte)] ^ (crc >> 8)
        }
        return crc
    }

    private static func makeTable(bits: Int, polynomial: UInt32) -> [UInt32] {
        (0..<256).map { index in
            var value = UInt32(index) << 24
            for _ in 0..<8 {
                let feedback = (value & 0x8000_0000) != 0
                value <<= 1
                if feedback {
                    value ^= polynomial << UInt32(32 - bits)
                }
            }
            return value.byteSwapped
        }
    }
}
