import Foundation
import Supabase
import UIKit

/// Data access for jobs, scans, photos and time entries.
enum Repository {

    // MARK: Jobs

    static func jobs(includeArchived: Bool = false) async throws -> [Job] {
        if await DemoStore.isActive {
            return await DemoStore.shared.jobs.filter { $0.deletedAt == nil && (includeArchived || $0.status != .archived) }
        }
        var q = supabase.from("jobs").select().is("deleted_at", value: nil)
        if !includeArchived { q = q.neq("status", value: JobStatus.archived.rawValue) }
        return try await q.order("updated_at", ascending: false).execute().value
    }

    static func job(id: UUID) async throws -> Job {
        if await DemoStore.isActive {
            guard let j = await DemoStore.shared.jobs.first(where: { $0.id == id }) else { throw AppError.message("Job not found") }
            return j
        }
        return try await supabase.from("jobs").select().eq("id", value: id).single().execute().value
    }

    static func upsert(_ job: Job) async throws -> Job {
        if await DemoStore.isActive { return await DemoStore.shared.upsert(job) }
        return try await supabase.from("jobs").upsert(job).select().single().execute().value
    }

    static func update(jobId: UUID, status: JobStatus) async throws {
        if await DemoStore.isActive {
            if var j = await DemoStore.shared.jobs.first(where: { $0.id == jobId }) { j.status = status; _ = await DemoStore.shared.upsert(j) }
            return
        }
        try await supabase.from("jobs").update(["status": status.rawValue]).eq("id", value: jobId).execute()
    }

    static func softDelete(jobId: UUID) async throws {
        if await DemoStore.isActive {
            if var j = await DemoStore.shared.jobs.first(where: { $0.id == jobId }) { j.deletedAt = Date(); _ = await DemoStore.shared.upsert(j) }
            return
        }
        try await supabase.from("jobs").update(["deleted_at": ISO8601.withFractional.string(from: Date())])
            .eq("id", value: jobId).execute()
    }

    static func scheduledJobs(from: Date, to: Date) async throws -> [Job] {
        if await DemoStore.isActive {
            return await DemoStore.shared.jobs
                .filter { $0.deletedAt == nil && ($0.scheduledAt.map { $0 >= from && $0 < to } ?? false) }
                .sorted { ($0.scheduledAt ?? .distantPast) < ($1.scheduledAt ?? .distantPast) }
        }
        return try await supabase.from("jobs").select()
            .is("deleted_at", value: nil)
            .gte("scheduled_at", value: ISO8601.withFractional.string(from: from))
            .lt("scheduled_at", value: ISO8601.withFractional.string(from: to))
            .order("scheduled_at").execute().value
    }

    // MARK: Scans

    static func scans(jobId: UUID) async throws -> [Scan] {
        if await DemoStore.isActive { return await DemoStore.shared.scans.filter { $0.jobId == jobId } }
        return try await supabase.from("scans").select().eq("job_id", value: jobId).order("created_at", ascending: false).execute().value
    }

    /// Uploads USDZ + JSON (+ optional thumbnail) and inserts the scan row.
    /// The DB trigger enforces the free-scan allowance; a failure surfaces as AppError.scanLimitReached.
    static func saveScan(_ scan: Scan, usdzURL: URL, jsonData: Data, thumbnail: UIImage?) async throws -> Scan {
        if await DemoStore.isActive {
            return try await DemoStore.shared.saveScan(scan, usdzURL: usdzURL, jsonData: jsonData, thumbnail: thumbnail)
        }
        var scan = scan
        let base = "\(scan.orgId.uuidString.lowercased())/\(scan.jobId.uuidString.lowercased())/\(scan.id.uuidString.lowercased())"
        let usdzPath = base + ".usdz"
        let jsonPath = base + ".json"

        // Insert the row FIRST so the allowance check runs before we spend bandwidth.
        scan.usdzPath = usdzPath
        scan.jsonPath = jsonPath
        if thumbnail != nil { scan.thumbnailPath = base + ".jpg" }
        do {
            scan = try await supabase.from("scans").insert(scan).select().single().execute().value
        } catch {
            throw AppError.from(error)
        }

        let usdzData = try Data(contentsOf: usdzURL)
        try await supabase.storage.from("scans").upload(path: usdzPath, file: usdzData, options: FileOptions(contentType: "model/vnd.usdz+zip", upsert: true))
        try await supabase.storage.from("scans").upload(path: jsonPath, file: jsonData, options: FileOptions(contentType: "application/json", upsert: true))
        if let thumbnail, let jpg = thumbnail.jpegData(compressionQuality: 0.8) {
            try await supabase.storage.from("scans").upload(path: base + ".jpg", file: jpg, options: FileOptions(contentType: "image/jpeg", upsert: true))
        }
        return scan
    }

    static func deleteScan(_ scan: Scan) async throws {
        if await DemoStore.isActive { await DemoStore.shared.deleteScan(scan); return }
        let paths = [scan.usdzPath, scan.jsonPath, scan.thumbnailPath].compactMap { $0 }
        if !paths.isEmpty { _ = try? await supabase.storage.from("scans").remove(paths: paths) }
        try await supabase.from("scans").delete().eq("id", value: scan.id).execute()
    }

    /// Downloads the USDZ to a local cache and returns its URL (for Quick Look / SceneKit)
    static func localUSDZ(for scan: Scan) async throws -> URL {
        guard let path = scan.usdzPath else { throw AppError.message("Scan has no model file") }
        if await DemoStore.isActive { return await DemoStore.shared.fileURL(path) }
        let dest = cacheDir.appendingPathComponent(scan.id.uuidString + ".usdz")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let data = try await supabase.storage.from("scans").download(path: path)
        try data.write(to: dest)
        return dest
    }

