// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Foundation

/// Dense source-to-element plans remain on the selected output volume. A small
/// read-only window is prepared before each parallel PCM batch; workers never
/// perform file I/O or mutate the window. The temporary plan is removed on exit.
final class AtmosFramePlanStore<Value: BitwiseCopyable & Sendable>: @unchecked Sendable {
    private let url: URL
    private let file: FileHandle
    let sourceCount: Int
    let elementCount: Int
    private var count = 0
    private var windowStart = 0
    private var window = [Value]()
    private var width: Int { sourceCount * elementCount }

    init(directory: URL, sourceCount: Int, elementCount: Int) throws {
        self.sourceCount = sourceCount
        self.elementCount = elementCount
        url = directory.appendingPathComponent(".truehda-plan-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { file = try FileHandle(forUpdating: url) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    deinit {
        try? file.close()
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ values: [Value]) throws {
        precondition(values.count == width)
        try values.withUnsafeBytes { try file.write(contentsOf: Data($0)) }
        count += 1
    }

    func prepareWindow(first: Int, last: Int) throws {
        guard count > 0 else { return }
        let lower = max(0, first), upper = min(count - 1, last)
        precondition(upper >= lower && upper - lower < 64)
        let stride = MemoryLayout<Value>.stride
        let bytes = (upper - lower + 1) * width * stride
        try file.seek(toOffset: UInt64(lower) * UInt64(width) * UInt64(stride))
        guard let data = try file.read(upToCount: bytes), data.count == bytes else {
            throw TrueHDError.invalidConfiguration("Incomplete spatial gain plan")
        }
        window = data.withUnsafeBytes { raw in
            (0..<(bytes / stride)).map { raw.loadUnaligned(fromByteOffset: $0 * stride, as: Value.self) }
        }
        windowStart = lower
    }

    func row(interval: Int, source: Int) -> ArraySlice<Value> {
        let index = min(max(0, interval), count - 1)
        let first = (index - windowStart) * width + source * elementCount
        precondition(first >= 0 && first + elementCount <= window.count)
        return window[first..<(first + elementCount)]
    }
}

typealias AtmosAggregateGainStore = AtmosFramePlanStore<Int32>
typealias AtmosSpectralPlanStore = AtmosFramePlanStore<Float>
