// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Foundation

/// Separable finite-size field on the internal 7.1.4 analysis basis. Tables are
/// generated from the panning geometry and a compact quartic kernel, rather
/// than measured programme audio. All dimensions and storage are fixed.
enum AtmosDiffuseField {
    static let positions: [ADMPosition] = [
        .init(x: -1, y: 1, z: 0), .init(x: 1, y: 1, z: 0), .init(x: 0, y: 1, z: 0),
        .init(x: -1, y: 0, z: 0), .init(x: 1, y: 0, z: 0),
        .init(x: -1, y: -1, z: 0), .init(x: 1, y: -1, z: 0),
        .init(x: -1, y: 1, z: 1), .init(x: 1, y: 1, z: 1),
        .init(x: -1, y: -1, z: 1), .init(x: 1, y: -1, z: 1)
    ]
    private static let maximum = 32_767.0 / 32_768.0
    private static let tables: [[Double]] = (0..<3).map { axis in
        let positions = axis == 2 ? 4 : 35
        let samples = axis == 2 ? 8 : 20
        var table = [Double](repeating: 0, count: positions * 20 * 11)
        for position in 0..<positions {
            let centre = Double(position) / Double(positions - 1)
            for size in 0..<20 {
                let width = Double(size) * 0.7 / 19
                let order = exponent(width)
                for sample in 0..<samples {
                    let coordinate = Double(sample) / Double(samples - 1)
                    let weight = kernel(axis: axis, coordinate: coordinate, centre: centre, width: width)
                    let panning = axisGains(axis, at: coordinate)
                    for channel in 0..<11 {
                        table[(position * 20 + size) * 11 + channel] += power(panning[channel] * weight, order)
                    }
                }
            }
        }
        return table
    }

    static func gains(at position: ADMPosition, size: Double) -> [Double] {
        guard size > 0 else { return [Double](repeating: 0, count: 11) }
        func quantize(_ value: Double) -> Double {
            min(32_767, max(0, (value * 32_768).rounded())) / 32_768
        }
        let point = [quantize((position.x + 1) / 2), quantize((1 - position.y) / 2), quantize(position.z)]
        let sizes = [0.0, 0.2, 0.5, 0.75, 1.0], widths = [0.0, 0.075, 0.25, 0.45, 0.7]
        let quantizedSize = quantize(size)
        let segment = (1..<sizes.count).first { quantizedSize <= sizes[$0] } ?? (sizes.count - 1)
        let fraction = (quantizedSize - sizes[segment - 1]) / (sizes[segment] - sizes[segment - 1])
        let width = widths[segment - 1] + fraction * (widths[segment] - widths[segment - 1])
        guard width >= 0.000025 else { return [Double](repeating: 0, count: 11) }
        let order = exponent(width)
        let axes = (0..<3).map { interpolate(axis: $0, coordinate: point[$0], width: width) }
        let interior = normalized((0..<11).map { axes[0][$0] * axes[1][$0] * axes[2][$0] })
        var boundary = [Double](repeating: 0, count: 11)
        for (axis, coordinate) in [(0, 0.0), (0, 1.0), (1, 0.0), (1, 1.0), (2, 1.0)] {
            let panning = axisGains(axis, at: coordinate)
            let weight = kernel(axis: axis, coordinate: coordinate, centre: point[axis], width: width)
            for channel in 0..<11 {
                var value = power(panning[channel] * weight, order)
                for other in 0..<3 where other != axis { value *= axes[other][channel] }
                boundary[channel] += value
            }
        }
        boundary = normalized(boundary)
        let distance = min(point[0], 1 - point[0], point[1], 1 - point[1], 1 - point[2])
        let interiorWeight = distance / 4 <= width || distance / 4 <= 0.05
            ? distance * distance * distance * 25 / (width * 4) : 1
        var field = normalized((0..<11).map {
            power(max(0, (interiorWeight * interior[$0] + boundary[$0]) / 32), 1 / order)
        })
        let front = field.prefix(3).reduce(0) { $0 + $1 * $1 }
        let rest = field.dropFirst(3).reduce(0) { $0 + $1 * $1 }
        if front + rest > 1e-6 {
            let gain = pow(10, -1.2 * size / 20)
            let scale = sqrt(gain * gain * (front + rest) / (gain * gain * rest + front))
            for channel in field.indices { field[channel] *= scale * (channel < 3 ? 1 : gain) }
        }
        return field
    }

