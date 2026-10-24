import Foundation

/// DXF (R12 LINE/TEXT, inches) and SVG export of a floor plan — opens in 2020 Design, AutoCAD, SketchUp, Illustrator.
enum CADExport {
    private static let inch = 39.3700787

    // MARK: DXF

    static func dxf(_ plan: FloorPlan, name: String) -> String {
        var e = ""
        func num(_ v: Double) -> String { String(format: "%.4f", v) }
        func P(_ p: PlanPoint) -> (Double, Double) { (p.x * inch, -p.y * inch) }      // y up in CAD
        func line(_ a: PlanPoint, _ b: PlanPoint, layer: String) {
            let (ax, ay) = P(a), (bx, by) = P(b)
            e += "0\nLINE\n8\n\(layer)\n10\n\(num(ax))\n20\n\(num(ay))\n30\n0\n11\n\(num(bx))\n21\n\(num(by))\n31\n0\n"
        }
        func text(_ s: String, at p: PlanPoint, height: Double = 3, angle: Double = 0, layer: String) {
            let (x, y) = P(p)
            e += "0\nTEXT\n8\n\(layer)\n10\n\(num(x))\n20\n\(num(y))\n30\n0\n40\n\(num(height))\n50\n\(num(angle))\n72\n1\n11\n\(num(x))\n21\n\(num(y))\n31\n0\n1\n\(s)\n"
        }

        // wall centre lines + both faces
        let t = plan.wallThickness / 2
        for i in 0..<plan.wallCount {
            let a = plan.wallStart(i), b = plan.wallEnd(i), n = plan.outwardNormal(i)
            line(a, b, layer: plan.isInferred(i) ? "WALLS_UNSCANNED" : "WALLS")
            line(a + n * t, b + n * t, layer: "WALL_FACES")
            line(a - n * t, b - n * t, layer: "WALL_FACES")
            // dimension text outside the wall
            let mid = plan.wallMid(i) + n * (t + 0.25)
            let d = plan.wallDirection(i)
            var ang = atan2(-d.y, d.x) * 180 / .pi
            if ang > 90 { ang -= 180 } else if ang < -90 { ang += 180 }
            text(Measure.ftIn(plan.wallLength(i)), at: mid, angle: ang, layer: "DIMS")
        }
        // openings: jambs + a line across the opening on its own layer
        for o in plan.openings {
            let a = plan.point(onWall: o.wall, at: o.left), b = plan.point(onWall: o.wall, at: o.right), n = plan.outwardNormal(o.wall)
            let layer = o.kind == .door ? "DOORS" : o.kind == .window ? "WINDOWS" : "OPENINGS"
            line(a + n * t, a - n * t, layer: layer); line(b + n * t, b - n * t, layer: layer)
            line(a, b, layer: layer)
            if o.kind == .door {   // swing
                let inward = plan.inwardNormal(o.wall)
                line(a, a + inward * o.width, layer: layer)
            }
            text("\(Measure.ftIn(o.width)) x \(Measure.ftIn(o.height))" + (o.kind == .window ? " sill \(Measure.ftIn(o.sill))" : ""),
                 at: (a + b) * 0.5 + n * (t + 0.12), height: 2, layer: "DIMS")
        }
        // objects as rotated rectangles
        for o in plan.objects {
            let ax = PlanPoint(x: cos(o.rotation), y: sin(o.rotation)), ay = ax.perp
            let c = [o.center + ax * (o.width / 2) + ay * (o.depth / 2), o.center - ax * (o.width / 2) + ay * (o.depth / 2),
                     o.center - ax * (o.width / 2) - ay * (o.depth / 2), o.center + ax * (o.width / 2) - ay * (o.depth / 2)]
            for k in 0..<4 { line(c[k], c[(k + 1) % 4], layer: "OBJECTS") }
            text(o.category.capitalized, at: o.center, height: 2, layer: "OBJECTS")
        }
        for m in plan.measurements {
            line(m.a, m.b, layer: "DIMS"); text(Measure.ftIn(m.length), at: (m.a + m.b) * 0.5, height: 2, layer: "DIMS")
        }

        let layers = [("WALLS", 7), ("WALLS_UNSCANNED", 8), ("WALL_FACES", 8), ("DOORS", 1), ("WINDOWS", 5), ("OPENINGS", 3), ("OBJECTS", 6), ("DIMS", 4)]
        var out = "999\nRoomScan - \(name) - inches\n0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$INSUNITS\n70\n1\n0\nENDSEC\n"
        out += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n\(layers.count)\n"
        for (l, c) in layers { out += "0\nLAYER\n2\n\(l)\n70\n0\n62\n\(c)\n6\nCONTINUOUS\n" }
        out += "0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n" + e + "0\nENDSEC\n0\nEOF\n"
        return out
    }

    // MARK: SVG

