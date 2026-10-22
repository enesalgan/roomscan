import Foundation

// MARK: - Editable floor plan (meters). Plan x = world X, plan y = world Z (top-down view).

struct PlanPoint: Codable, Hashable {
    var x: Double
    var y: Double

    static func + (a: PlanPoint, b: PlanPoint) -> PlanPoint { .init(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: PlanPoint, b: PlanPoint) -> PlanPoint { .init(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: PlanPoint, k: Double) -> PlanPoint { .init(x: a.x * k, y: a.y * k) }
    var length: Double { (x * x + y * y).squareRoot() }
    var normalized: PlanPoint { let l = length; return l > 0 ? self * (1 / l) : .init(x: 1, y: 0) }
    func dot(_ o: PlanPoint) -> Double { x * o.x + y * o.y }
    func cross(_ o: PlanPoint) -> Double { x * o.y - y * o.x }
    func distance(to p: PlanPoint) -> Double { (self - p).length }
    /// Rotated +90° (left normal in a y-down screen space)
    var perp: PlanPoint { .init(x: -y, y: x) }
}

enum OpeningKind: String, Codable, CaseIterable, Identifiable {
    case door, window, opening
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self { case .door: "door.left.hand.closed"; case .window: "window.vertical.closed"; case .opening: "rectangle.portrait" }
        }
    /// Default size when inserted by hand (meters)
    var defaultSize: (width: Double, height: Double, sill: Double) {
        switch self {
        case .door: (0.91, 2.03, 0)
        case .window: (1.22, 1.22, 0.91)
        case .opening: (1.22, 2.03, 0)
        }
    }
}

struct PlanOpening: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: OpeningKind
    var wall: Int
    var offset: Double      // center distance from wall start (m)
    var width: Double
    var height: Double
    var sill: Double        // bottom edge above floor (m)

    var left: Double { offset - width / 2 }
    var right: Double { offset + width / 2 }
}

struct PlanObject: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var category: String
    var center: PlanPoint
    var width: Double
    var depth: Double
    var height: Double
    var rotation: Double    // radians, in plan space
}

struct FloorPlan: Codable, Hashable {
    var corners: [PlanPoint]
    var wallHeight: Double = 2.44
    var wallThickness: Double = 0.12
    var openings: [PlanOpening] = []
    var objects: [PlanObject] = []

    // MARK: Walls

    var wallCount: Int { corners.count }
    func wallStart(_ i: Int) -> PlanPoint { corners[(i + corners.count) % corners.count] }
    func wallEnd(_ i: Int) -> PlanPoint { corners[(i + 1 + corners.count) % corners.count] }
    func wallLength(_ i: Int) -> Double { wallStart(i).distance(to: wallEnd(i)) }
    func wallDirection(_ i: Int) -> PlanPoint { (wallEnd(i) - wallStart(i)).normalized }
    func wallMid(_ i: Int) -> PlanPoint { (wallStart(i) + wallEnd(i)) * 0.5 }
    func point(onWall i: Int, at t: Double) -> PlanPoint { wallStart(i) + wallDirection(i) * t }

    /// Shoelace in plan space (y down on screen). Positive = clockwise on screen.
    var signedArea: Double {
        guard corners.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<corners.count { s += corners[i].cross(corners[(i + 1) % corners.count]) }
        return s / 2
    }
    var area: Double { abs(signedArea) }
    var perimeter: Double { (0..<wallCount).reduce(0) { $0 + wallLength($1) } }

    /// Unit normal pointing out of the room
    func outwardNormal(_ i: Int) -> PlanPoint {
        let left = wallDirection(i).perp
        // For a clockwise polygon (signedArea > 0, screen coords) the interior is on the left side.
        return signedArea > 0 ? left * -1 : left
    }
    func inwardNormal(_ i: Int) -> PlanPoint { outwardNormal(i) * -1 }

    var bounds: (min: PlanPoint, max: PlanPoint) {
        guard let f = corners.first else { return (.init(x: 0, y: 0), .init(x: 0, y: 0)) }
        var mn = f, mx = f
        for c in corners { mn.x = min(mn.x, c.x); mn.y = min(mn.y, c.y); mx.x = max(mx.x, c.x); mx.y = max(mx.y, c.y) }
        return (mn, mx)
    }
    var width: Double { bounds.max.x - bounds.min.x }
    var depth: Double { bounds.max.y - bounds.min.y }

    // MARK: Editing

    /// Moves the END corner of wall i so the wall has the given length (start stays fixed).
    mutating func setWallLength(_ i: Int, _ len: Double) {
        guard len > 0.1 else { return }
        let d = wallDirection(i)
        corners[(i + 1) % corners.count] = wallStart(i) + d * len
        clampOpenings(on: i)
        clampOpenings(on: (i + 1) % corners.count)
    }

    mutating func moveCorner(_ i: Int, to p: PlanPoint) {
        corners[i] = p
        clampOpenings(on: i)
        clampOpenings(on: (i - 1 + corners.count) % corners.count)
    }