    /// Raw CapturedRoom JSON for a scan (used to build the editable floor plan)
    static func scanJSON(for scan: Scan) async throws -> Data {
        guard let path = scan.jsonPath else { throw AppError.message("Scan has no plan data") }
        if await DemoStore.isActive {
            let url = await DemoStore.shared.fileURL(path)
            return try Data(contentsOf: url)
        }
        return try await supabase.storage.from("scans").download(path: path)
    }

    /// Saves edited plan + recomputed summary
    static func updateScan(_ scan: Scan) async throws -> Scan {
        if await DemoStore.isActive { return await DemoStore.shared.updateScan(scan) }
        struct Patch: Encodable {
            let name: String; let plan: FloorPlan?; let summary: ScanSummary; let floor_area_m2: Double?
        }
        return try await supabase.from("scans")
            .update(Patch(name: scan.name, plan: scan.plan, summary: scan.summary, floor_area_m2: scan.floorAreaM2))
            .eq("id", value: scan.id).select().single().execute().value
    }

    // MARK: Photos

    static func photos(jobId: UUID) async throws -> [Photo] {
        if await DemoStore.isActive { return await DemoStore.shared.photos.filter { $0.jobId == jobId } }
        return try await supabase.from("photos").select().eq("job_id", value: jobId).order("created_at").execute().value
    }

    static func addPhoto(jobId: UUID, orgId: UUID, userId: UUID, image: UIImage, caption: String? = nil) async throws -> Photo {
        if await DemoStore.isActive { return try await DemoStore.shared.addPhoto(jobId: jobId, image: image, caption: caption) }
        let id = UUID()
        let path = "\(orgId.uuidString.lowercased())/\(jobId.uuidString.lowercased())/\(id.uuidString.lowercased()).jpg"
        let resized = image.resized(maxDimension: 2048)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { throw AppError.message("Could not encode photo") }
        try await supabase.storage.from("photos").upload(path: path, file: data, options: FileOptions(contentType: "image/jpeg"))
        let photo = Photo(id: id, jobId: jobId, orgId: orgId, createdBy: userId, storagePath: path, caption: caption,
                          width: Int(resized.size.width * resized.scale), height: Int(resized.size.height * resized.scale), takenAt: Date())
        return try await supabase.from("photos").insert(photo).select().single().execute().value
    }

    static func deletePhoto(_ photo: Photo) async throws {
        if await DemoStore.isActive { await DemoStore.shared.deletePhoto(photo); return }
        _ = try? await supabase.storage.from("photos").remove(paths: [photo.storagePath])
        try await supabase.from("photos").delete().eq("id", value: photo.id).execute()
    }

    static func signedURL(bucket: String, path: String, expiresIn: Int = 3600) async throws -> URL {
        if await DemoStore.isActive { return await DemoStore.shared.fileURL(path) }
        return try await supabase.storage.from(bucket).createSignedURL(path: path, expiresIn: expiresIn)
    }

    // MARK: Time entries

    static func timeEntries(jobId: UUID) async throws -> [TimeEntry] {
        if await DemoStore.isActive { return await DemoStore.shared.timeEntries.filter { $0.jobId == jobId } }
        return try await supabase.from("time_entries").select().eq("job_id", value: jobId).order("started_at", ascending: false).execute().value
    }

    static func startTimer(jobId: UUID, orgId: UUID, userId: UUID) async throws -> TimeEntry {
        if await DemoStore.isActive { return await DemoStore.shared.startTimer(jobId: jobId) }
        let entry = TimeEntry(jobId: jobId, orgId: orgId, userId: userId)
        return try await supabase.from("time_entries").insert(entry).select().single().execute().value
    }

    static func stopTimer(_ entry: TimeEntry, note: String? = nil) async throws -> TimeEntry {
        if await DemoStore.isActive { return await DemoStore.shared.stopTimer(entry, note: note) }
        var e = entry
        e.endedAt = Date()
        e.note = note ?? e.note
        return try await supabase.from("time_entries").update(e).eq("id", value: e.id).select().single().execute().value
    }

    // MARK: Members & invites

    static func members() async throws -> [Profile] {
        if await DemoStore.isActive { return await [DemoStore.shared.profile] }
        return try await supabase.from("profiles").select().order("created_at").execute().value
    }

    static func invites() async throws -> [OrgInvite] {
        if await DemoStore.isActive { return [] }
        return try await supabase.from("org_invites").select().is("used_at", value: nil).order("created_at", ascending: false).execute().value
    }

    static func createInvite(orgId: UUID, userId: UUID, role: MemberRole, email: String?) async throws -> OrgInvite {
        if await DemoStore.isActive { throw AppError.message("Invites need a real account. Sign up to invite your team.") }
        struct NewInvite: Encodable {
            let org_id: UUID; let created_by: UUID; let role: MemberRole; let email: String?
        }
        return try await supabase.from("org_invites")
            .insert(NewInvite(org_id: orgId, created_by: userId, role: role, email: email?.isEmpty == true ? nil : email))
            .select().single().execute().value
    }

    static func deleteInvite(id: UUID) async throws {
        try await supabase.from("org_invites").delete().eq("id", value: id).execute()
    }

    // MARK: Helpers

    static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("roomscan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