    static func svg(_ plan: FloorPlan, name: String) -> String {
        let b = plan.bounds
        let pad = 1.0
        let minX = (b.min.x - pad) * inch, minY = (b.min.y - pad) * inch
        let w = (b.max.x - b.min.x + 2 * pad) * inch, h = (b.max.y - b.min.y + 2 * pad) * inch
        func X(_ p: PlanPoint) -> String { String(format: "%.2f,%.2f", p.x * inch, p.y * inch) }
        var s = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(String(format: "%.2f %.2f %.2f %.2f", minX, minY, w, h))" width="\(String(format: "%.1fin", w))" height="\(String(format: "%.1fin", h))">
        <title>\(name)</title>
        <g id="floor" fill="#f3f4f6" stroke="none"><polygon points="\(plan.corners.map(X).joined(separator: " "))"/></g>
        <g id="walls" fill="none" stroke="#111" stroke-width="\(String(format: "%.2f", plan.wallThickness * inch))" stroke-linejoin="miter" stroke-linecap="square">

        """
        for i in 0..<plan.wallCount {
            let dash = plan.isInferred(i) ? " stroke-dasharray=\"6 4\" stroke-opacity=\"0.5\"" : ""
            s += "<line x1=\"\(X(plan.wallStart(i)).replacingOccurrences(of: ",", with: "\" y1=\""))\" x2=\"\(X(plan.wallEnd(i)).replacingOccurrences(of: ",", with: "\" y2=\""))\"\(dash)/>\n"
        }
        s += "</g>\n<g id=\"openings\" stroke=\"#111\" stroke-width=\"0.8\">\n"
        for o in plan.openings {
            let a = plan.point(onWall: o.wall, at: o.left), e = plan.point(onWall: o.wall, at: o.right)
            let color = o.kind == .window ? "#38bdf8" : "#fff"
            s += "<line x1=\"\(X(a).replacingOccurrences(of: ",", with: "\" y1=\""))\" x2=\"\(X(e).replacingOccurrences(of: ",", with: "\" y2=\""))\" stroke=\"\(color)\" stroke-width=\"\(String(format: "%.2f", plan.wallThickness * inch + 1))\"/>\n"
            if o.kind == .door {
                let tip = a + plan.inwardNormal(o.wall) * o.width
                s += "<line x1=\"\(X(a).replacingOccurrences(of: ",", with: "\" y1=\""))\" x2=\"\(X(tip).replacingOccurrences(of: ",", with: "\" y2=\""))\"/>\n"
            }
        }
        s += "</g>\n<g id=\"objects\" fill=\"#11111110\" stroke=\"#555\" stroke-width=\"0.5\">\n"
        for o in plan.objects {
            let c = o.center
            s += "<rect x=\"\(String(format: "%.2f", (c.x - o.width / 2) * inch))\" y=\"\(String(format: "%.2f", (c.y - o.depth / 2) * inch))\" width=\"\(String(format: "%.2f", o.width * inch))\" height=\"\(String(format: "%.2f", o.depth * inch))\" transform=\"rotate(\(String(format: "%.2f", o.rotation * 180 / .pi)) \(String(format: "%.2f %.2f", c.x * inch, c.y * inch)))\"/>\n"
        }
        s += "</g>\n<g id=\"dims\" font-family=\"Helvetica, Arial\" font-size=\"3\" fill=\"#0066e6\" text-anchor=\"middle\">\n"
        for i in 0..<plan.wallCount {
            let n = plan.outwardNormal(i), mid = plan.wallMid(i) + n * (plan.wallThickness / 2 + 0.25)
            let d = plan.wallDirection(i)
            var ang = atan2(d.y, d.x) * 180 / .pi
            if ang > 90 { ang -= 180 } else if ang < -90 { ang += 180 }
            s += "<text x=\"\(String(format: "%.2f", mid.x * inch))\" y=\"\(String(format: "%.2f", mid.y * inch))\" transform=\"rotate(\(String(format: "%.1f", ang)) \(String(format: "%.2f %.2f", mid.x * inch, mid.y * inch))\">\(Measure.ftIn(plan.wallLength(i)).replacingOccurrences(of: "\"", with: "&quot;"))</text>\n"
        }
        s += "</g>\n</svg>\n"
        return s
    }

    /// Writes both files to a temp folder and returns their URLs
    static func files(for scan: Scan, plan: FloorPlan, formats: Set<String> = ["dxf", "svg"]) -> [URL] {
        let safe = scan.name.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory
        var out: [URL] = []
        if formats.contains("dxf") {
            let u = dir.appendingPathComponent("\(safe).dxf")
            try? dxf(plan, name: scan.name).write(to: u, atomically: true, encoding: .utf8)
            out.append(u)
        }
        if formats.contains("svg") {
            let u = dir.appendingPathComponent("\(safe).svg")
            try? svg(plan, name: scan.name).write(to: u, atomically: true, encoding: .utf8)
            out.append(u)
        }
        return out
    }
}
