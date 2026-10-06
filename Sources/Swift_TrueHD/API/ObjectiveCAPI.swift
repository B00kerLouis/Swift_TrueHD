// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Objective-C-compatible wrappers preserve the same configuration defaults,
// progress reporting, and result metadata as the native Swift API.

import Foundation

@objcMembers
public final class STTrueHDProgress: NSObject, @unchecked Sendable {
    public let completedFrames: UInt64
    public let totalFrames: UInt64
    public let encodedBytes: UInt64
    public let fractionCompleted: Double

    init(_ progress: TrueHDEncodingProgress) {
        completedFrames = progress.completedFrames
        totalFrames = progress.totalFrames
        encodedBytes = progress.encodedBytes
        fractionCompleted = progress.fractionCompleted
    }
}

@objcMembers
public final class STTrueHDResult: NSObject, @unchecked Sendable {
    public let outputURL: URL
    public let profile: TrueHDProfile
    public let sampleRate: Int
    public let channelCount: Int
    public let inputFrameCount: UInt64
    public let outputByteCount: UInt64
    public let sourceFrameRate: Double
    public let sourceFrameRateName: String
    public let outputFrameRate: Double
    public let outputFrameRateName: String
    public let firstFrameOfAction: String
    public let spatialClusterCount: Int
    public let drcProfile: TrueHDDRCProfile
    public let drcProfileName: String
    public let manifestURL: URL
    public let logURL: URL

    init(_ result: TrueHDEncodingResult) {
        outputURL = result.outputURL
        profile = result.profile
        sampleRate = result.sampleRate
        channelCount = result.channelCount
        inputFrameCount = result.inputFrameCount
        outputByteCount = result.outputByteCount
        sourceFrameRate = result.sourceFrameRate?.framesPerSecond ?? 0
        sourceFrameRateName = result.sourceFrameRate?.displayName ?? "not indicated"
        outputFrameRate = result.outputFrameRate?.framesPerSecond ?? 0
        outputFrameRateName = result.outputFrameRate?.displayName ?? "not indicated"
        firstFrameOfAction = result.firstFrameOfAction
        spatialClusterCount = result.spatialClusterCount
        drcProfile = result.drcProfile
        drcProfileName = result.drcProfile.commandLineName
        manifestURL = result.manifestURL
        logURL = result.logURL
    }
}

@objcMembers
public final class STTrueHDEncoder: NSObject, Sendable {
    public override init() {}

    public func encode(
        inputURL: URL,
        outputURL: URL,
        configuration: TrueHDEncoderConfiguration,
        progressHandler: (@Sendable (STTrueHDProgress) -> Void)?,
        completionHandler: @escaping @Sendable (STTrueHDResult?, NSError?) -> Void
    ) {
        Task.detached {
            do {
                let result = try await TrueHDEncoder().encode(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    configuration: configuration,
                    progress: { progress in
                        progressHandler?(STTrueHDProgress(progress))
                    }
                )
                completionHandler(STTrueHDResult(result), nil)
            } catch {
                completionHandler(nil, error as NSError)
            }
        }
    }
}
