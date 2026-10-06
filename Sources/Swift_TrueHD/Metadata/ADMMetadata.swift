// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Parses ADM/CHNA programme structure and converts cartesian or polar positions
// into the normalized coordinates consumed by the spatial coder.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct ADMPosition: Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let centre = ADMPosition(x: 0, y: 0, z: 0)

    func clamped() -> ADMPosition {
        ADMPosition(
            x: min(1, max(-1, x)),
            y: min(1, max(-1, y)),
            z: min(1, max(-1, z))
        )
    }
}

struct ADMPositionBlock: Sendable, Equatable {
    let startFrame: UInt64
    let endFrame: UInt64
    let position: ADMPosition
    /// DAMF/IAB position events describe a trajectory between two updates.
    /// ADM XML blocks retain their historical hold semantics unless this flag
    /// is explicitly enabled by the native reader.
    let interpolatesToNext: Bool

    init(
        startFrame: UInt64,
        endFrame: UInt64,
        position: ADMPosition,
        interpolatesToNext: Bool = false
    ) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.position = position
        self.interpolatesToNext = interpolatesToNext
    }
}

struct ADMChannelMetadata: Sendable, Equatable {
    let channelFormatID: String
    let isObject: Bool
    let blocks: [ADMPositionBlock]
    let isPresent: Bool

    init(
        channelFormatID: String,
        isObject: Bool,
        blocks: [ADMPositionBlock],
        isPresent: Bool = true
    ) {
        self.channelFormatID = channelFormatID
        self.isObject = isObject
        self.blocks = blocks
        self.isPresent = isPresent
    }

    func position(at frame: UInt64) -> ADMPosition {
        guard !blocks.isEmpty else { return .centre }
        var lower = 0
        var upper = blocks.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if blocks[middle].startFrame <= frame {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let index = max(0, lower - 1)
        guard index + 1 < blocks.count,
              blocks[index].interpolatesToNext,
              blocks[index + 1].startFrame > blocks[index].startFrame,
              frame < blocks[index + 1].startFrame else {
            return blocks[index].position
        }
        let start = blocks[index].startFrame
        let end = blocks[index + 1].startFrame
        let fraction = Double(frame - start) / Double(end - start)
        let from = blocks[index].position
        let to = blocks[index + 1].position
        return ADMPosition(
            x: from.x + (to.x - from.x) * fraction,
            y: from.y + (to.y - from.y) * fraction,
            z: from.z + (to.z - from.z) * fraction
        ).clamped()
    }
}

struct ADMMetadata: Sendable {
    let channels: [ADMChannelMetadata]
    let programmeStartSeconds: Double?

    init(channels: [ADMChannelMetadata], programmeStartSeconds: Double? = nil) {
        self.channels = channels
        self.programmeStartSeconds = programmeStartSeconds
    }

    static func parse(
        xml: Data,
        channelAssignment: Data,
        channelCount: Int,
        sampleRate: Int
    ) throws -> ADMMetadata {
        let delegate = ADMXMLDelegate(sampleRate: sampleRate)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else {
            let detail = parser.parserError?.localizedDescription ?? "unknown XML parser error"
            throw TrueHDError.invalidWaveFile("ADM axml could not be parsed: \(detail)")
        }

        let formatIDs = try parseChannelAssignment(
            channelAssignment,
            channelCount: channelCount
        )
        let channels = formatIDs.map { formatID in
            delegate.channels[formatID]
                ?? ADMChannelMetadata(channelFormatID: formatID, isObject: false, blocks: [])
        }
        let programmeStart = delegate.programmeStartSeconds == 0
            ? 3_600.0
            : delegate.programmeStartSeconds
        return ADMMetadata(
            channels: channels,
            programmeStartSeconds: programmeStart
        )
    }

    private static func parseChannelAssignment(
        _ data: Data,
        channelCount: Int
    ) throws -> [String] {
        guard data.count >= 4 else {
            throw TrueHDError.invalidWaveFile("ADM chna chunk is truncated")
        }
        let trackCount = Int(u16LE(data, at: 0))
        let uidCount = Int(u16LE(data, at: 2))
        guard trackCount == channelCount, uidCount >= channelCount else {
            throw TrueHDError.invalidWaveFile(
                "ADM chna describes \(trackCount) tracks for \(channelCount) PCM channels"
            )
        }

        var result = Array(repeating: "", count: channelCount)
        var offset = 4
        for _ in 0..<uidCount {
            guard offset + 40 <= data.count else {
                throw TrueHDError.invalidWaveFile("ADM chna UID records are truncated")
            }
            let trackIndex = Int(u16LE(data, at: offset))
            let trackReference = ascii(data, range: (offset + 14)..<(offset + 28))
            if (1...channelCount).contains(trackIndex), trackReference.hasPrefix("AT_") {
                let stem = String(trackReference.dropLast(3))
                result[trackIndex - 1] = "AC" + stem.dropFirst(2)
            }
            offset += 40
        }
        guard !result.contains(where: { $0.isEmpty }) else {
            throw TrueHDError.invalidWaveFile("ADM chna does not map every PCM channel")
        }
        return result
    }

    private static func ascii(_ data: Data, range: Range<Int>) -> String {
        let bytes = data[range].prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func u16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
}

private final class ADMXMLDelegate: NSObject, XMLParserDelegate {
    private struct PendingBlock {
        var startFrame: UInt64
        var durationFrames: UInt64
        var cartesian = true
        var coordinates: [String: Double] = [:]
        var jumpPosition = false
        var interpolationLengthFrames: UInt64?
    }

