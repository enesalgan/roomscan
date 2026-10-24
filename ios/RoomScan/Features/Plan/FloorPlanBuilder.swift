import Foundation
import RoomPlan
import simd

/// Converts RoomPlan's CapturedRoom into our editable FloorPlan (top-down, meters).
/// Room outline comes from RoomPlan's own floor polygon (reliable); openings and objects
/// are placed by their world positions. Falls back to chaining wall segments if no floor polygon.
enum FloorPlanBuilder {

    static func build(from room: CapturedRoom) -> FloorPlan? {
        let segments = room.walls.map { endpoints(of: $0) }
        guard !segments.isEmpty else { return nil }

        var outline = floorPolygon(room, wallSegments: segments)
        if outline == nil || outline!.count < 3 { outline = chain(segments) }
        guard let corners = outline, corners.count >= 3 else { return nil }

        var plan = FloorPlan(corners: corners)
        plan.inferredWalls = inferredEdges(corners, wallSegments: segments)
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
        return plan.straightened()
    }

    // MARK: - Floor polygon (RoomPlan ≥ iOS 17)

    /// Returns the floor outline in world XZ. polygonCorners may be local or world space depending on OS
    /// version, so both interpretations are tried and the one matching the walls' footprint wins.
    private static func floorPolygon(_ room: CapturedRoom, wallSegments: [(PlanPoint, PlanPoint)]) -> [PlanPoint]? {
        guard let floor = room.floors.max(by: { $0.polygonCorners.count < $1.polygonCorners.count }),
              floor.polygonCorners.count >= 3 else { return nil }

        let raw = floor.polygonCorners
        let local = raw.map { PlanPoint(x: Double($0.x), y: Double($0.z)) }
        let localXY = raw.map { PlanPoint(x: Double($0.x), y: Double($0.y)) }
        let world = raw.map { p -> PlanPoint in
            let w = floor.transform * simd_float4(p.x, p.y, p.z, 1)
            return PlanPoint(x: Double(w.x), y: Double(w.z))
        }

        var pts: [PlanPoint] = []
        for s in wallSegments { pts.append(s.0); pts.append(s.1) }
        let target = bbox(pts)

        func score(_ c: [PlanPoint]) -> Double {
            let b = bbox(c)
            let dc = (b.center - target.center).length
            let ds = abs(b.size.x - target.size.x) + abs(b.size.y - target.size.y)
            return dc + ds
        }
        let best = [world, local, localXY].min { score($0) < score($1) }!
        guard score(best) < max(target.size.x, target.size.y) * 0.75 + 0.5 else { return nil }
        return dedupe(best)
    }

    private static func bbox(_ pts: [PlanPoint]) -> (center: PlanPoint, size: PlanPoint) {
        guard let f = pts.first else { return (.init(x: 0, y: 0), .init(x: 0, y: 0)) }
        var mn = f, mx = f
        for p in pts { mn.x = min(mn.x, p.x); mn.y = min(mn.y, p.y); mx.x = max(mx.x, p.x); mx.y = max(mx.y, p.y) }
        return (PlanPoint(x: (mn.x + mx.x) / 2, y: (mn.y + mx.y) / 2), mx - mn)
    }

    private static func dedupe(_ pts: [PlanPoint]) -> [PlanPoint] {
        var out: [PlanPoint] = []
        for p in pts where out.last.map({ $0.distance(to: p) > 0.02 }) ?? true { out.append(p) }
        if out.count > 1, out.first!.distance(to: out.last!) < 0.02 { out.removeLast() }
        return out
    }

    /// Polygon edges with no scanned wall lying along them → inferred (unscanned) walls.
    private static func inferredEdges(_ corners: [PlanPoint], wallSegments: [(PlanPoint, PlanPoint)]) -> [Int] {
        var out: [Int] = []
        for i in 0..<corners.count {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let dir = (b - a).normalized, len = a.distance(to: b)
            guard len > 0.05 else { continue }
            var covered = 0.0
            for (s0, s1) in wallSegments {
                let wd = (s1 - s0).normalized
                guard abs(wd.dot(dir)) > 0.9 else { continue }                 // parallel-ish
                let mid = (s0 + s1) * 0.5
                let t = (mid - a).dot(dir)
                let dist = (mid - (a + dir * t)).length
                guard dist < 0.35 else { continue }                              // on the edge line
                let t0 = min(max((s0 - a).dot(dir), 0), len), t1 = min(max((s1 - a).dot(dir), 0), len)
                covered += abs(t1 - t0)
            }
            if covered < len * 0.4 { out.append(i) }
        }
        return out
    }

    // MARK: - Fallback: chain wall segments

    private static func endpoints(of wall: CapturedRoom.Surface) -> (PlanPoint, PlanPoint) {
        let t = wall.transform
        let c = PlanPoint(x: Double(t.columns.3.x), y: Double(t.columns.3.z))
        let ax = PlanPoint(x: Double(t.columns.0.x), y: Double(t.columns.0.z)).normalized
        let half = Double(wall.dimensions.x) / 2
        return (c - ax * half, c + ax * half)
    }

    /// Orders wall segments into a loop by walking to the nearest free endpoint, preferring
    /// continuations that keep turning the same way; returns one corner per wall.
    private static func chain(_ segs: [(PlanPoint, PlanPoint)]) -> [PlanPoint]? {
        guard segs.count >= 3 else { return nil }
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
        // Consecutive walls that touch → one shared corner (line intersection).
        // Walls with a gap between them (unscanned side) → keep both free ends; the straight
        // edge between them becomes an inferred wall instead of collapsing to a point.
        var corners: [PlanPoint] = []
        for i in 0..<ordered.count {
            let prev = ordered[(i - 1 + ordered.count) % ordered.count]
            let cur = ordered[i]
            let gap = prev.1.distance(to: cur.0)
            if gap < 0.45, let x = intersect(prev, cur) {
                corners.append(x)
            } else if gap < 0.45 {
                corners.append((prev.1 + cur.0) * 0.5)
            } else {
                corners.append(prev.1)
                corners.append(cur.0)
            }
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
        guard point.distance(to: s1.1) < 1.0, point.distance(to: s2.0) < 1.0 else { return nil }
        return point
    }
}
