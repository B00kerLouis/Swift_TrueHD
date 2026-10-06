// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Minimal most-significant-bit-first writer for deterministic syntax packing.
// Callers retain responsibility for field ranges and byte-alignment rules.

import Foundation

struct BitWriter: Sendable {
    private(set) var bytes: [UInt8]
    private var accumulator: UInt64 = 0
    private var bufferedBitCount = 0
    private(set) var bitCount = 0

    init(reservingCapacity capacity: Int = 0) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    mutating func write(_ value: UInt64, count: Int) {
        precondition((0...32).contains(count))
        guard count > 0 else { return }

        let mask = count == 64 ? UInt64.max : (UInt64(1) << UInt64(count)) - 1
        accumulator = (accumulator << UInt64(count)) | (value & mask)
        bufferedBitCount += count
        bitCount += count

        while bufferedBitCount >= 8 {
            let shift = bufferedBitCount - 8
            bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt64(shift)))
            bufferedBitCount -= 8
            if bufferedBitCount == 0 {
                accumulator = 0
            } else {
                accumulator &= (UInt64(1) << UInt64(bufferedBitCount)) - 1
            }
        }
    }

    mutating func writeSigned(_ value: Int32, count: Int) {
        write(UInt64(UInt32(bitPattern: value)), count: count)
    }

    mutating func align(toMultipleOf alignment: Int) {
        precondition(alignment > 0)
        let padding = (alignment - bitCount % alignment) % alignment
        write(0, count: padding)
    }

    mutating func flush() {
        guard bufferedBitCount > 0 else { return }
        bytes.append(UInt8(truncatingIfNeeded: accumulator << UInt64(8 - bufferedBitCount)))
        accumulator = 0
        bufferedBitCount = 0
    }

    func paddedBytes() -> [UInt8] {
        guard bufferedBitCount > 0 else { return bytes }
        var result = bytes
        result.append(UInt8(truncatingIfNeeded: accumulator << UInt64(8 - bufferedBitCount)))
        return result
    }
}
