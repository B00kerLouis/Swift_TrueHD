// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Public configuration, progress, result, and error types shared by the Swift,
// command-line, and Objective-C entry points.

import Foundation

@objc(STTrueHDProfile)
public enum TrueHDProfile: Int, Sendable {
    case surround71
    /// 12-, 14-, or 16-element TrueHD with Atmos metadata.
    case atmos
}

/// Selects the dynamic-range-control metadata curve carried by the TrueHD
/// stream. The PCM remains lossless; a decoder may apply, scale, or disable
/// the resulting gain trajectory during playback.
@objc(STTrueHDDRCProfile)
public enum TrueHDDRCProfile: Int, Sendable, CaseIterable {
    case filmStandard
    case filmLight
    case musicStandard
    case musicLight
    case speech

    public var commandLineName: String {
        switch self {
        case .filmStandard: "film_standard"
        case .filmLight: "film_light"
        case .musicStandard: "music_standard"
        case .musicLight: "music_light"
        case .speech: "speech"
        }
    }
}

@objc(STTrueHDFrameRate)
public enum TrueHDFrameRate: Int, Sendable, CaseIterable {
    case fps23976
    case fps24
    case fps25
    case fps2997Drop
    case fps2997
    case fps30
    case fps47952
    case fps48
    case fps50
    case fps5994
    case fps60

    public var framesPerSecond: Double {
        switch self {
        case .fps23976: 24_000.0 / 1_001.0
        case .fps24: 24
        case .fps25: 25
        case .fps2997Drop, .fps2997: 30_000.0 / 1_001.0
        case .fps30: 30
        case .fps47952: 48_000.0 / 1_001.0
        case .fps48: 48
        case .fps50: 50
        case .fps5994: 60_000.0 / 1_001.0
        case .fps60: 60
        }
    }

    public var displayName: String {
        switch self {
        case .fps23976: "23.976"
        case .fps24: "24"
        case .fps25: "25"
        case .fps2997Drop: "29.97 DF"
        case .fps2997: "29.97"
        case .fps30: "30"
        case .fps47952: "47.952"
        case .fps48: "48"
        case .fps50: "50"
        case .fps5994: "59.94"
        case .fps60: "60"
        }
    }

    var nominalFrameCount: Int {
        switch self {
        case .fps23976, .fps24: 24
        case .fps25: 25
        case .fps2997Drop, .fps2997, .fps30: 30
        case .fps47952, .fps48: 48
        case .fps50: 50
        case .fps5994, .fps60: 60
        }
    }

    /// Maps a decimal rate carried by DAMF to the corresponding SMPTE
    /// non-drop-frame rate. A decimal source does not encode drop-frame mode.
    static func fromFramesPerSecond(_ value: Double) -> TrueHDFrameRate? {
        let nonDropFrameRates: [TrueHDFrameRate] = [
            .fps23976, .fps24, .fps25, .fps2997, .fps30,
            .fps47952, .fps48, .fps50, .fps5994, .fps60,
        ]
        return nonDropFrameRates.min { lhs, rhs in
            abs(lhs.framesPerSecond - value) < abs(rhs.framesPerSecond - value)
        }.flatMap { candidate in
            abs(candidate.framesPerSecond - value) < 0.01 ? candidate : nil
        }
    }

    static func fromDBMD(_ data: Data) -> TrueHDFrameRate? {
        // DBMD v6 stores the frames-per-second enumeration at byte 0xDA.
        guard data.count > 0xDA, data.prefix(2).elementsEqual([0x06, 0x00]) else {
            return nil
        }
        switch data[0xDA] {
        case 0x21: return .fps23976
        case 0x22: return .fps24
        case 0x23: return .fps25
        case 0x24: return .fps2997Drop
        case 0x25: return .fps2997
        case 0x26: return .fps30
        case 0x27: return .fps47952
        case 0x28: return .fps48
        case 0x29: return .fps50
        case 0x2B: return .fps5994
        case 0x2C: return .fps60
        default: return nil
        }
    }
}

/// Selects the output timecode rate. `.input` preserves the rate declared by
/// the input master; the remaining values explicitly override it.
@objc(STTrueHDOutputFrameRate)
public enum TrueHDOutputFrameRate: Int, Sendable, CaseIterable {
    case input
    case fps23976
    case fps24
    case fps25
    case fps2997Drop
    case fps2997
    case fps30
    case fps47952
    case fps48
    case fps50
    case fps5994
    case fps60

