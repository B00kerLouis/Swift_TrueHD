// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Foundation

struct AtmosAggregatePlan {
    let positions: [ADMPosition]
    let active: [Bool]
    let leaders: [Int]

    func weights(for point: ADMPosition, source: Int) -> [Double] {
        var result = [Double](repeating: 0, count: positions.count)
        let slots = positions.indices.filter { active[$0] }
        guard !slots.isEmpty else { return result }
        if let own = slots.first(where: {
            leaders[$0] == source && AtmosAggregatePlanner.distanceSquared(point, positions[$0]) < 1e-12
        }) {
            result[own] = 1
            return result
        }
        let gains = AtmosImageMixer.weights(for: point, centres: slots.map { positions[$0] },
                                            basisCount: positions.count)
        for (i, slot) in slots.enumerated() { result[slot] = gains[i] }
        return result
    }
}

/// Deterministic spatial aggregation. Slot identity follows a centroid across
/// intervals, rather than the current source-energy ordering. Every non-LFE
/// slot may follow sources throughout the room. No output slot denotes an
/// independent original object track.
enum AtmosAggregatePlanner {
    // One horizontal wire-position step in normalized room coordinates.
    private static let coincidentDistanceSquared = 1.0 / (62 * 62)
    static func distanceSquared(_ a: ADMPosition, _ b: ADMPosition) -> Double {
        let x = (a.x - b.x) / 2, y = (a.y - b.y) / 2, z = a.z - b.z
        return x * x + y * y + z * z
    }

    static func quantize(_ position: ADMPosition) -> ADMPosition {
        let p = position.clamped()
        // The metadata bridge has Q15 room-coordinate precision before the
        // coarser signed OAMD grid. Skipping this stage changes half-grid
        // decisions even for a single moving source.
        func coordinate(_ value: Double) -> Double {
            min(32_767, max(0, (value * 32_768).rounded())) / 32_768
        }
        let x = coordinate((p.x + 1) / 2) * 2 - 1
        let y = 1 - coordinate((1 - p.y) / 2) * 2
        let z = coordinate(p.z)
        return ADMPosition(x: (x * 31).rounded() / 31,
                           y: (y * 31).rounded() / 31,
                           z: (z * 15).rounded() / 15)
    }

