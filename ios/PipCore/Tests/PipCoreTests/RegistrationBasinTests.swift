import Foundation
import Testing
import simd
@testable import PipCore

/// How far off a start may be and still converge: measured on the synthetic room (printed table).
@Suite struct RegistrationBasinTests {
    @Test func basinOfConvergence() throws {
        guard ProcessInfo.processInfo.environment["PIP_BASIN"] != nil else { return }
        var pts: [simd_float3] = []
        func grid(_ a: ClosedRange<Float>, _ b: ClosedRange<Float>, _ f: (Float, Float) -> simd_float3) {
            var u = a.lowerBound; while u <= a.upperBound { var v = b.lowerBound; while v <= b.upperBound { pts.append(f(u, v)); v += 0.04 }; u += 0.04 }
        }
        grid(0...4, 0...4) { simd_float3($0, 0, $1) }
        grid(0...4, 0...2.5) { simd_float3(0, $1, $0) }
        grid(0...4, 0...2.5) { simd_float3(4, $1, $0) }
        grid(0...4, 0...2.5) { simd_float3($0, $1, 0) }
        grid(1.5...2.5, 1...1.8) { simd_float3($0, 0.75, $1) }
        grid(3.2...3.8, 0...1.2) { simd_float3($0, $1, 0.2) }
        grid(0.2...0.8, 0...1.2) { simd_float3(3.2, $1, $0) }
        let target = RegistrationTarget(points: pts)
        let truth = PointRegistration.transform(yaw: 0.6, translation: simd_float3(1, 0, -1))
        let source = VoxelIndex.downsample(pts.filter { simd_distance($0, simd_float3(2.5, 0.8, 1)) < 2.5 }, size: 0.08).map { (truth.inverse * simd_float4($0, 1)).xyz }
        var rows: [String] = []
        for yawErr: Float in [0, 10, 20, 30, 40] {
            var row = String(format: "yaw %2.0f°:", yawErr)
            for tErr: Float in [0, 0.3, 0.6, 0.9, 1.2] {
                let start = PointRegistration.transform(yaw: 0.6 + yawErr * .pi / 180, translation: simd_float3(1 + tErr * 0.8, 0, -1 - tErr * 0.6))
                let r = PointRegistration.align(source: source, target: target, initial: start)
                let ok = r.map { abs($0.yawDegrees - 0.6 * 180 / .pi) < 1 && simd_distance($0.translation, simd_float3(1, 0, -1)) < 0.03 && $0.isMatch } ?? false
                row += ok ? "  ✓" : "  ·"
            }
            rows.append(row)
        }
        print("start off by 0 / 0.3 / 0.6 / 0.9 / 1.2 m\n" + rows.joined(separator: "\n"))
    }

    @Test func manyStartsRecoverFromFarOff() throws {
        var pts: [simd_float3] = []
        func grid(_ a: ClosedRange<Float>, _ b: ClosedRange<Float>, _ f: (Float, Float) -> simd_float3) {
            var u = a.lowerBound; while u <= a.upperBound { var v = b.lowerBound; while v <= b.upperBound { pts.append(f(u, v)); v += 0.04 }; u += 0.04 }
        }
        grid(0...4, 0...4) { simd_float3($0, 0, $1) }
        grid(0...4, 0...2.5) { simd_float3(0, $1, $0) }
        grid(0...4, 0...2.5) { simd_float3(4, $1, $0) }
        grid(0...4, 0...2.5) { simd_float3($0, $1, 0) }
        grid(1.5...2.5, 1...1.8) { simd_float3($0, 0.75, $1) }
        grid(3.2...3.8, 0...1.2) { simd_float3($0, $1, 0.2) }
        grid(0.2...0.8, 0...1.2) { simd_float3(3.2, $1, $0) }
        let target = RegistrationTarget(points: pts)
        // The stored view was taken at (2, 1.4, 3) looking south; the live camera stands 1.1 m
        // further back and looks 35° to the side. Its frame is turned and shifted.
        func cam(_ p: simd_float3, _ h: Float) -> simd_float4x4 {
            let back = simd_float3(-sin(h), 0, -cos(h)), up = simd_float3(0, 1, 0)
            return simd_float4x4(columns: (simd_float4(simd_cross(up, back), 0), simd_float4(up, 0), simd_float4(back, 0), simd_float4(p, 1)))
        }
        let toLive = PointRegistration.transform(yaw: -1.2, translation: simd_float3(3, 0, 1))
        let stored = cam(simd_float3(2, 1.4, 3), .pi)
        let liveWorld = cam(simd_float3(2, 1.4, 3) + simd_float3(0, 0, 1.1) * -1 * -1, .pi + 35 * .pi / 180)
        let live = toLive * liveWorld
        let source = VoxelIndex.downsample(pts.filter { simd_distance($0, simd_float3(2, 0.8, 1.5)) < 2.5 }, size: 0.08).map { (toLive * simd_float4($0, 1)).xyz }
        let single = PointRegistration.align(source: source, target: target, initial: MapLinker.seed(live: live, stored: stored))
        let starts = MapLinker.bestSeeds(MapLinker.seeds(live: live, stored: stored), source: source, target: target, keep: 3)
        let fits = starts.compactMap { PointRegistration.align(source: source, target: target, initial: $0) }.filter(\.isMatch)
        let truth = toLive.inverse
        let p = simd_float3(1, 1, 1)
        let best = try #require(fits.min { $0.rms < $1.rms })
        #expect(simd_distance((best.transform * simd_float4(p, 1)).xyz, (truth * simd_float4(p, 1)).xyz) < 0.02)
        print("one start: \(single?.isMatch == true ? "found" : "missed"); best of 15: \(fits.count) good fits")
    }
}
