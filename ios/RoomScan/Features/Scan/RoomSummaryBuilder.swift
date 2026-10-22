import Foundation
import RoomPlan
import simd

/// Turns a CapturedRoom into the compact ScanSummary stored in Postgres (JSONB) so the
/// web designer can show dimensions and counts without parsing the USDZ.
enum RoomSummaryBuilder {

    static func build(from room: CapturedRoom) -> (summary: ScanSummary, floorAreaM2: Double) {
        var s = ScanSummary()
        s.walls = room.walls.count
        s.doors = room.doors.count
        s.windows = room.windows.count
        s.openings = room.openings.count

        var objects: [String: Int] = [:]
        for o in room.objects {
            let key = String(describing: o.category)
            objects[key, default: 0] += 1
        }
        s.objects = objects

        // Wall endpoints projected on the floor plane (x,z) → bounding box + perimeter
        var xs: [Float] = [], zs: [Float] = []
        var perimeter: Float = 0
        var maxHeight: Float = 0
        for wall in room.walls {
            let t = wall.transform
            let center = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let xAxis = simd_normalize(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))
            let half = wall.dimensions.x / 2
            let a = center - xAxis * half
            let b = center + xAxis * half
            xs.append(contentsOf: [a.x, b.x]); zs.append(contentsOf: [a.z, b.z])
            perimeter += wall.dimensions.x
            maxHeight = max(maxHeight, wall.dimensions.y)
        }
        if let minX = xs.min(), let maxX = xs.max(), let minZ = zs.min(), let maxZ = zs.max() {
            s.widthM = Double(maxX - minX)
            s.depthM = Double(maxZ - minZ)
        }
        s.heightM = Double(maxHeight)
        s.perimeterM = Double(perimeter)

        // Floor area: shoelace on floor polygon(s) when available (iOS 17+), else bbox
        var area: Double = 0
        for floor in room.floors {
            let pts = floor.polygonCorners
            if pts.count >= 3 {
                var sum: Float = 0
                for i in 0..<pts.count {
                    let p = pts[i], q = pts[(i + 1) % pts.count]
                    sum += p.x * q.z - q.x * p.z
                }
                area += Double(abs(sum) / 2)
            }
        }
        if area == 0 { area = s.widthM * s.depthM }
        return (s, area)
    }

    /// USDZ + JSON files in a temp directory
    static func export(_ room: CapturedRoom, name: String) throws -> (usdz: URL, json: Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roomscan-export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let usdz = dir.appendingPathComponent("\(UUID().uuidString).usdz")
        try room.export(to: usdz, exportOptions: .parametric)   // clean, editable geometry for the web designer
        let json = try JSONEncoder().encode(room)
        return (usdz, json)
    }
}
