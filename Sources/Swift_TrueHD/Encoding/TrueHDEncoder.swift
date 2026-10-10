// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Public asynchronous facade that validates configuration, selects the native
// input path, and dispatches to the matching elementary-stream encoder.

import Foundation

public final class TrueHDEncoder: Sendable {
    public init() {}

    public func encode(
        inputURL: URL,
        outputURL: URL,
        configuration: TrueHDEncoderConfiguration = TrueHDEncoderConfiguration(),
        progress: (@Sendable (TrueHDEncodingProgress) -> Void)? = nil
    ) async throws -> TrueHDEncodingResult {
        guard outputURL.pathExtension.lowercased() == "mlp" else {
            throw TrueHDError.invalidConfiguration(
                "Raw TrueHD output must use the .mlp file extension"
            )
        }
        let configuration = configuration.copy() as! TrueHDEncoderConfiguration
        guard (0...31).contains(configuration.dialogueNormalization) else {
            throw TrueHDError.invalidConfiguration("Dialogue normalization must be 0 (default) or 1...31")
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw TrueHDError.outputExists(outputURL)
        }
        let startedAt = Date()
        let result: TrueHDEncodingResult
        let encoderName: String
        let initialReader = try NativeMasterReader.open(url: inputURL)
        let isAtmos = initialReader.admMetadata != nil
            || (initialReader.admXML != nil && initialReader.admChannelAssignment != nil)
        if isAtmos {
            var completedResult: TrueHDEncodingResult?
            for (index, bitDepth) in TrueHDCompliancePolicy.atmosElementBitDepths.enumerated() {
                let reader = index == 0
                    ? initialReader
                    : try NativeMasterReader.open(url: inputURL)
                do {
                    let encoder = try AtmosBitstreamEncoder(
                        configuration: configuration, elementBitDepth: bitDepth
                    )
                    completedResult = try encoder.encode(
                        reader: reader,
                        outputURL: outputURL,
                        overwrite: false,
                        progress: progress
                    )
                    break
                } catch let error as TrueHDError {
                    if case .peakBitRateExceeded = error,
                       index + 1 < TrueHDCompliancePolicy.atmosElementBitDepths.count {
                        continue
                    }
                    throw error
                }
            }
            guard let completedResult else {
                throw TrueHDError.invalidConfiguration(
                    "No compliant Atmos element depth could satisfy the transport limit"
                )
            }
            result = completedResult
            encoderName = "libtruehda"
        } else {
            let encoder = try TrueHDBitstreamEncoder(configuration: configuration)
            result = try encoder.encode(
                reader: initialReader,
                outputURL: outputURL,
                overwrite: false,
                progress: progress
            )
            encoderName = "Swift TrueHD Native 7.1"
        }
        try EncodingCompanionWriter.write(
            result: result,
            inputURL: inputURL,
            configuration: configuration,
            startedAt: startedAt,
            completedAt: Date(),
            encoderName: encoderName
        )
        return result
    }
}
