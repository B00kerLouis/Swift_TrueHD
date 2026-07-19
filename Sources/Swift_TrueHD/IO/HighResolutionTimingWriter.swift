// SPDX-License-Identifier: AGPL-3.0-only
//
// Serializes high-resolution timing metadata from the resolved source timeline
// without altering or trimming the corresponding PCM sample sequence.

import Foundation

struct HighResolutionTimingWriter {
    private struct State: Hashable {
        let index: Int
        let timing: UInt64
    }

    private struct Node {
        let state: State
        let bits: [Bool]
    }

    private var initialZeroCount = 5
    private var pendingBits: [Bool] = []
    private var pendingIndex = 0

    mutating func nextBit(outputSample: UInt64) -> Bool {
        if initialZeroCount > 0 {
            initialZeroCount -= 1
            return false
        }

        if pendingIndex == pendingBits.count {
            pendingBits = [true] + Self.serialize(timing: outputSample >> 16)
            pendingIndex = 0
        }

        let bit = pendingBits[pendingIndex]
        pendingIndex += 1
        return bit
    }

    private static func serialize(timing target: UInt64) -> [Bool] {
        var queue = [Node(state: State(index: 6, timing: 0), bits: [])]
        var cursor = 0
        var visited: Set<State> = [queue[0].state]

        while cursor < queue.count {
            let node = queue[cursor]
            cursor += 1

            for bit in [false, true] {
                if node.state.index == 15, !bit {
                    if node.state.timing == target {
                        return node.bits + [false]
                    }
                    continue
                }

                guard let next = transition(from: node.state, bit: bit, target: target),
                      visited.insert(next).inserted else { continue }
                queue.append(Node(state: next, bits: node.bits + [bit]))
            }
        }

        preconditionFailure("Unable to serialize high-resolution output timing")
    }

    private static func transition(
        from state: State,
        bit: Bool,
        target: UInt64
    ) -> State? {
        switch state.index {
        case 6...9:
            if !bit { return State(index: state.index + 1, timing: state.timing) }
            let shift = state.index - 6
            guard let timing = shifted(state.timing, by: shift, adding: 0, limit: target) else {
                return nil
            }
            return State(index: 11, timing: timing)
        case 10:
            guard bit,
                  let timing = shifted(state.timing, by: 4, adding: 0, limit: target) else {
                return nil
            }
            return State(index: 6, timing: timing)
        case 11...14:
            if !bit { return State(index: state.index + 1, timing: state.timing) }
            let shift = state.index - 10
            guard let timing = shifted(
                state.timing,
                by: shift,
                adding: UInt64(1 << (shift - 1)),
                limit: target
            ) else { return nil }
            return State(index: 11, timing: timing)
        case 15:
            guard bit,
                  let timing = shifted(state.timing, by: 5, adding: 16, limit: target) else {
                return nil
            }
            return State(index: 6, timing: timing)
        default:
            return nil
        }
    }

    private static func shifted(
        _ value: UInt64,
        by shift: Int,
        adding addition: UInt64,
        limit: UInt64
    ) -> UInt64? {
        guard value <= UInt64.max >> shift else { return nil }
        let shifted = value << shift
        guard shifted <= UInt64.max - addition else { return nil }
        let result = shifted + addition
        return result <= limit ? result : nil
    }
}
