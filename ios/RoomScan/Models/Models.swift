import Foundation

// MARK: - Enums (mirror Postgres enums)

enum OrgType: String, Codable { case company, individual }
enum MemberRole: String, Codable { case owner, admin, member }

enum JobStatus: String, Codable, CaseIterable, Identifiable {
    case new, scheduled, measured, designing, quoted, won, lost, archived
    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: "New"
        case .scheduled: "Scheduled"
        case .measured: "Measured"
        case .designing: "Designing"
        case .quoted: "Quoted"
        case .won: "Won"
        case .lost: "Lost"
        case .archived: "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .new: "sparkles"
        case .scheduled: "calendar"
        case .measured: "ruler"
        case .designing: "pencil.and.ruler"
        case .quoted: "doc.text"
        case .won: "checkmark.seal"
        case .lost: "xmark.circle"
        case .archived: "archivebox"
        }
    }
}

// MARK: - Rows

struct Organization: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var type: OrgType
    var ownerId: UUID
    var freeScans: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case ownerId = "owner_id"
        case freeScans = "free_scans"
        case createdAt = "created_at"
    }
}

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var orgId: UUID
    var role: MemberRole
    var fullName: String?
    var email: String?
    var phone: String?
    var isActive: Bool
    let createdAt: Date

    var displayName: String { fullName?.isEmpty == false ? fullName! : (email ?? "User") }
    var isAdmin: Bool { role == .owner || role == .admin }

    enum CodingKeys: String, CodingKey {
        case id, role, phone, email
        case orgId = "org_id"
        case fullName = "full_name"
        case isActive = "is_active"
        case createdAt = "created_at"
    }
}

struct OrgInvite: Codable, Identifiable, Hashable {
    let id: UUID
    let orgId: UUID
    let code: String
    let role: MemberRole
    let email: String?
    let expiresAt: Date
    let usedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, code, role, email
        case orgId = "org_id"
        case expiresAt = "expires_at"
        case usedAt = "used_at"
        case createdAt = "created_at"
    }
}

struct Job: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var orgId: UUID
    var createdBy: UUID
    var assignedTo: UUID?
    var title: String
    var status: JobStatus = .new
    var customerName: String?
    var customerPhone: String?
    var customerEmail: String?
    var addressLine1: String?
    var addressLine2: String?
    var city: String?
    var state: String?
    var postalCode: String?
    var country: String? = "US"
    var latitude: Double?
    var longitude: Double?
    var scheduledAt: Date?
    var estimateAmount: Double?
    var estimateCurrency: String = "USD"
    var notes: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date?

    var addressSummary: String {
        let parts = [addressLine1, [city, state].compactMap { $0 }.joined(separator: ", "), postalCode]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case id, title, status, city, state, country, latitude, longitude, notes
        case orgId = "org_id"
        case createdBy = "created_by"
        case assignedTo = "assigned_to"
        case customerName = "customer_name"
        case customerPhone = "customer_phone"
        case customerEmail = "customer_email"
        case addressLine1 = "address_line1"
        case addressLine2 = "address_line2"
        case postalCode = "postal_code"
        case scheduledAt = "scheduled_at"
        case estimateAmount = "estimate_amount"
        case estimateCurrency = "estimate_currency"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct Scan: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var jobId: UUID
    var orgId: UUID
    var createdBy: UUID
    var name: String = "Room"
    var usdzPath: String?
    var jsonPath: String?
    var thumbnailPath: String?
    var roomCount: Int = 1
    var floorAreaM2: Double?
    var summary: ScanSummary = ScanSummary()
    var capturedAt: Date = Date()
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, summary
        case jobId = "job_id"
        case orgId = "org_id"
        case createdBy = "created_by"
        case usdzPath = "usdz_path"
        case jsonPath = "json_path"
        case thumbnailPath = "thumbnail_path"
        case roomCount = "room_count"
        case floorAreaM2 = "floor_area_m2"
        case capturedAt = "captured_at"
        case createdAt = "created_at"
    }
}

/// Lightweight summary stored as JSONB so the web app can show numbers without parsing the USDZ.
struct ScanSummary: Codable, Hashable {
    var walls: Int = 0
    var doors: Int = 0
    var windows: Int = 0
    var openings: Int = 0
    var objects: [String: Int] = [:]   // e.g. ["refrigerator": 1, "stove": 1]
    var widthM: Double = 0
    var depthM: Double = 0
    var heightM: Double = 0
    var perimeterM: Double = 0

    enum CodingKeys: String, CodingKey {
        case walls, doors, windows, openings, objects
        case widthM = "width_m"
        case depthM = "depth_m"
        case heightM = "height_m"
        case perimeterM = "perimeter_m"
    }
}

struct Photo: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var jobId: UUID
    var orgId: UUID
    var createdBy: UUID
    var storagePath: String
    var caption: String?
    var width: Int?
    var height: Int?
    var takenAt: Date?
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, caption, width, height
        case jobId = "job_id"
        case orgId = "org_id"
        case createdBy = "created_by"
        case storagePath = "storage_path"
        case takenAt = "taken_at"
        case createdAt = "created_at"
    }
}

struct TimeEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var jobId: UUID
    var orgId: UUID
    var userId: UUID
    var startedAt: Date = Date()
    var endedAt: Date?
    var note: String?

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var isRunning: Bool { endedAt == nil }

    enum CodingKeys: String, CodingKey {
        case id, note
        case jobId = "job_id"
        case orgId = "org_id"
        case userId = "user_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

struct Entitlement: Codable, Hashable {
    var orgId: UUID?
    var subscribed: Bool = false
    var scansRemaining: Int?   // nil = unlimited
    var scansUsed: Int = 0

    var canScan: Bool { subscribed || (scansRemaining ?? 1) > 0 }

    enum CodingKeys: String, CodingKey {
        case subscribed
        case orgId = "org_id"
        case scansRemaining = "scans_remaining"
        case scansUsed = "scans_used"
    }
}

// MARK: - Formatting helpers

extension TimeInterval {
    var hms: String {
        let s = Int(self)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

extension Double {
    var meters: String { String(format: "%.2f m", self) }
    var feetInches: String {
        let totalInches = self * 39.3701
        let ft = Int(totalInches / 12)
        let inch = totalInches - Double(ft * 12)
        return String(format: "%d' %.1f\"", ft, inch)
    }
    var squareFeet: String { String(format: "%.0f sq ft", self * 10.7639) }
}
