// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Foundation

/// Fits each source's speaker image using only the active aggregate directions.
/// Nonnegative coefficients preserve source polarity; power normalization is
/// applied to the reconstructed field, including correlated element feeds.
enum AtmosImageMixer {
    static func weights(for point: ADMPosition, centres: [ADMPosition], basisCount: Int) -> [Double] {
        guard !centres.isEmpty else { return [] }
        let target = AtmosSpeakerBasis.gains(at: point, count: basisCount)
        let columns = centres.map { AtmosSpeakerBasis.gains(at: $0, count: basisCount) }
        var gains = nonnegativeLeastSquares(columns: columns, target: target)
        func render(_ values: [Double]) -> [Double] {
            (0..<basisCount).map { row in
                columns.indices.reduce(0) { $0 + columns[$1][row] * values[$1] }
            }
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        var field = render(gains)
        let targetPower = dot(target, target), power = dot(field, field)
        let epsilon = Double(Float.ulpOfOne)
        if power > pow(10, -0.2) * targetPower {
            let scale = sqrt((targetPower + epsilon) / (power + epsilon))
            gains = gains.map { $0 * scale }
        } else {
            // When the active directions cannot span the requested image,
            // retain the least-squares fit and restore the missing field power
            // along a nonnegative geometric direction.
            let scale = pow(10, 0.1)
            gains = gains.map { $0 * scale }
            field = field.map { $0 * scale }
            let geometric = AtmosAggregatePlanner.weights(for: point, centres: centres, minimumGain: 0)
            let supplementary = render(geometric)
            let a = dot(supplementary, supplementary)
            let b = 2 * dot(supplementary, field)
            let c = dot(field, field) - targetPower
            let amount = (sqrt(max(0, b * b - 4 * a * c)) - b) / (2 * a + epsilon)
            gains = zip(gains, geometric).map { $0.0 + amount * $0.1 }
        }
        gains = gains.map { $0 >= 1e-6 ? $0 : 0 }
        let sum = gains.reduce(0, +)
        if let largest = gains.indices.max(by: { gains[$0] < gains[$1] }),
           gains[largest] >= sum * Double(Float(0.99997)) {
            gains = gains.indices.map { $0 == largest ? min(1, sum) : 0 }
        }
        return gains
    }

    /// Lawson-Hanson active-set solve on a bounded (at most 15-column) system.
    /// Reorthogonalized QR avoids squaring the condition number for neighbouring
    /// aggregate directions. Rank-deficient columns remain inactive.
    private static func nonnegativeLeastSquares(columns: [[Double]], target: [Double]) -> [Double] {
        let count = columns.count, rows = target.count
        var x = [Double](repeating: 0, count: count)
        var passive = [Bool](repeating: false, count: count)
        var excluded = passive
        func solve(_ indices: [Int]) -> [Double]? {
            var q = [[Double]](), r = [[Double]](repeating: [Double](repeating: 0, count: indices.count), count: indices.count)
            for (j, index) in indices.enumerated() {
                var v = columns[index]
                for _ in 0..<2 {
                    for i in 0..<j {
                        let dot = (0..<rows).reduce(0.0) { $0 + q[i][$1] * v[$1] }
                        r[i][j] += dot
                        for row in 0..<rows { v[row] -= dot * q[i][row] }
                    }
                }
                let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
                guard norm > 1e-10 else { return nil }
                r[j][j] = norm
                q.append(v.map { $0 / norm })
            }
            var values = q.map { column in zip(column, target).reduce(0) { $0 + $1.0 * $1.1 } }
            for i in indices.indices.reversed() {
                for j in (i + 1)..<indices.count { values[i] -= r[i][j] * values[j] }
                values[i] /= r[i][i]
            }
            return values
        }
        for _ in 0..<(count * count * 3) {
            let residual = (0..<rows).map { row in
                target[row] - columns.indices.reduce(0.0) { $0 + columns[$1][row] * x[$1] }
            }
            let gradient = columns.map { column in zip(column, residual).reduce(0) { $0 + $1.0 * $1.1 } }
            guard let incoming = columns.indices.filter({ !passive[$0] && !excluded[$0] })
                .max(by: { gradient[$0] < gradient[$1] }), gradient[incoming] > 1e-10 else { break }
            passive[incoming] = true
            for _ in 0..<(count * 3) {
                let indices = columns.indices.filter { passive[$0] }
                guard let solution = solve(indices) else {
                    passive[incoming] = false
                    excluded[incoming] = true
                    break
                }
                var z = [Double](repeating: 0, count: count)
                for (i, index) in indices.enumerated() { z[index] = solution[i] }
                if indices.allSatisfy({ z[$0] > 0 }) { x = z; break }
                let alpha = indices.filter { z[$0] <= 0 }.map { x[$0] / (x[$0] - z[$0]) }.min() ?? 1
                for i in x.indices { x[i] += alpha * (z[i] - x[i]) }
                for i in indices where x[i] <= 1e-12 { x[i] = 0; passive[i] = false }
            }
        }
        return x
    }
}
