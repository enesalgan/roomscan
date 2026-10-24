import Foundation
import UIKit

/// In-memory + on-device data store used by "Try demo" mode.
/// Lets the whole app (jobs, LiDAR scans, photos, timer, paywall) run without Supabase.
/// Files (USDZ/JSON/JPG) are written under Documents/demo so they survive app restarts;
/// the records themselves are persisted as JSON in the same folder.
@MainActor
final class DemoStore {
    static let shared = DemoStore()
    static var isActive: Bool { shared.active }

    private(set) var active = false
    let userId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let orgId  = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    var jobs: [Job] = []
    var scans: [Scan] = []
    var photos: [Photo] = []
    var timeEntries: [TimeEntry] = []
    var subscribed = false
    var credits = 0
    var profession: Profession? = .contractor

    var profile: Profile {
        Profile(id: userId, orgId: orgId, role: .owner, fullName: "Demo User", email: "demo@roomscan.app",
                phone: nil, profession: profession, isActive: true, createdAt: Date())
    }
    var organization: Organization {
        Organization(id: orgId, name: "Demo Showroom", type: .company, ownerId: userId, freeScans: Config.freeScans, createdAt: Date())
    }
    var entitlement: Entitlement {
        Entitlement(orgId: orgId, subscribed: subscribed,
                    scansRemaining: subscribed ? nil : max(Config.freeScans + credits - scans.count, 0),
                    scansUsed: scans.count)
    }

    func enter() { active = true; load() }
    func exit()  { active = false }

    // MARK: Files

    var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func fileURL(_ relative: String) -> URL { dir.appendingPathComponent(relative) }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var jobs: [Job]; var scans: [Scan]; var photos: [Photo]; var timeEntries: [TimeEntry]
        var subscribed: Bool; var credits: Int
        var profession: Profession?
    }

    func save() {
        let snap = Snapshot(jobs: jobs, scans: scans, photos: photos, timeEntries: timeEntries, subscribed: subscribed, credits: credits, profession: profession)
        if let data = try? JSONEncoder.postgrest.encode(snap) {
            try? data.write(to: fileURL("state.json"))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL("state.json")),
              let snap = try? JSONDecoder.postgrest.decode(Snapshot.self, from: data) else { return }
        jobs = snap.jobs; scans = snap.scans; photos = snap.photos; timeEntries = snap.timeEntries
        subscribed = snap.subscribed; credits = snap.credits
        if let p = snap.profession { profession = p }
    }

    func reset() {
        jobs = []; scans = []; photos = []; timeEntries = []; subscribed = false; credits = 0
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Operations (mirror Repository)

    func upsert(_ job: Job) -> Job {
        var j = job; j.updatedAt = Date()
        if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i] = j } else { jobs.insert(j, at: 0) }
        save(); return j
    }

    func saveScan(_ scan: Scan, usdzURL: URL, jsonData: Data, thumbnail: UIImage?) throws -> Scan {
        guard entitlement.canScan else { throw AppError.scanLimitReached }
        var s = scan
        let base = s.id.uuidString.lowercased()
        try FileManager.default.copyItem(at: usdzURL, to: fileURL(base + ".usdz"))
        try jsonData.write(to: fileURL(base + ".json"))
        s.usdzPath = base + ".usdz"; s.jsonPath = base + ".json"
        if let jpg = thumbnail?.jpegData(compressionQuality: 0.8) {
            try jpg.write(to: fileURL(base + ".jpg")); s.thumbnailPath = base + ".jpg"
        }
        scans.insert(s, at: 0); save(); return s
    }

    func updateScan(_ scan: Scan) -> Scan {
        if let i = scans.firstIndex(where: { $0.id == scan.id }) { scans[i] = scan } else { scans.insert(scan, at: 0) }
        save(); return scan
    }

    func deleteScan(_ scan: Scan) {
        for p in [scan.usdzPath, scan.jsonPath, scan.thumbnailPath].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: fileURL(p))
        }
        scans.removeAll { $0.id == scan.id }; save()
    }

    func addPhoto(jobId: UUID, image: UIImage, caption: String?) throws -> Photo {
        let id = UUID()
        let resized = image.resized(maxDimension: 2048)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { throw AppError.message("Could not encode photo") }
        let rel = "photo-\(id.uuidString.lowercased()).jpg"
        try data.write(to: fileURL(rel))
        let p = Photo(id: id, jobId: jobId, orgId: orgId, createdBy: userId, storagePath: rel, caption: caption,
                      width: Int(resized.size.width), height: Int(resized.size.height), takenAt: Date())
        photos.append(p); save(); return p
    }

    func deletePhoto(_ photo: Photo) {
        try? FileManager.default.removeItem(at: fileURL(photo.storagePath))
        photos.removeAll { $0.id == photo.id }; save()
    }

    func startTimer(jobId: UUID) -> TimeEntry {
        let e = TimeEntry(jobId: jobId, orgId: orgId, userId: userId)
        timeEntries.insert(e, at: 0); save(); return e
    }

    func stopTimer(_ entry: TimeEntry, note: String?) -> TimeEntry {
        var e = entry; e.endedAt = Date(); e.note = note ?? e.note
        if let i = timeEntries.firstIndex(where: { $0.id == e.id }) { timeEntries[i] = e }
        save(); return e
    }
}
