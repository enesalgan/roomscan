import Foundation

enum Config {
    /// Built from the project ref (xcconfig can't hold "//" reliably). Falls back to SUPABASE_URL if set.
    static var supabaseURL: URL {
        let info = Bundle.main.infoDictionary ?? [:]
        if let ref = (info["SUPABASE_PROJECT_REF"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ref.isEmpty, !ref.contains("$"), let url = URL(string: "https://\(ref).supabase.co") {
            return url
        }
        if let s = info["SUPABASE_URL"] as? String, s.hasPrefix("https://"), !s.contains("$"), let url = URL(string: s) {
            return url
        }
        fatalError("SUPABASE_PROJECT_REF is not set. Edit Config/Secrets.xcconfig")
    }

    static var supabaseAnonKey: String {
        guard let k = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String, !k.isEmpty else {
            fatalError("SUPABASE_ANON_KEY is not set. Edit Config/Secrets.xcconfig")
        }
        return k
    }

    /// App Store product identifiers (must match App Store Connect + the edge function map)
    enum Products {
        static let proMonthly = "com.lixisoft.roomscan.pro.monthly"
        static let proYearly  = "com.lixisoft.roomscan.pro.yearly"
        static let credits10  = "com.lixisoft.roomscan.credits10"
        static let all = [proMonthly, proYearly, credits10]
    }

    static let freeScans = 3
}
