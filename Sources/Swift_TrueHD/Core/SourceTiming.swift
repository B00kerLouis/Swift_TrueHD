// SPDX-License-Identifier: AGPL-3.0-only
//
// Resolves source frame-rate and timecode metadata into one validated output
// timeline shared by the elementary stream and companion records.

import Foundation

struct TrueHDSourceTiming: Sendable, Equatable {
    let frameRate: TrueHDFrameRate
    let firstFrameOfAction: String
    let inputStartFrame: UInt64

    static func resolve(
        frameRate: TrueHDFrameRate?,
        firstFrameOfAction: String,
        availableFrames: UInt64
    ) throws -> TrueHDSourceTiming {
        guard let frameRate else {
            throw TrueHDError.unsupportedInput(
                "Atmos input DBMD does not contain a supported source frame rate"
            )
        }
        _ = try seconds(for: firstFrameOfAction, frameRate: frameRate)
        guard availableFrames > 0 else {
            throw TrueHDError.unsupportedInput("Atmos input contains no audio samples")
        }
        return TrueHDSourceTiming(
            frameRate: frameRate,
            firstFrameOfAction: firstFrameOfAction,
            inputStartFrame: 0
        )
    }

    private static func seconds(
        for value: String,
        frameRate: TrueHDFrameRate
    ) throws -> Double {
        let normalized = value.replacingOccurrences(of: ";", with: ":")
        let fields = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 4,
              let hours = Int(fields[0]),
              let minutes = Int(fields[1]),
              let seconds = Int(fields[2]),
              let frames = Int(fields[3]),
              hours >= 0,
              (0..<60).contains(minutes),
              (0..<60).contains(seconds),
              (0..<frameRate.nominalFrameCount).contains(frames) else {
            throw TrueHDError.invalidConfiguration(
                "FFOA must use HH:MM:SS:FF (or HH:MM:SS;FF for drop-frame)"
            )
        }
        return Double((hours * 60 + minutes) * 60 + seconds)
            + Double(frames) / frameRate.framesPerSecond
    }
}