    func resolve(input inputFrameRate: TrueHDFrameRate?) -> TrueHDFrameRate? {
        switch self {
        case .input: inputFrameRate
        case .fps23976: .fps23976
        case .fps24: .fps24
        case .fps25: .fps25
        case .fps2997Drop: .fps2997Drop
        case .fps2997: .fps2997
        case .fps30: .fps30
        case .fps47952: .fps47952
        case .fps48: .fps48
        case .fps50: .fps50
        case .fps5994: .fps5994
        case .fps60: .fps60
        }
    }
}

@objc(STTrueHDEncoderConfiguration)
@objcMembers
public final class TrueHDEncoderConfiguration: NSObject, NSCopying, @unchecked Sendable {
    public var spatialClusterCount: Int
    public var firstFrameOfAction: String
    public var frameRate: TrueHDOutputFrameRate
    public var drcProfile: TrueHDDRCProfile

    public override convenience init() { self.init(spatialClusterCount: 16) }

    public init(
        spatialClusterCount: Int = 16,
        firstFrameOfAction: String = "00:00:00:00",
        frameRate: TrueHDOutputFrameRate = .input,
        drcProfile: TrueHDDRCProfile = .filmLight
    ) {
        self.spatialClusterCount = spatialClusterCount
        self.firstFrameOfAction = firstFrameOfAction
        self.frameRate = frameRate
        self.drcProfile = drcProfile
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        TrueHDEncoderConfiguration(
            spatialClusterCount: spatialClusterCount,
            firstFrameOfAction: firstFrameOfAction,
            frameRate: frameRate,
            drcProfile: drcProfile
        )
    }
}

public struct TrueHDEncodingProgress: Sendable, Equatable {
    public let completedFrames: UInt64
    public let totalFrames: UInt64
    public let encodedBytes: UInt64

    public var fractionCompleted: Double {
        guard totalFrames > 0 else { return 0 }
        return min(1, Double(completedFrames) / Double(totalFrames))
    }
}

public struct TrueHDSpatialAccuracy: Sendable, Equatable {
    public let intervalCount: Int
    public let maximumActiveSpatialSources: Int
    public let groupedIntervalCount: Int
    public let sourceIntervalCount: Int
    public let exactlyRepresentedSourceIntervals: Int
    public let assignmentChangeCount: Int
    public let maximumQuantizedPositionError: Double
    public let energyWeightedRMSQuantizedPositionError: Double
}

public struct TrueHDEncodingResult: Sendable, Equatable {
    public let outputURL: URL
    public let profile: TrueHDProfile
    public let sampleRate: Int
    public let channelCount: Int
    public let inputFrameCount: UInt64
    public let outputByteCount: UInt64
    public let sourceFrameRate: TrueHDFrameRate?
    public let outputFrameRate: TrueHDFrameRate?
    public let firstFrameOfAction: String
    public let spatialClusterCount: Int
    public let elementBitDepth: Int
    public let drcProfile: TrueHDDRCProfile
    public let spatialAccuracy: TrueHDSpatialAccuracy?

    public var manifestURL: URL {
        URL(fileURLWithPath: outputURL.path + ".mll")
    }

    public var logURL: URL {
        URL(fileURLWithPath: outputURL.path + ".log")
    }
}

public enum TrueHDError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidWaveFile(String)
    case unsupportedInput(String)
    case outputExists(URL)
    case malformedBitstream(String)
    case peakBitRateExceeded(required: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
             .invalidWaveFile(let message),
             .unsupportedInput(let message),
             .malformedBitstream(let message):
            message
        case .outputExists(let url):
            "Output already exists: \(url.path)"
        case .peakBitRateExceeded(let required, let limit):
            "Encoded access unit requires \(required) bits/second; limit is \(limit)"
        }
    }
}

enum TrueHDCompliancePolicy {
    static let atmosRestartInterval = 124
    static let surroundRestartInterval = 128
    static let peakBitRate = 18_000_000
    static let atmosElementBitDepths = [20, 19, 18, 17]
}
