import Foundation

enum Config {
    static var supabaseURL: URL {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let url = URL(string: s), s.hasPrefix("https://") else {
            fatalError("SUPABASE_URL is not set. Edit Config/Secrets.xcconfig")
        }
        return url
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