    static func weights(for point: ADMPosition, centres: [ADMPosition], minimumGain: Double = 1e-6) -> [Double] {
        let p = unitPosition(point)
        var unique = [Int]()
        for index in centres.indices {
            // Cluster coverage and gain solving use different tolerances.
            // Nearby centres may still span different speaker directions;
            // removing one here can discard the only elevated direction.
            if !unique.contains(where: { distanceSquared(centres[$0], centres[index]) < 1e-12 }) {
                unique.append(index)
            }
        }
        var result = Array(repeating: 0.0, count: centres.count)
        if let exact = unique.first(where: { distanceSquared(point, centres[$0]) < 1e-12 }) {
            result[exact] = 1
            return result
        }
        // Minimize coordinate error and gain spread with a distance-weighted
        // diagonal regularizer. The rank-four form avoids an N-by-N inversion
        // for each source while retaining the same positive-definite system.
        let vectors = unique.map { index -> [Double] in
            let c = unitPosition(centres[index])
            return [1, c.x - p.x, c.y - p.y, c.z - p.z]
        }
        let inverse = vectors.map { 1 / max(1e-14, 0.01 * ($0[1] * $0[1] + $0[2] * $0[2] + $0[3] * $0[3])) }
        var matrix = Array(repeating: Array(repeating: 0.0, count: 5), count: 4)
        for row in 0..<4 {
            matrix[row][row] = 1
            for source in vectors.indices {
                for column in 0..<4 {
                    matrix[row][column] += inverse[source] * vectors[source][row] * vectors[source][column]
                }
                matrix[row][4] += inverse[source] * vectors[source][row]
            }
        }
        for column in 0..<4 {
            let pivot = (column..<4).max { abs(matrix[$0][column]) < abs(matrix[$1][column]) }!
            matrix.swapAt(column, pivot)
            let divisor = matrix[column][column]
            guard divisor.isFinite, abs(divisor) > 1e-16 else { return nearestWeights(for: point, centres: centres) }
            for j in column..<5 { matrix[column][j] /= divisor }
            for row in 0..<4 where row != column {
                let multiplier = matrix[row][column]
                for j in column..<5 { matrix[row][j] -= multiplier * matrix[column][j] }
            }
        }
        for i in vectors.indices {
            let dot = (0..<4).reduce(0.0) { $0 + vectors[i][$1] * matrix[$1][4] }
            result[unique[i]] = max(0, inverse[i] * (1 - dot))
        }
        // Normalize the rendered field, not the independently summed element
        // powers: correlated feeds can otherwise make the aggregate too loud.
        var field = Array(repeating: 0.0, count: 12)
        for i in unique where result[i] > 0 {
            let c = unitPosition(centres[i])
            let xs = [cos(c.x * .pi / 2), sin(c.x * .pi / 2)]
            let ys = [cos(c.y * .pi / 2), sin(c.y * .pi / 2)]
            let z = sin(c.z * .pi / 2)
            let zs = [max(0, z), max(0, -z), cos(c.z * .pi / 2)]
            for x in 0..<2 { for y in 0..<2 { for height in 0..<3 {
                field[(x * 2 + y) * 3 + height] += result[i] * xs[x] * ys[y] * zs[height]
            } } }
        }
        let norm = sqrt(field.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-12 else { return nearestWeights(for: point, centres: centres) }
        return result.map { $0 / norm < minimumGain ? 0 : $0 / norm }
    }

    private static func unitPosition(_ point: ADMPosition) -> ADMPosition {
        ADMPosition(x: (point.x + 1) / 2, y: (1 - point.y) / 2, z: point.z)
    }

    private static func nearestWeights(for point: ADMPosition, centres: [ADMPosition]) -> [Double] {
        let distances = centres.map { distanceSquared(point, $0) }
        let nearest = distances.indices.sorted {
            distances[$0] == distances[$1] ? $0 < $1 : distances[$0] < distances[$1]
        }
        var result = Array(repeating: 0.0, count: centres.count)
        guard let first = nearest.first else { return result }
        if distances[first] < 0.000_001 { result[first] = 1; return result }
        // A spatial aggregate is a sum of its assigned sources. Spreading a
        // source over several independently rendered centroids leaks energy
        // into zones that were silent in the original scene.
        result[first] = 1
        return result
    }

    static func update(centres: inout [ADMPosition],
                       points: [ADMPosition], energy: [Double],
                       leaders: inout [Int], bands: [[Float]]? = nil) -> AtmosAggregatePlan {
        precondition(points.count == energy.count && centres.count >= 11)
        if let bands {
            return spectralUpdate(centres: &centres, points: points, bands: bands, leaders: &leaders)
        }
        let previous = centres
        let slots = centres.count
        precondition(leaders.count == slots)
        let previousLeaders = leaders
        var seedSources = [Int]()
        var candidates = [ADMPosition]()
        // Weighted farthest-point seeds allocate the finite budget to spatial
        // detail which the compatibility anchors do not already represent.
        for _ in 0..<slots {
            var best: Int?, score = 0.0
            for source in points.indices where energy[source] > 0 {
                let distance = candidates.map { distanceSquared(points[source], $0) }.min() ?? 1
                let value = distance * energy[source]
                if value > score { best = source; score = value }
            }
            if let best { candidates.append(points[best]); seedSources.append(best) }
            else { candidates.append(previous[seedSources.count]); seedSources.append(-1) }
        }
        centres = candidates
        var assignedPower = [Double](repeating: 0, count: centres.count)
        var nextLeaders = [Int](repeating: -1, count: centres.count)
        func destination(_ source: Int, _ positions: [ADMPosition]) -> Int {
            let distances = positions.map { distanceSquared(points[source], $0) }
            let nearest = distances.indices.min { distances[$0] < distances[$1] }!
            if let owned = seedSources.firstIndex(of: source), distances[owned] <= distances[nearest] + 1e-12 {
                return owned
            }
            return nearest
        }
        for _ in 0..<6 {
            var sums = Array(repeating: ADMPosition.centre, count: centres.count)
            var powers = Array(repeating: 0.0, count: centres.count)
            var dominantPower = powers
            nextLeaders = [Int](repeating: -1, count: centres.count)
            for source in points.indices where energy[source] > 0 {
                let slot = destination(source, centres)
                let weight = energy[source]
                sums[slot].x += points[source].x * weight
                sums[slot].y += points[source].y * weight
                sums[slot].z += points[source].z * weight
                powers[slot] += weight
                if weight > dominantPower[slot] {
                    dominantPower[slot] = weight
                    nextLeaders[slot] = source
                }
            }
            for slot in centres.indices where powers[slot] > 0 {
                let mass = powers[slot]
                let point = ADMPosition(x: sums[slot].x / mass, y: sums[slot].y / mass,
                                        z: sums[slot].z / mass)
                centres[slot] = point.clamped()
            }
            assignedPower = powers
        }
        let next = centres
        let nextDynamicLeaders = nextLeaders
        let assignment = minimumAssignment(previous: previous, next: next,
                                           previousLeaders: previousLeaders, nextLeaders: nextDynamicLeaders)
        var active = [Bool]()
        var orderedLeaders = [Int]()
        centres = []
        for (slot, incoming) in assignment.enumerated() {
            let isActive = assignedPower[incoming] > 0
            if isActive { leaders[slot] = nextDynamicLeaders[incoming] }
            centres.append(isActive ? next[incoming] : previous[slot])
            active.append(isActive)
            orderedLeaders.append(isActive ? leaders[slot] : -1)
        }
        return AtmosAggregatePlan(positions: centres, active: active, leaders: orderedLeaders)
    }

    /// Select spatial coverage by critical-band loudness, then refine the
    /// selected coordinates using the same positive gain model as the mixer.
    /// Broadband energy alone lets one bass-heavy source monopolize the budget.
    private static func spectralUpdate(centres: inout [ADMPosition], points: [ADMPosition],
                                        bands: [[Float]], leaders: inout [Int]) -> AtmosAggregatePlan {
        let count = centres.count
        let previous = centres, previousLeaders = leaders
        precondition(bands.count == points.count && bands.allSatisfy { $0.count == 24 })
        let power = bands.map { $0.reduce(Float(0), +) }
        let sources = points.indices.filter { power[$0] >= 0.5 }
        let radius = Float(0.2) * sqrt(Float(11) / Float(count))
        let radiusSquared = radius * radius
        let unit = sources.map { i -> SIMD3<Float> in
            let p = unitPosition(points[i])
            return SIMD3(Float(p.x), Float(p.y), Float(p.z))
        }
        let speakerGains = sources.map { AtmosSpeakerBasis.gains(at: points[$0], count: count).map(Float.init) }
        var importance = sources.map { bands[$0].reduce(Float(0)) { $0 + pow(max(0, $1), 0.2) } }
        var speakerImportance = [Float](repeating: 0, count: count)
        for source in sources.indices {
            for speaker in 0..<count {
                let gain = speakerGains[source][speaker]
                speakerImportance[speaker] += gain * gain * importance[source]
            }
        }
        var represented = [Float](repeating: 0, count: count)
        var visited = [Bool](repeating: false, count: count)
        var coverage = [[Float]](repeating: [Float](repeating: 0, count: sources.count), count: sources.count)
        var conflicting = [[Bool]](repeating: [Bool](repeating: false, count: sources.count), count: sources.count)
        for i in sources.indices {
            for j in sources.indices {
                let delta = unit[i] - unit[j]
                let distance = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
                coverage[i][j] = max(0.001, cos(min(1, distance / radiusSquared) * Float.pi / 2))
                let firstOnly = (0..<count).contains { speakerGains[i][$0] > 0 && speakerGains[j][$0] == 0 }
                let secondOnly = (0..<count).contains { speakerGains[j][$0] > 0 && speakerGains[i][$0] == 0 }
                conflicting[i][j] = firstOnly && secondOnly
                if conflicting[i][j] { coverage[i][j] = max(0.001, coverage[i][j] * 0.95) }
            }
            coverage[i][i] = 1
        }
        var residual = sources.map { bands[$0] }
        var total = [Float](repeating: 0, count: 24)
        for row in residual { for band in 0..<24 { total[band] += row[band] } }
        func loudness(_ value: Float) -> Float { 2 * pow(1 + max(0, value), 0.2) }
        let reference = total.map(loudness)
        var remaining = Array(sources.indices)
        var selected = [Int]()
        while selected.count < count && !remaining.isEmpty {
            var scores = [Int: Float]()
            var maximum = -Float.infinity
            for candidate in remaining {
                var covered = [Float](repeating: 0, count: 24)
                for source in remaining {
                    let gain = coverage[candidate][source]
                    for band in 0..<24 { covered[band] += residual[source][band] * gain }
                }
                let retention: Float = previousLeaders.contains(sources[candidate]) ? 6 : 1
                var score: Float = 0
                for band in 0..<24 { score += reference[band] - loudness(total[band] - retention * covered[band]) }
                scores[candidate] = score
            }
            // Give each audible speaker direction a chance to retain a source
            // before spending the remaining budget on additional spatial detail.
            if let speaker = (0..<count).first(where: { speaker in
                !visited[speaker] && represented[speaker] * (1 + Float.ulpOfOne) < 0.6
                    && remaining.contains { speakerGains[$0][speaker] > 0 && (scores[$0] ?? 0) > 0 }
            }) {
                for source in remaining {
                    let gain = speakerGains[source][speaker]
                    scores[source] = (scores[source] ?? 0) * gain * gain
                }
                visited[speaker] = true
            }
            maximum = remaining.map { scores[$0] ?? -.infinity }.max() ?? -.infinity
            let tied = remaining.filter { (scores[$0] ?? -.infinity) >= maximum - 0.01 }
            guard let best = tied.max(by: {
                importance[$0] == importance[$1] ? sources[$0] > sources[$1]
                    : importance[$0] < importance[$1]
            }) else { break }
            selected.append(best)
            for source in remaining {
                let remainder = 1 - coverage[best][source]
                for band in 0..<24 { residual[source][band] *= remainder }
                if !conflicting[best][source] {
                    let ratio = pow(remainder, 0.2)
                    for speaker in 0..<count where speakerGains[best][speaker] > 0 {
                        let gain = speakerGains[source][speaker]
                        represented[speaker] += gain * gain * importance[source] * (1 - ratio)
                            / (speakerImportance[speaker] + Float.ulpOfOne)
                    }
                    importance[source] *= ratio
                }
            }
            remaining.removeAll { source in
                residual[source].reduce(0, +) <= 0.5
                    || distanceSquared(points[sources[source]], points[sources[best]]) <= coincidentDistanceSquared
            }
        }
        let seeds = selected.map { points[sources[$0]] }
        var sums = [SIMD3<Float>](repeating: .zero, count: seeds.count)
        var masses = [Float](repeating: 0, count: seeds.count)
        // Refinement is needed only when the finite element budget leaves
        // uncovered candidates. Preserve selected positions after full coverage.
        for (index, source) in sources.enumerated() where !seeds.isEmpty && !remaining.isEmpty {
            let gains = weights(for: points[source], centres: seeds, minimumGain: 0).map(Float.init)
            let sum = gains.reduce(0, +) + Float(2.22e-16)
            let importance = bands[source].reduce(Float(0)) { $0 + pow(max(0, $1), 0.2) }
            for slot in seeds.indices {
                let value = gains[slot] / sum * importance
                let weight = value * value
                sums[slot] += unit[index] * weight
                masses[slot] += weight
            }
        }
        var next = seeds.enumerated().map { slot, point -> ADMPosition in
            guard masses[slot] > 0 else { return point }
            let p = sums[slot] / masses[slot]
            return ADMPosition(x: Double(p.x) * 2 - 1, y: 1 - Double(p.y) * 2, z: Double(p.z)).clamped()
        }
        let activeCount = next.count
        var nextLeaders = selected.map { sources[$0] }
        while next.count < count { next.append(previous[next.count]); nextLeaders.append(-1) }
        let assignment = minimumAssignment(previous: previous, next: next,
                                           previousLeaders: previousLeaders, nextLeaders: nextLeaders)
        var active = [Bool](), outputLeaders = [Int]()
        centres = []
        for (slot, incoming) in assignment.enumerated() {
            let used = incoming < activeCount
            if used { leaders[slot] = nextLeaders[incoming] }
            centres.append(used ? next[incoming] : previous[slot])
            active.append(used)
            outputLeaders.append(used ? leaders[slot] : -1)
        }
        return AtmosAggregatePlan(positions: centres, active: active, leaders: outputLeaders)
    }

    /// Associate the closest available source/slot pair first. Unoccupied
    /// slots retain their last position and identity until they are reused.
    /// The tie order is stable, including near-coincident Float coordinates.
    private static func minimumAssignment(previous: [ADMPosition], next: [ADMPosition],
                                          previousLeaders: [Int], nextLeaders: [Int]) -> [Int] {
        let count = previous.count
        var availableSlots = [Bool](repeating: true, count: count)
        var availableSources = nextLeaders.map { $0 >= 0 }
        var result = [Int](repeating: -1, count: count)
        let activeCount = availableSources.filter { $0 }.count
        for _ in 0..<activeCount {
            var minimum = Float.infinity, selectedSlot = -1, selectedSource = -1
            for slot in 0..<count where availableSlots[slot] {
                for source in 0..<count where availableSources[source] {
                    let a = previous[slot], b = next[source]
                    let x = Float((a.x + 1) / 2) - Float((b.x + 1) / 2)
                    let y = Float((1 - a.y) / 2) - Float((1 - b.y) / 2)
                    let z = Float(a.z) - Float(b.z)
                    let distance = x * x + y * y + z * z
                    let cost = distance + (previousLeaders[slot] == nextLeaders[source] ? Float(0) : 20)
                    if cost < minimum { minimum = cost; selectedSlot = slot; selectedSource = source }
                }
            }
            precondition(selectedSlot >= 0 && selectedSource >= 0)
            result[selectedSlot] = selectedSource
            availableSlots[selectedSlot] = false
            availableSources[selectedSource] = false
        }
        let emptySources = nextLeaders.indices.filter { nextLeaders[$0] < 0 }
        let emptySlots = result.indices.filter { result[$0] < 0 }
        for (slot, source) in zip(emptySlots, emptySources) { result[slot] = source }
        return result
    }
}
