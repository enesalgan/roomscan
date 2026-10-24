import UIKit

/// Builds the customer-facing PDF: cover (company + job + room summary), one page per room
/// (plan, elevations, opening list), photos, notes. Company header/footer and optional watermark on every page.
enum JobReportPDF {
    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter
    static let margin: CGFloat = 40
    static let accent = UIColor(red: 0, green: 0.42, blue: 0.9, alpha: 1)

    struct Input {
        var job: Job
        var scans: [Scan]
        var photos: [(UIImage, String?)]
        var branding: Branding
        var logo: UIImage?
        var preparedBy: String?
    }

    static func generate(_ input: Input) throws -> URL {
        let name = input.job.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) — RoomScan.pdf")
        let fmt = UIGraphicsPDFRendererFormat()
        fmt.documentInfo = [kCGPDFContextTitle as String: input.job.title, kCGPDFContextCreator as String: "RoomScan"]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: fmt)
        var pageNo = 0
        try renderer.writePDF(to: url) { r in
            func newPage() { r.beginPage(); pageNo += 1; chrome(r.cgContext, input, pageNo) }

            // ── Cover ─────────────────────────────────────────────
            newPage()
            var y = cover(r.cgContext, input)
            let rooms = input.scans.filter { $0.plan != nil }
            if rooms.count > 1 {
                y = heading("Floor plan", y: y + 18)
                let h = min(page.height - margin - 40 - y, 330)
                floorMap(r.cgContext, input.job, rooms, in: CGRect(x: margin, y: y, width: page.width - 2 * margin, height: h))
            }

            // ── Rooms ─────────────────────────────────────────────
            for scan in rooms {
                guard let plan = scan.plan else { continue }
                newPage()
                var y = margin + 50
                y = title(scan.name, sub: "\(Measure.ftIn(plan.width)) × \(Measure.ftIn(plan.depth))  ·  \(plan.area.squareFeet)  ·  " + String(localized: "Ceiling") + " \(Measure.ftIn(plan.wallHeight))", y: y)
                let planH: CGFloat = 330
                PlanRenderer.drawPlan(plan, in: CGRect(x: margin, y: y, width: page.width - 2 * margin, height: planH), ctx: r.cgContext, accent: accent)
                y += planH + 8
                // elevations of walls with openings
                let walls = (0..<plan.wallCount).filter { !plan.openings(on: $0).isEmpty }
                if !walls.isEmpty {
                    y = heading(String(localized: "Wall elevations"), y: y)
                    let cols = 2, cw = (page.width - 2 * margin - 12) / 2, ch: CGFloat = 120
                    for (k, w) in walls.enumerated() {
                        if y + ch > page.height - margin - 30 { newPage(); y = margin + 50 }
                        let x = margin + CGFloat(k % cols) * (cw + 12)
                        let rect = CGRect(x: x, y: y, width: cw, height: ch)
                        PlanRenderer.text(String(localized: "Wall \(w + 1)"), at: CGPoint(x: rect.minX + 22, y: rect.minY + 6), size: 8, color: .darkGray, bold: true)
                        PlanRenderer.drawElevation(plan, wall: w, in: rect.insetBy(dx: 4, dy: 10), ctx: r.cgContext, accent: accent)
                        if k % cols == cols - 1 || k == walls.count - 1 { y += ch + 6 }
                    }
                }
                // openings table
                if !plan.openings.isEmpty {
                    if y + 60 > page.height - margin - 30 { newPage(); y = margin + 50 }
                    y = heading(String(localized: "Doors & windows"), y: y)
                    let cols: [(String, CGFloat)] = [(String(localized: "Wall"), 50), (String(localized: "Type"), 120), (String(localized: "Width"), 80),
                                                     (String(localized: "Height"), 80), (String(localized: "Sill"), 80), (String(localized: "From left"), 90)]
                    y = tableHeader(cols, y: y)
                    for o in plan.openings.sorted(by: { ($0.wall, $0.offset) < ($1.wall, $1.offset) }) {
                        if y + 16 > page.height - margin - 30 { newPage(); y = margin + 50; y = tableHeader(cols, y: y) }
                        let st = OpeningCatalog.style(for: o)
                        y = tableRow(["\(o.wall + 1)", String(localized: String.LocalizationValue(st.name)), Measure.ftIn(o.width), Measure.ftIn(o.height),
                                      o.kind == .door ? "—" : Measure.ftIn(o.sill), Measure.ftIn(o.left)], cols, y: y)
                    }
                }
            }

            // ── Photos ────────────────────────────────────────────
            if !input.photos.isEmpty {
                newPage()
                var y = margin + 50
                y = title(String(localized: "Photos"), sub: "\(input.photos.count)", y: y)
                let cols = 2, cw = (page.width - 2 * margin - 14) / 2, ch: CGFloat = 200
                for (k, (img, cap)) in input.photos.enumerated() {
                    if y + ch > page.height - margin - 30 { newPage(); y = margin + 50 }
                    let x = margin + CGFloat(k % cols) * (cw + 14)
                    let rect = CGRect(x: x, y: y, width: cw, height: ch - 18)
                    let fitted = aspectFit(img.size, in: rect)
                    r.cgContext.saveGState()
                    r.cgContext.addPath(UIBezierPath(roundedRect: fitted, cornerRadius: 6).cgPath); r.cgContext.clip()
                    img.draw(in: fitted)
                    r.cgContext.restoreGState()
                    if let cap, !cap.isEmpty {
                        (cap as NSString).draw(at: CGPoint(x: x, y: rect.maxY + 3), withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray])
                    }
                    if k % cols == cols - 1 || k == input.photos.count - 1 { y += ch + 4 }
                }
            }

            // ── Notes ─────────────────────────────────────────────
            if let n = input.job.notes?.nilIfEmpty {
                newPage()
                var y = margin + 50
                y = title(String(localized: "Notes"), sub: nil, y: y)
                (n as NSString).draw(in: CGRect(x: margin, y: y, width: page.width - 2 * margin, height: page.height - y - margin - 30),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 10.5), .foregroundColor: UIColor.black])
            }
        }
        return url
    }

    // MARK: Page chrome

    private static func chrome(_ ctx: CGContext, _ input: Input, _ pageNo: Int) {
        let b = input.branding
        // watermark
        if b.watermark {
            ctx.saveGState()
            if let logo = input.logo {
                let side: CGFloat = 320
                let fitted = aspectFit(logo.size, in: CGRect(x: page.midX - side / 2, y: page.midY - side / 2, width: side, height: side))
                logo.draw(in: fitted, blendMode: .normal, alpha: 0.06)
            } else if let name = b.companyName.nilIfEmpty {
                ctx.translateBy(x: page.midX, y: page.midY); ctx.rotate(by: -.pi / 5)
                let font = UIFont.systemFont(ofSize: 54, weight: .heavy)
                let sz = (name as NSString).size(withAttributes: [.font: font])
                (name as NSString).draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2), withAttributes: [.font: font, .foregroundColor: UIColor.black.withAlphaComponent(0.05)])
            }
            ctx.restoreGState()
        }
        // header
        var x = margin
        if let logo = input.logo {
            let r = aspectFit(logo.size, in: CGRect(x: margin, y: 22, width: 90, height: 30))
            logo.draw(in: CGRect(x: margin, y: 22, width: r.width, height: r.height))
            x += r.width + 10
        }
        let name = b.companyName.nilIfEmpty ?? "RoomScan"
        (name as NSString).draw(at: CGPoint(x: x, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.black])
        if let t = b.tagline.nilIfEmpty {
            (t as NSString).draw(at: CGPoint(x: x, y: 38), withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray])
        }
        let contact = [b.phone, b.email, b.website].compactMap { $0.nilIfEmpty }.joined(separator: "  ·  ")
        let cs = (contact as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 8)])
        (contact as NSString).draw(at: CGPoint(x: page.width - margin - cs.width, y: 26), withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray])
        if let a = b.address.nilIfEmpty {
            let asz = (a as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 8)])
            (a as NSString).draw(at: CGPoint(x: page.width - margin - asz.width, y: 38), withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray])
        }
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.15).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: 58)); ctx.addLine(to: CGPoint(x: page.width - margin, y: 58)); ctx.strokePath()
        // footer
        ctx.move(to: CGPoint(x: margin, y: page.height - margin - 14)); ctx.addLine(to: CGPoint(x: page.width - margin, y: page.height - margin - 14)); ctx.strokePath()
        let left = [b.license.nilIfEmpty.map { String(localized: "License") + " \($0)" }, input.job.title, Date().formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: "  ·  ")
        (left as NSString).draw(at: CGPoint(x: margin, y: page.height - margin - 8), withAttributes: [.font: UIFont.systemFont(ofSize: 7.5), .foregroundColor: UIColor.gray])
        let right = String(localized: "Page \(pageNo)") + "  ·  RoomScan"
        let rs = (right as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 7.5)])
        (right as NSString).draw(at: CGPoint(x: page.width - margin - rs.width, y: page.height - margin - 8), withAttributes: [.font: UIFont.systemFont(ofSize: 7.5), .foregroundColor: UIColor.gray])
    }

    // MARK: Cover

    private static func cover(_ ctx: CGContext, _ input: Input) -> CGFloat {
        let job = input.job
        var y: CGFloat = margin + 60
        (String(localized: "Measurement report") as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: accent])
        y += 16
        (job.title as NSString).draw(in: CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 60),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: UIColor.black])
        y += 38
        if !job.addressSummary.isEmpty {
            let full = [job.addressLine1, job.addressLine2, [job.city, job.state].compactMap { $0?.nilIfEmpty }.joined(separator: ", "), job.postalCode].compactMap { $0?.nilIfEmpty }.joined(separator: ", ")
            (full as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray]); y += 18
        }
        y += 10
        var facts: [(String, String)] = []
        if let c = job.customerName?.nilIfEmpty { facts.append((String(localized: "Customer"), c)) }
        if let p = job.customerPhone?.nilIfEmpty { facts.append((String(localized: "Phone"), p)) }
        if let e = job.customerEmail?.nilIfEmpty { facts.append((String(localized: "Email"), e)) }
        if let d = job.scheduledAt { facts.append((String(localized: "Appointment"), d.formatted(date: .abbreviated, time: .shortened))) }
        if let e = job.estimateAmount { facts.append((String(localized: "Estimate"), e.formatted(.currency(code: job.estimateCurrency)))) }
        if let by = input.preparedBy?.nilIfEmpty { facts.append((String(localized: "Prepared by"), by)) }
        facts.append((String(localized: "Date"), Date().formatted(date: .long, time: .omitted)))
        let colW = (page.width - 2 * margin) / 2
        for (k, f) in facts.enumerated() {
            let x = margin + CGFloat(k % 2) * colW, yy = y + CGFloat(k / 2) * 30
            (f.0.uppercased() as NSString).draw(at: CGPoint(x: x, y: yy), withAttributes: [.font: UIFont.systemFont(ofSize: 7, weight: .semibold), .foregroundColor: UIColor.gray])
            (f.1 as NSString).draw(at: CGPoint(x: x, y: yy + 10), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black])
        }
        y += CGFloat((facts.count + 1) / 2) * 30 + 10

        // room summary table
        let rooms = input.scans.filter { $0.plan != nil }
        if !rooms.isEmpty {
            y = heading(String(localized: "Rooms"), y: y)
            let cols: [(String, CGFloat)] = [(String(localized: "Room"), 150), (String(localized: "Size"), 130), (String(localized: "Area"), 80),
                                             (String(localized: "Ceiling"), 70), (String(localized: "Doors"), 50), (String(localized: "Windows"), 55)]
            y = tableHeader(cols, y: y)
            var total = 0.0
            for s in rooms {
                let p = s.plan!
                total += p.area
                y = tableRow([s.name, "\(Measure.ftIn(p.width)) × \(Measure.ftIn(p.depth))", p.area.squareFeet, Measure.ftIn(p.wallHeight),
                              "\(p.summary.doors)", "\(p.summary.windows)"], cols, y: y)
            }
            y = tableRow([String(localized: "Total"), "", total.squareFeet, "", "", ""], cols, y: y, bold: true)
            // single room → draw its plan on the cover too
            if rooms.count == 1, let p = rooms[0].plan {
                let h = min(page.height - margin - 40 - y - 10, 360)
                PlanRenderer.drawPlan(p, in: CGRect(x: margin, y: y + 10, width: page.width - 2 * margin, height: h), ctx: ctx, accent: accent)
                y += h + 10
            }
        }
        return y
    }

    private static func floorMap(_ ctx: CGContext, _ job: Job, _ rooms: [Scan], in rect: CGRect) {
        var placements: [RoomPlacement] = []; var x = 0.0
        for r in rooms {
            placements.append(job.floorLayout?.first(where: { $0.scanId == r.id }) ?? RoomPlacement(scanId: r.id, x: x, y: 0))
            x += (r.plan?.width ?? 3) + 0.6
        }
        var mn = PlanPoint(x: .infinity, y: .infinity), mx = PlanPoint(x: -.infinity, y: -.infinity)
        for r in rooms {
            guard let plan = r.plan, let pl = placements.first(where: { $0.scanId == r.id }) else { continue }
            for c in plan.corners.map({ FloorMapView.transform($0, pl) }) { mn.x = min(mn.x, c.x); mn.y = min(mn.y, c.y); mx.x = max(mx.x, c.x); mx.y = max(mx.y, c.y) }
        }
        guard mn.x.isFinite else { return }
        let scale = min((rect.width - 40) / max(mx.x - mn.x, 1), (rect.height - 40) / max(mx.y - mn.y, 1))
        let ox = rect.midX - (mn.x + mx.x) / 2 * scale, oy = rect.midY - (mn.y + mx.y) / 2 * scale
        for r in rooms {
            guard let plan = r.plan, let pl = placements.first(where: { $0.scanId == r.id }) else { continue }
            func S(_ p: PlanPoint) -> CGPoint { let t = FloorMapView.transform(p, pl); return CGPoint(x: ox + t.x * scale, y: oy + t.y * scale) }
            let path = CGMutablePath(); path.move(to: S(plan.corners[0])); for c in plan.corners.dropFirst() { path.addLine(to: S(c)) }; path.closeSubpath()
            ctx.addPath(path); ctx.setFillColor(UIColor.black.withAlphaComponent(0.04).cgColor); ctx.fillPath()
            ctx.setLineWidth(max(plan.wallThickness * scale, 2)); ctx.setStrokeColor(UIColor.black.cgColor); ctx.addPath(path); ctx.strokePath()
            for o in plan.openings {
                ctx.move(to: S(plan.point(onWall: o.wall, at: o.left))); ctx.addLine(to: S(plan.point(onWall: o.wall, at: o.right)))
                ctx.setStrokeColor(UIColor.white.cgColor); ctx.setLineWidth(max(plan.wallThickness * scale, 2) + 1); ctx.strokePath()
            }
            let c = S(PlanPoint(x: plan.width / 2, y: plan.depth / 2))
            PlanRenderer.text(r.name, at: CGPoint(x: c.x, y: c.y - 6), size: 9, color: .black, bold: true)
            PlanRenderer.text(plan.area.squareFeet, at: CGPoint(x: c.x, y: c.y + 6), size: 7.5, color: .darkGray)
        }
    }

    // MARK: Text helpers

    private static func title(_ t: String, sub: String?, y: CGFloat) -> CGFloat {
        (t as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: UIColor.black])
        if let sub { (sub as NSString).draw(at: CGPoint(x: margin, y: y + 23), withAttributes: [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: UIColor.darkGray]) }
        return y + (sub == nil ? 30 : 42)
    }

    private static func heading(_ t: String, y: CGFloat) -> CGFloat {
        (t.uppercased() as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: accent])
        return y + 16
    }

    private static func tableHeader(_ cols: [(String, CGFloat)], y: CGFloat) -> CGFloat {
        var x = margin
        for c in cols {
            (c.0.uppercased() as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 7, weight: .semibold), .foregroundColor: UIColor.gray]); x += c.1
        }
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.2).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: y + 12)); ctx.addLine(to: CGPoint(x: page.width - margin, y: y + 12)); ctx.strokePath()
        return y + 16
    }

    private static func tableRow(_ cells: [String], _ cols: [(String, CGFloat)], y: CGFloat, bold: Bool = false) -> CGFloat {
        var x = margin
        for (k, c) in cols.enumerated() {
            let s = k < cells.count ? cells[k] : ""
            (s as NSString).draw(in: CGRect(x: x, y: y, width: c.1 - 4, height: 14),
                                 withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: bold ? .semibold : .regular), .foregroundColor: UIColor.black]); x += c.1
        }
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.08).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: y + 15)); ctx.addLine(to: CGPoint(x: page.width - margin, y: y + 15)); ctx.strokePath()
        return y + 17
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let k = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * k, h = size.height * k
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}
