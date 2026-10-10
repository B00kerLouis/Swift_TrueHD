// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
//
// Writes deterministic machine-readable and human-readable job companions only
// after the elementary stream has completed successfully.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum EncodingCompanionWriter {
    static func write(
        result: TrueHDEncodingResult,
        inputURL: URL,
        configuration: TrueHDEncoderConfiguration,
        startedAt: Date,
        completedAt: Date,
        encoderName: String = "Swift TrueHD Native"
    ) throws {
        let manifest = makeManifest(
            result: result,
            inputURL: inputURL,
            configuration: configuration,
            startedAt: startedAt,
            completedAt: completedAt,
            encoderName: encoderName
        )
        try manifest.write(to: result.manifestURL, options: .atomic)

        let duration = Double(result.inputFrameCount) / Double(result.sampleRate)
        let elapsed = completedAt.timeIntervalSince(startedAt)
        let averageRate = duration > 0
            ? Double(result.outputByteCount) * 8 / duration
            : 0
        let spatialAnalysis: String
        if let accuracy = result.spatialAccuracy {
            let renderingAnchorCount = max(0, result.spatialClusterCount - 1)
            spatialAnalysis = """

        Fixed-basis spatial approximation
          Fixed non-LFE rendering anchors: \(renderingAnchorCount)
          Metadata intervals: \(accuracy.intervalCount)
          Maximum active spatial sources: \(accuracy.maximumActiveSpatialSources)
          Source-interval observations: \(accuracy.sourceIntervalCount)
          Exactly represented source intervals: \(accuracy.exactlyRepresentedSourceIntervals)
          Rendering-basis assignment changes: \(accuracy.assignmentChangeCount)
          Maximum quantized XYZ deviation: \(String(format: "%.8f", accuracy.maximumQuantizedPositionError))
          Energy-weighted RMS quantized XYZ deviation: \(String(format: "%.8f", accuracy.energyWeightedRMSQuantizedPositionError))
        """
        } else {
            spatialAnalysis = ""
        }
        let log = """
        Dolby TrueHD Encode Log

        Identification
          Encoder: \(encoderName)
          Started: \(ISO8601DateFormatter().string(from: startedAt))
          Completed: \(ISO8601DateFormatter().string(from: completedAt))

        Input
          File: \(inputURL.path)
          Sample rate: \(result.sampleRate) Hz
          Encoded samples: \(result.inputFrameCount)
          Source frame rate: \(result.sourceFrameRate?.displayName ?? "not indicated")
          Output frame rate: \(result.outputFrameRate?.displayName ?? "not indicated")
          First frame of action: \(result.firstFrameOfAction)

        User options
          Spatial clusters: \(result.spatialClusterCount == 0 ? "not applicable" : String(result.spatialClusterCount))
          Frame-rate selection: \(frameRateSelectionName(configuration.frameRate))
          DRC profile: \(result.drcProfile.commandLineName)
          Prediction search: \(configuration.predictionMode.commandLineName)
          Dialnorm override: \(configuration.dialogueNormalization == 0 ? "default" : "-\(configuration.dialogueNormalization)")

        Automatic compliance policy
          Profile: \(profileName(result.profile))
          Element bit depth: \(result.elementBitDepth)
          Restart interval: \(restartInterval(result.profile))
          Peak bit rate limit: \(TrueHDCompliancePolicy.peakBitRate) bits/second
        \(spatialAnalysis)

        Output
          File: \(result.outputURL.path)
          Bytes: \(result.outputByteCount)
          Duration: \(String(format: "%.6f", duration)) seconds
          Average data rate: \(String(format: "%.0f", averageRate)) bits/second
          Encoding elapsed: \(String(format: "%.3f", elapsed)) seconds
          Job manifest: \(result.manifestURL.path)
          Encode log: \(result.logURL.path)

        Status
          Encoding completed.
        """
        let logData = Data((log + "\n").utf8)
        try logData.write(to: result.logURL, options: .atomic)
    }

    private static func makeManifest(
        result: TrueHDEncodingResult,
        inputURL: URL,
        configuration: TrueHDEncoderConfiguration,
        startedAt: Date,
        completedAt: Date,
        encoderName: String
    ) -> Data {
        let root = XMLElement(name: "encode")
        root.addAttribute(XMLNode.attribute(withName: "version", stringValue: "3") as! XMLNode)
        root.addAttribute(
            XMLNode.attribute(withName: "generator", stringValue: encoderName) as! XMLNode
        )

        let input = XMLElement(name: "input")
        input.addChild(element("file", inputURL.path))
        input.addChild(element("sample-rate", String(result.sampleRate)))
        input.addChild(element("sample-count", String(result.inputFrameCount)))
        input.addChild(element("source-frame-rate", result.sourceFrameRate?.displayName ?? "not_indicated"))
        root.addChild(input)

        let options = XMLElement(name: "options")
        options.addChild(element("spatial-clusters", String(result.spatialClusterCount)))
        options.addChild(element("ffoa", result.firstFrameOfAction))
        options.addChild(element("frame-rate", result.outputFrameRate?.displayName ?? "not_indicated"))
        options.addChild(element("frame-rate-selection", frameRateSelectionName(configuration.frameRate)))
        options.addChild(element("drc-profile", result.drcProfile.commandLineName))
        options.addChild(element("prediction-search", configuration.predictionMode.commandLineName))
        options.addChild(element("dialnorm-override", configuration.dialogueNormalization == 0 ? "default" : "-\(configuration.dialogueNormalization)"))
        root.addChild(options)

        let compliance = XMLElement(name: "automatic-compliance")
        compliance.addChild(element("profile", profileName(result.profile)))
        compliance.addChild(element("element-bit-depth", String(result.elementBitDepth)))
        compliance.addChild(element("restart-interval", String(restartInterval(result.profile))))
        compliance.addChild(element("peak-bit-rate", String(TrueHDCompliancePolicy.peakBitRate)))
        root.addChild(compliance)

        if let accuracy = result.spatialAccuracy {
            let spatial = XMLElement(name: "spatial-accuracy")
            spatial.addChild(element(
                "available-spatial-elements",
                String(max(0, result.spatialClusterCount - 8))
            ))
            spatial.addChild(element("metadata-intervals", String(accuracy.intervalCount)))
            spatial.addChild(element(
                "maximum-active-spatial-sources",
                String(accuracy.maximumActiveSpatialSources)
            ))
            spatial.addChild(element("grouped-intervals", String(accuracy.groupedIntervalCount)))
            spatial.addChild(element("source-intervals", String(accuracy.sourceIntervalCount)))
            spatial.addChild(element(
                "exact-before-oamd-quantization",
                String(accuracy.exactlyRepresentedSourceIntervals)
            ))
            spatial.addChild(element(
                "continuous-source-assignment-changes",
                String(accuracy.assignmentChangeCount)
            ))
            spatial.addChild(element(
                "maximum-quantized-xyz-deviation",
                String(format: "%.8f", accuracy.maximumQuantizedPositionError)
            ))
            spatial.addChild(element(
                "energy-weighted-rms-quantized-xyz-deviation",
                String(format: "%.8f", accuracy.energyWeightedRMSQuantizedPositionError)
            ))
            root.addChild(spatial)
        }

        let presentations = XMLElement(name: "presentations")
        let counts = result.profile == .atmos ? [2, 6, 8, result.channelCount] : [2, 6, 8]
        for (index, count) in counts.enumerated() {
            let presentation = XMLElement(name: "presentation")
            presentation.addAttribute(
                XMLNode.attribute(withName: "channels", stringValue: String(count)) as! XMLNode
            )
            presentation.addAttribute(
                XMLNode.attribute(
                    withName: "type",
                    stringValue: index == counts.count - 1 ? "independent" : "compatible"
                ) as! XMLNode
            )
            presentations.addChild(presentation)
        }
        root.addChild(presentations)

        let output = XMLElement(name: "output")
        output.addChild(element("file", result.outputURL.path))
        output.addChild(element("bytes", String(result.outputByteCount)))
        output.addChild(element("log", result.logURL.path))
        root.addChild(output)

        let execution = XMLElement(name: "execution")
        execution.addChild(element("started", ISO8601DateFormatter().string(from: startedAt)))
        execution.addChild(element("completed", ISO8601DateFormatter().string(from: completedAt)))
        root.addChild(execution)

        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        return document.xmlData(options: [.nodePrettyPrint])
    }

    private static func element(_ name: String, _ value: String) -> XMLElement {
        XMLElement(name: name, stringValue: value)
    }

    private static func profileName(_ profile: TrueHDProfile) -> String {
        switch profile {
        case .surround71: "surround71"
        case .atmos: "atmos"
        }
    }

    private static func restartInterval(_ profile: TrueHDProfile) -> Int {
        switch profile {
        case .surround71: TrueHDCompliancePolicy.surroundRestartInterval
        case .atmos: TrueHDCompliancePolicy.atmosRestartInterval
        }
    }

    private static func frameRateSelectionName(_ selection: TrueHDOutputFrameRate) -> String {
        switch selection {
        case .input: "input"
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
}
