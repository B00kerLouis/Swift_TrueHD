// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Foundation

/// Room-coordinate basis used to allocate the 11, 13 and 15 non-LFE aggregates.
/// These are analysis directions, not fixed output object positions.
enum AtmosSpeakerBasis {
    private static let maximum = 32_767.0 / 32_768.0
    private static let wideDepth = 5_285.0 / 32_768.0

    static func gains(at position: ADMPosition, count: Int) -> [Double] {
        precondition([11, 13, 15].contains(count))
        func coordinate(_ value: Double) -> Double {
            min(32_767, max(0, (value * 32_768).rounded())) / 32_768
        }
        let x = coordinate((position.x + 1) / 2)
        let y = coordinate((1 - position.y) / 2)
        let z = coordinate(position.z)
        var result = [Double](repeating: 0, count: count)
        typealias Row = (depth: Double, columns: [(Double, Int)])
        var floor: [Row] = [(0, [(0, 0), (0.5, 2), (maximum, 1)])]
        if count > 11 { floor.append((wideDepth, [(0, 7), (maximum, 8)])) }
        floor += [(0.5, [(0, 3), (maximum, 4)]), (maximum, [(0, 5), (maximum, 6)])]
        let firstHeight = count == 11 ? 7 : 9
        var height: [Row] = [(0, [(0, firstHeight), (maximum, firstHeight + 1)])]
        if count == 15 { height.append((0.5, [(0, 11), (maximum, 12)])) }
        height.append((maximum, [(0, count - 2), (maximum, count - 1)]))
        func pair(_ value: Double, _ nodes: [Double]) -> [(Int, Double)] {
            if value <= nodes[0] { return [(0, 1)] }
            if value >= nodes[nodes.count - 1] { return [(nodes.count - 1, 1)] }
            for i in 1..<nodes.count where value <= nodes[i] {
                let angle = (value - nodes[i - 1]) / (nodes[i] - nodes[i - 1]) * .pi / 2
                return [(i - 1, cos(angle)), (i, sin(angle))]
            }
            return []
        }
        let vertical = z >= maximum ? (0.0, 1.0) : (cos(z * .pi / 2), sin(z * .pi / 2))
        for (rows, verticalGain) in [(floor, vertical.0), (height, vertical.1)] where verticalGain > 0 {
            for (row, depthGain) in pair(y, rows.map(\.depth)) {
                for (column, horizontalGain) in pair(x, rows[row].columns.map { $0.0 }) {
                    let value = horizontalGain * depthGain * verticalGain
                    if value >= 1e-6 { result[rows[row].columns[column].1] = value }
                }
            }
        }
        return result
    }
}
