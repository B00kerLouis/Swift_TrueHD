// SPDX-License-Identifier: AGPL-3.0-only
//
// Parses the intentionally small public command surface and maps it onto the
// shared framework configuration. Compliance choices remain inside the library.

import Darwin
import Foundation
import libtruehda

@main
private struct TurehdaCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            let message = "error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
            printUsage()
            return
        }
        var input: String?
        var output: String?
        let configuration = TrueHDEncoderConfiguration()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "-i", "--input":
                input = try requiredValue(for: option, at: &index, in: arguments)
            case "-o", "--output":
                output = try requiredValue(for: option, at: &index, in: arguments)
            case "--spatial-clusters":
                let value = try requiredValue(for: option, at: &index, in: arguments)
                guard let count = Int(value), [12, 14, 16].contains(count) else {
                    throw CLIError.invalidSpatialClusters(value)
                }
                configuration.spatialClusterCount = count
            case "--ffoa":
                configuration.firstFrameOfAction = try requiredValue(
                    for: option, at: &index, in: arguments
                )
            case "--frame-rate":
                let value = try requiredValue(for: option, at: &index, in: arguments)
                configuration.frameRate = try parseFrameRate(value)
            case "--drc-profile":
                let value = try requiredValue(for: option, at: &index, in: arguments)
                configuration.drcProfile = try parseDRCProfile(value)
            default:
                throw CLIError.unknownOption(option)
            }
            index += 1
        }

        guard let input, let output else {
            printUsage()
            throw CLIError.missingRequiredArguments
        }

        let result = try await TrueHDEncoder().encode(
            inputURL: URL(fileURLWithPath: input),
            outputURL: URL(fileURLWithPath: output),
            configuration: configuration,
            progress: { progress in
                let percent = Int(progress.fractionCompleted * 100)
                FileHandle.standardError.write(Data("\rEncoding \(percent)%".utf8))
            }
        )
        FileHandle.standardError.write(Data("\n".utf8))
        print("Wrote \(result.outputByteCount) bytes to \(result.outputURL.path)")
        print("DRC profile: \(result.drcProfile.commandLineName)")
        if let frameRate = result.outputFrameRate {
            print("Output frame rate: \(frameRate.displayName) fps; FFOA: \(result.firstFrameOfAction)")
        }
        if let accuracy = result.spatialAccuracy {
            let renderingAnchorCount = max(0, result.spatialClusterCount - 1)
            print(
                "Fixed-basis spatial approximation: max XYZ deviation "
                    + "\(String(format: "%.6f", accuracy.maximumQuantizedPositionError)), "
                    + "energy-weighted RMS "
                    + "\(String(format: "%.6f", accuracy.energyWeightedRMSQuantizedPositionError)); "
                    + "maximum \(accuracy.maximumActiveSpatialSources) active spatial sources "
                    + "across \(renderingAnchorCount) fixed non-LFE anchors"
            )
        }
        print("Job manifest: \(result.manifestURL.path)")
        print("Encode log: \(result.logURL.path)")
    }

    private static func requiredValue(
        for option: String,
        at index: inout Int,
        in arguments: [String]
    ) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw CLIError.missingValue(option)
        }
        return arguments[index]
    }

    private static func parseFrameRate(_ value: String) throws -> TrueHDOutputFrameRate {
        switch value.lowercased().replacingOccurrences(of: " ", with: "") {
        case "23.976", "23.98": .fps23976
        case "24": .fps24
        case "25": .fps25
        case "29.97df", "29.97-df", "29.97drop": .fps2997Drop
        case "29.97": .fps2997
        case "30": .fps30
        default: throw CLIError.invalidFrameRate(value)
        }
    }

    private static func parseDRCProfile(_ value: String) throws -> TrueHDDRCProfile {
        switch value.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_") {
        case "film_standard", "filmstandard": .filmStandard
        case "film_light", "filmlight": .filmLight
        case "music_standard", "musicstandard": .musicStandard
        case "music_light", "musiclight": .musicLight
        case "speech": .speech
        default: throw CLIError.invalidDRCProfile(value)
        }
    }

    private static func printUsage() {
        print(
            """
            Usage:
              turehda -i INPUT -o OUTPUT.mlp [options]

            Options:
              -i, --input PATH                 Input WAVE, DAMF, or MXF IAB master
              -o, --output PATH.mlp            Output TrueHD elementary stream
                  --spatial-clusters 12|14|16  Atmos transport elements (default: 16)
                  --ffoa HH:MM:SS:FF           Output start timecode (default: 00:00:00:00)
                  --frame-rate RATE            23.976|24|25|29.97df|29.97|30
                  --drc-profile PROFILE        film_standard|film_light|music_standard|
                                               music_light|speech (default: film_light)
            """
        )
    }
}

private enum CLIError: LocalizedError {
    case missingRequiredArguments
    case missingValue(String)
    case unknownOption(String)
    case invalidSpatialClusters(String)
    case invalidFrameRate(String)
    case invalidDRCProfile(String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredArguments:
            "--input and --output are required"
        case .missingValue(let option):
            "Missing value for \(option)"
        case .unknownOption(let option):
            "Unknown option: \(option)"
        case .invalidSpatialClusters(let value):
            "Spatial clusters must be 12, 14, or 16; got \(value)"
        case .invalidFrameRate(let value):
            "Unsupported frame rate: \(value)"
        case .invalidDRCProfile(let value):
            "Unsupported DRC profile: \(value)"
        }
    }
}
