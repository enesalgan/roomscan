import SwiftUI
import Supabase

/// Company details + logo used on PDF reports. Cached on device; pushed to the organization row
/// and the `branding` storage bucket when signed in to a real account.
@MainActor
@Observable
final class BrandingStore {
    static let shared = BrandingStore()

    private(set) var branding = Branding()
    private(set) var logo: UIImage?
    private var orgId: UUID?

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("branding", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func jsonURL(_ org: UUID) -> URL { dir.appendingPathComponent("\(org.uuidString).json") }
    private func logoURL(_ org: UUID) -> URL { dir.appendingPathComponent("\(org.uuidString).png") }

    /// Loads the cached copy, then the remote one (if any) which wins.
    func load(for org: Organization, demo: Bool) async {
        orgId = org.id
        if let data = try? Data(contentsOf: jsonURL(org.id)), let b = try? JSONDecoder().decode(Branding.self, from: data) { branding = b }
        else { branding = Branding(companyName: org.name) }
        logo = UIImage(contentsOfFile: logoURL(org.id).path)
        guard !demo else { return }
        if let remote = org.branding { branding = remote; persistLocally() }
        if logo == nil, let path = branding.logoPath,
           let data = try? await supabase.storage.from("branding").download(path: path), let img = UIImage(data: data) {
            logo = img
            try? data.write(to: logoURL(org.id))
        }
    }

    func update(_ b: Branding, logo newLogo: UIImage??, demo: Bool) async throws {
        guard let orgId else { return }
        branding = b
        if let newLogo {                       // .some(image) = replace, .some(nil) = remove
            logo = newLogo
            if let img = newLogo, let png = img.resized(maxSide: 800).pngData() { try png.write(to: logoURL(orgId)) }
            else { try? FileManager.default.removeItem(at: logoURL(orgId)) }
        }
        persistLocally()
        guard !demo else { return }
        if let newLogo {
            let path = "\(orgId.uuidString)/logo.png"
            if let img = newLogo, let png = img.resized(maxSide: 800).pngData() {
                try await supabase.storage.from("branding").upload(path: path, file: png, options: FileOptions(contentType: "image/png", upsert: true))
                branding.logoPath = path
            } else {
                try? await supabase.storage.from("branding").remove(paths: [path])
                branding.logoPath = nil
            }
            persistLocally()
        }
        try await supabase.from("organizations").update(["branding": branding]).eq("id", value: orgId).execute()
    }

    private func persistLocally() {
        guard let orgId, let data = try? JSONEncoder().encode(branding) else { return }
        try? data.write(to: jsonURL(orgId))
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let k = min(1, maxSide / max(size.width, size.height))
        guard k < 1 else { return self }
        let new = CGSize(width: size.width * k, height: size.height * k)
        return UIGraphicsImageRenderer(size: new).image { _ in draw(in: CGRect(origin: .zero, size: new)) }
    }
}
