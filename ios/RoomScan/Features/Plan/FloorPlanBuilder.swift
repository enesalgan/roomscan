import Foundation
import RoomPlan
import simd

/// Converts RoomPlan's CapturedRoom into our editable FloorPlan (top-down, meters).
enum FloorPlanBuilder {

    static func build(from room: CapturedRoom) -> FloorPlan? {
        let segments = room.walls.map { endpoints(of: $0) }
        guard segments.count >= 3, let corners = chain(segments) else { return nil }

        var plan = FloorPlan(corners: corners)
        plan.wallHeight = Double(room.walls.map { $0.dimensions.y }.max() ?? 2.44)
        let floorY = Double(room.floors.first?.transform.columns.3.y ?? room.walls.first.map { $0.transform.columns.3.y - $0.dimensions.y / 2 } ?? 0)

        let groups: [(OpeningKind, [CapturedRoom.Surface])] = [(.door, room.doors), (.window, room.windows), (.opening, room.openings)]
        for (kind, surfaces) in groups {
            for s in surfaces {
                let c = s.transform.columns.3
                let center = PlanPoint(x: Double(c.x), y: Double(c.z))
                guard let hit = plan.nearestWall(to: center), hit.distance < 0.6 else { continue }
                let w = Double(s.dimensions.x), h = Double(s.dimensions.y)
                let sill = max(0, Double(c.y) - h / 2 - floorY)
                plan.openings.append(PlanOpening(kind: kind, wall: hit.wall, offset: hit.t, width: w, height: h, sill: sill))
            }
        }
        for i in 0..<plan.wallCount { plan.clampOpenings(on: i) }

        for o in room.objects {
            let c = o.transform.columns.3
            let ax = o.transform.columns.0
            plan.objects.append(PlanObject(
                category: String(describing: o.category),
                center: PlanPoint(x: Double(c.x), y: Double(c.z)),
                width: Double(o.dimensions.x), depth: Double(o.dimensions.z), height: Double(o.dimensions.y),
                rotation: atan2(Double(ax.z), Double(ax.x))))
        }
        return plan
    }

    // MARK: - Geometry helpers

    private static func endpoints(of wall: CapturedRoom.Surface) -> (PlanPoint, PlanPoint) {
        let t = wall.transform
        let c = PlanPoint(x: Double(t.columns.3.x), y: Double(t.columns.3.z))
        let ax = PlanPoint(x: Double(t.columns.0.x), y: Double(t.columns.0.z)).normalized
        let half = Double(wall.dimensions.x) / 2
        return (c - ax * half, c + ax * half)
    }

    /// Orders wall segments into a closed loop and returns one corner per wall
    /// (intersection of consecutive wall lines, or midpoint of the touching ends when nearly parallel).
    private static func chain(_ segs: [(PlanPoint, PlanPoint)]) -> [PlanPoint]? {
        var remaining = Array(segs.indices.dropFirst())
        var ordered: [(PlanPoint, PlanPoint)] = [segs[0]]
        while !remaining.isEmpty {
            let end = ordered.last!.1
            var bestIdx = 0, bestFlip = false, bestDist = Double.infinity
            for (k, idx) in remaining.enumerated() {
                let (a, b) = segs[idx]
                let da = end.distance(to: a), db = end.distance(to: b)
                if da < bestDist { bestDist = da; bestIdx = k; bestFlip = false }
                if db < bestDist { bestDist = db; bestIdx = k; bestFlip = true }
            }
            let (a, b) = segs[remaining[bestIdx]]
            ordered.append(bestFlip ? (b, a) : (a, b))
            remaining.remove(at: bestIdx)
        }
        guard ordered.count >= 3 else { return nil }

        var corners: [PlanPoint] = []
        for i in 0..<ordered.count {
            let prev = ordered[(i - 1 + ordered.count) % ordered.count]
            let cur = ordered[i]
            corners.append(intersect(prev, cur) ?? (prev.1 + cur.0) * 0.5)
        }
        return corners
    }

    private static func intersect(_ s1: (PlanPoint, PlanPoint), _ s2: (PlanPoint, PlanPoint)) -> PlanPoint? {
        let p = s1.0, r = s1.1 - s1.0
        let q = s2.0, s = s2.1 - s2.0
        let denom = r.cross(s)
        guard abs(denom) > 1e-6 * max(r.length * s.length, 1e-9) else { return nil }
        let t = (q - p).cross(s) / denom
        let point = p + r * t
        // sanity: must be near the touching ends, otherwise fall back to midpoint
        guard point.distance(to: s1.1) < 1.0, point.distance(to: s2.0) < 1.0 else { return nil }
        return point
    }
}