    let sampleRate: Int
    var channels: [String: ADMChannelMetadata] = [:]
    var programmeStartSeconds: Double?

    private var currentFormatID: String?
    private var currentIsObject = false
    private var currentBlocks: [PendingBlock] = []
    private var pendingBlock: PendingBlock?
    private var text = ""
    private var coordinate: String?

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch localName(elementName) {
        case "audioProgramme":
            if programmeStartSeconds == nil {
                programmeStartSeconds = seconds(from: attributeDict["start"])
            }
        case "audioChannelFormat":
            currentFormatID = attributeDict["audioChannelFormatID"]
            currentIsObject = attributeDict["typeDefinition"] == "Objects"
                || attributeDict["typeLabel"] == "0003"
            currentBlocks.removeAll(keepingCapacity: true)
        case "audioBlockFormat" where currentFormatID != nil:
            pendingBlock = PendingBlock(
                startFrame: frames(from: attributeDict["rtime"]),
                durationFrames: frames(from: attributeDict["duration"])
            )
        case "position":
            coordinate = attributeDict["coordinate"]
        case "jumpPosition":
            pendingBlock?.interpolationLengthFrames = attributeDict["interpolationLength"]
                .map(frames(from:))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "cartesian":
            pendingBlock?.cartesian = value != "0"
        case "position":
            if let coordinate, let number = Double(value) {
                pendingBlock?.coordinates[coordinate] = number
            }
            coordinate = nil
        case "jumpPosition":
            pendingBlock?.jumpPosition = value == "1"
        case "audioBlockFormat":
            if let block = pendingBlock {
                currentBlocks.append(block)
            }
            pendingBlock = nil
        case "audioChannelFormat":
            if let currentFormatID {
                channels[currentFormatID] = ADMChannelMetadata(
                    channelFormatID: currentFormatID,
                    isObject: currentIsObject,
                    blocks: positionBlocks(from: currentBlocks)
                )
            }
            currentFormatID = nil
            currentBlocks = []
        default:
            break
        }
        text = ""
    }

    private func position(from block: PendingBlock) -> ADMPosition {
        if block.cartesian {
            return ADMPosition(
                x: block.coordinates["X"] ?? 0,
                y: block.coordinates["Y"] ?? 0,
                z: block.coordinates["Z"] ?? 0
            )
        }
        let azimuth = (block.coordinates["azimuth"] ?? 0) * .pi / 180
        let elevation = (block.coordinates["elevation"] ?? 0) * .pi / 180
        let distance = block.coordinates["distance"] ?? 1
        let horizontal = cos(elevation) * distance
        return ADMPosition(
            // BS.2076 positive azimuth rotates towards the listener's left,
            // while normalized Cartesian X is positive towards the right.
            x: -sin(azimuth) * horizontal,
            y: cos(azimuth) * horizontal,
            z: sin(elevation) * distance
        )
    }

    private func positionBlocks(from rawBlocks: [PendingBlock]) -> [ADMPositionBlock] {
        let blocks = rawBlocks.sorted { $0.startFrame < $1.startFrame }
        guard let first = blocks.first else { return [] }
        var keyframes: [(frame: UInt64, position: ADMPosition, interpolates: Bool)] = []
        func append(_ frame: UInt64, _ position: ADMPosition, _ interpolates: Bool) {
            let value = (frame, position.clamped(), interpolates)
            if keyframes.last?.frame == frame {
                keyframes[keyframes.count - 1] = value
            } else {
                keyframes.append(value)
            }
        }

        // BS.2076 defines the first block's position over its entire duration,
        // regardless of jumpPosition, so the trajectory always has a known start.
        var previous = position(from: first).clamped()
        append(first.startFrame, previous, false)
        for block in blocks.dropFirst() {
            let target = position(from: block).clamped()
            if block.jumpPosition {
                let duration = block.durationFrames == 0 ? UInt64.max : block.durationFrames
                let interpolation = min(block.interpolationLengthFrames ?? 0, duration)
                if interpolation > 0, block.startFrame <= UInt64.max - interpolation {
                    append(block.startFrame, previous, true)
                    append(block.startFrame + interpolation, target, false)
                } else {
                    append(block.startFrame, target, false)
                }
            } else if block.durationFrames > 0,
                      block.startFrame <= UInt64.max - block.durationFrames {
                // With jumpPosition absent/zero, the block position is the
                // target reached at the end of that block's duration.
                append(block.startFrame, previous, true)
                append(block.startFrame + block.durationFrames, target, false)
            } else {
                append(block.startFrame, target, false)
            }
            previous = target
        }

        return keyframes.enumerated().map { index, item in
            ADMPositionBlock(
                startFrame: item.frame,
                endFrame: index + 1 < keyframes.count ? keyframes[index + 1].frame : .max,
                position: item.position,
                interpolatesToNext: item.interpolates
            )
        }
    }

    private func frames(from time: String?) -> UInt64 {
        guard let value = seconds(from: time) else { return 0 }
        return UInt64(max(0, value * Double(sampleRate)).rounded())
    }

    private func seconds(from time: String?) -> Double? {
        guard let time else { return nil }
        let fields = time.split(separator: ":")
        if fields.count == 1, let seconds = Double(fields[0]) {
            return max(0, seconds)
        }
        guard fields.count == 3,
              let hours = Double(fields[0]),
              let minutes = Double(fields[1]),
              let seconds = Double(fields[2]) else { return nil }
        return max(0, (hours * 60 + minutes) * 60 + seconds)
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