    mutating func clampOpenings(on wall: Int) {
        let len = wallLength(wall)
        for k in openings.indices where openings[k].wall == wall {
            let half = openings[k].width / 2
            openings[k].offset = min(max(openings[k].offset, half), max(half, len - half))
        }
    }

    func openings(on wall: Int) -> [PlanOpening] { openings.filter { $0.wall == wall }.sorted { $0.offset < $1.offset } }

    @discardableResult
    mutating func addOpening(_ kind: OpeningKind, on wall: Int) -> PlanOpening {
        let len = wallLength(wall)
        let size = kind.defaultSize
        let w = min(size.width, len * 0.8)
        var o = PlanOpening(kind: kind, wall: wall, offset: len / 2, width: w, height: min(size.height, wallHeight), sill: size.sill)
        // avoid stacking on an existing opening: nudge right until free
        let existing = openings(on: wall)
        var tries = 0
        while existing.contains(where: { abs($0.offset - o.offset) < ($0.width + o.width) / 2 }) && tries < 6 {
            o.offset = min(len - w / 2, o.offset + w); tries += 1
        }
        openings.append(o)
        return o
    }

    /// Nearest wall to a point: (wall index, distance along wall from its start)
    func nearestWall(to p: PlanPoint) -> (wall: Int, t: Double, distance: Double)? {
        guard wallCount >= 2 else { return nil }
        var best: (Int, Double, Double)?
        for i in 0..<wallCount {
            let s = wallStart(i), d = wallDirection(i), len = wallLength(i)
            let t = min(max((p - s).dot(d), 0), len)
            let dist = p.distance(to: s + d * t)
            if best == nil || dist < best!.2 { best = (i, t, dist) }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    // MARK: Derived summary (stored next to the scan for the web app)

    var summary: ScanSummary {
        var s = ScanSummary()
        s.walls = wallCount
        s.doors = openings.filter { $0.kind == .door }.count
        s.windows = openings.filter { $0.kind == .window }.count
        s.openings = openings.filter { $0.kind == .opening }.count
        var objs: [String: Int] = [:]
        for o in objects { objs[o.category, default: 0] += 1 }
        s.objects = objs
        s.widthM = width; s.depthM = depth; s.heightM = wallHeight; s.perimeterM = perimeter
        return s
    }
}

// MARK: - Feet/inches formatting & parsing

enum Measure {
    /// 3.81 m → 12' 6"   (rounded to the nearest 1/4")
    static func ftIn(_ meters: Double) -> String {
        let quarters = (meters * 39.3700787 * 4).rounded()
        var ft = Int(quarters / 48)
        var rem = Int(quarters) - ft * 48      // quarter inches
        if rem < 0 { rem += 48; ft -= 1 }
        let whole = rem / 4, frac = rem % 4
        let fracStr = ["", " 1/4", " 1/2", " 3/4"][frac]
        let inchStr: String = {
            if whole == 0 && frac == 0 { return "" }
            if whole == 0 { return "\(fracStr.trimmingCharacters(in: .whitespaces))\"" }
            return "\(whole)\(fracStr)\""
        }()
        if ft == 0 { return inchStr.isEmpty ? "0\"" : inchStr }
        return inchStr.isEmpty ? "\(ft)'" : "\(ft)' \(inchStr)"
    }

    static func metric(_ meters: Double) -> String {
        meters >= 1 ? String(format: "%.2f m", meters) : String(format: "%.0f cm", meters * 100)
    }

    /// Accepts: 12' 6 1/2"  ·  12'6  ·  12.5 (feet)  ·  78" (inches)  ·  3.2m  ·  320cm
    static func parse(_ raw: String) -> Double? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "”", with: "\"")
             .replacingOccurrences(of: "ft", with: "'").replacingOccurrences(of: "in", with: "\"")
        if s.hasSuffix("cm"), let v = Double(s.dropLast(2).trimmingCharacters(in: .whitespaces)) { return v / 100 }
        if s.hasSuffix("m"), let v = Double(s.dropLast(1).trimmingCharacters(in: .whitespaces)) { return v }

        func inches(_ str: String) -> Double? {
            let t = str.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return 0 }
            var total = 0.0
            for tok in t.split(separator: " ") {
                if tok.contains("/") {
                    let p = tok.split(separator: "/")
                    guard p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b != 0 else { return nil }
                    total += a / b
                } else if let v = Double(tok) { total += v } else { return nil }
            }
            return total
        }

        if let q = s.firstIndex(of: "'") {
            guard let ft = Double(s[..<q].trimmingCharacters(in: .whitespaces)) else { return nil }
            guard let inch = inches(String(s[s.index(after: q)...])) else { return nil }
            return (ft * 12 + inch) * 0.0254
        }
        if s.contains("\"") { return inches(s).map { $0 * 0.0254 } }
        if let v = Double(s) { return v * 0.3048 }   // bare number = feet
        return nil
    }
}
