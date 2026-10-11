// SPDX-License-Identifier: LicenseRef-Swift-TrueHD-Research
// Copyright (c) B00kerLouis.

import Foundation

/// Source trajectories have their own control-rate clock. Sampling only at AU
/// or video-frame boundaries changes the motion phase, especially at steps.
struct AtmosTrajectorySampler {
    private static let step: UInt64 = 512
    private static let lookahead: UInt64 = 2_048
    private static let decay = exp(-512.0 / (48_000 * 0.025))
    private var clock: UInt64 = 0
    private var state: [ADMPosition]
    private var target: [ADMPosition]

    init(initial: [ADMPosition]) {
        state = initial
        target = initial
    }

    mutating func targets(at frame: UInt64, source: (UInt64) -> [ADMPosition]) -> [ADMPosition] {
        while clock < frame + Self.lookahead {
            target = source(clock == 0 ? 0 : clock - 1)
            precondition(target.count == state.count)
            for i in state.indices {
                state[i].x = Self.decay * state[i].x + (1 - Self.decay) * target[i].x
                state[i].y = Self.decay * state[i].y + (1 - Self.decay) * target[i].y
                state[i].z = Self.decay * state[i].z + (1 - Self.decay) * target[i].z
            }
            clock += Self.step
        }
        // Settle within source-coordinate precision before the much coarser
        // OAMD grid. An asymptotic half-grid value must not keep the wrong code.
        func settled(_ value: Double, _ target: Double) -> Double {
            abs(value - target) <= 1.0 / 32_768 ? target : value
        }
        return zip(state, target).map { value, end in
            ADMPosition(x: settled(value.x, end.x), y: settled(value.y, end.y),
                        z: settled(value.z, end.z))
        }
    }
}
