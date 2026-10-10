// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research

import XCTest
@testable import libtruehda

final class MLPChecksumTests: XCTestCase {
    func testChecksum16AgainstAtmosMajorSync() {
        let majorSync: [UInt8] = [
            0xF8, 0x72, 0x6F, 0xBA, 0x00, 0x17, 0x80, 0x4F,
            0xB7, 0x52, 0x10, 0x00, 0x00, 0x00, 0x8B, 0xCC,
            0x43, 0xFC, 0x02, 0x00, 0x3A, 0xED, 0xE3, 0x05,
            0xE3, 0x01, 0x1B, 0xC6, 0xFC, 0x00, 0x46, 0x58,
        ]

        XCTAssertEqual(MLPChecksums.checksum16(majorSync.dropLast(2)), 0x5846)
    }

    func testBitWriterUsesMostSignificantBitOrder() {
        var writer = BitWriter()
        writer.write(0b101, count: 3)
        writer.write(0b00111, count: 5)
        writer.write(0xABCD, count: 16)
        writer.flush()
        XCTAssertEqual(writer.bytes, [0xA7, 0xAB, 0xCD])
    }
}