    private static func exponent(_ width: Double) -> Double {
        width <= 0.125 ? 6 : 6.869565010070801 - width * 6.956521987915039
    }

    private static func kernel(axis: Int, coordinate: Double, centre: Double, width: Double) -> Double {
        guard width >= 0.000025 else { return 0 }
        let distance = (coordinate - centre) / 4
        guard abs(distance) <= width else { return 0 }
        let square = (distance / width) * (distance / width)
        let value = exp2Approximation(-0.6328125 * square * square * 26.575424194335938)
        guard value >= pow(2, -32) else { return 0 }
        return value * (axis == 2 ? cos(coordinate * 0.34147748351097107 * 4) : 1)
    }

    private static func power(_ value: Double, _ exponent: Double) -> Double {
        guard value >= Double(Float.leastNormalMagnitude) else { return 0 }
        var scale: Int32 = 0
        let fraction = frexp(value, &scale)
        let log = 6.0214667320251465 * fraction - 3.13381814956665
            - 4.117977619171143 * fraction * fraction
            + 1.231310486793518 * fraction * fraction * fraction + Double(scale)
        return exp2Approximation(log * exponent)
    }

    private static func exp2Approximation(_ value: Double) -> Double {
        let integer = floor(value), fraction = value - integer
        let polynomial = 1 + fraction * 0.686279296875 + fraction * fraction * 0.25482177734375
            + fraction * fraction * fraction * 0.05889892578125
        return ldexp(polynomial, Int32(integer))
    }

    private static func normalized(_ values: [Double]) -> [Double] {
        let norm = max(0.00001, sqrt(values.reduce(0) { $0 + $1 * $1 }))
        return values.map { abs($0) < Double(Float.leastNormalMagnitude) ? 0 : $0 / norm }
    }

    private static func interpolate(axis: Int, coordinate: Double, width: Double) -> [Double] {
        let maximumPosition = axis == 2 ? 3 : 34
        let p = coordinate * Double(maximumPosition), s = width * 19 / 0.7
        let i = min(Int(p), maximumPosition), j = min(Int(s), 19)
        let nextI = min(i + 1, maximumPosition), nextJ = min(j + 1, 19)
        let a = nextI == i ? 0 : p - Double(i), b = nextJ == j ? 0 : s - Double(j)
        let weights = [1 - max(a, b), 1 - max(1 - a, b), 1 - max(a, 1 - b), 1 - max(1 - a, 1 - b)]
        let sum = weights.reduce(0, +)
        let indices = [(i, j), (nextI, j), (i, nextJ), (nextI, nextJ)]
        var result = [Double](repeating: 0, count: 11)
        for channel in 0..<11 {
            for corner in indices.indices {
                let pair = indices[corner]
                let index = (pair.0 * 20 + pair.1) * 11 + channel
                result[channel] += weights[corner] / sum * tables[axis][index]
            }
        }
        return result
    }

    private static func axisGains(_ axis: Int, at value: Double) -> [Double] {
        var output = [Double](repeating: 0, count: 11)
        func apply(_ channels: [Int], _ coordinates: [Double]) {
            if value <= coordinates[0] { output[channels[0]] = 1; return }
            if value >= coordinates[coordinates.count - 1] { output[channels[channels.count - 1]] = 1; return }
            for i in 1..<coordinates.count where value <= coordinates[i] {
                let angle = (value - coordinates[i - 1]) / (coordinates[i] - coordinates[i - 1]) * .pi / 2
                output[channels[i - 1]] = cos(angle)
                output[channels[i]] = sin(angle)
                return
            }
        }
        if axis == 0 {
            apply([0, 2, 1], [0, 0.5, maximum])
            for pair in [[3, 4], [5, 6], [7, 8], [9, 10]] { apply(pair, [0, maximum]) }
        } else if axis == 1 {
            for row in [[0, 3, 5], [1, 4, 6]] { apply(row, [0, 0.5, maximum]) }
            for row in [[7, 9], [8, 10]] { apply(row, [0, maximum]) }
            output[2] = value < 0.5 ? cos(value * .pi) : 0
        } else {
            let floor = value >= maximum ? 0 : cos(value * .pi / 2)
            let ceiling = value >= maximum ? 1 : sin(value * .pi / 2)
            for channel in output.indices { output[channel] = channel < 7 ? floor : ceiling }
        }
        return output
    }
}
