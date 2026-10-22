import Foundation
import Supabase

/// Single shared Supabase client.
let supabase = SupabaseClient(
    supabaseURL: Config.supabaseURL,
    supabaseKey: Config.supabaseAnonKey,
    options: SupabaseClientOptions(
        db: .init(encoder: .postgrest, decoder: .postgrest)
    )
)

extension JSONEncoder {
    static let postgrest: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.withFractional.string(from: date))
        }
        return e
    }()
}

extension JSONDecoder {
    static let postgrest: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            var s = try decoder.singleValueContainer().decode(String.self)
            // Postgres emits microseconds and "+00:00"; ISO8601DateFormatter wants ≤3 fractional digits.
            if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
                let frac = String(s[r].dropFirst().prefix(3))
                s.replaceSubrange(r, with: "." + frac.padding(toLength: 3, withPad: "0", startingAt: 0))
            }
            if !s.hasSuffix("Z"), s.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression) == nil { s += "Z" }
            if let date = ISO8601.withFractional.date(from: s) ?? ISO8601.plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()
}

enum ISO8601 {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Errors surfaced to the UI
enum AppError: LocalizedError {
    case notSignedIn
    case scanLimitReached
    case lidarUnsupported
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "You are not signed in."
        case .scanLimitReached: "You've used your free scans. Upgrade to keep scanning."
        case .lidarUnsupported: "This device doesn't have a LiDAR scanner. RoomScan needs an iPhone 12 Pro or newer Pro model, or an iPad Pro with LiDAR."
        case .message(let m): m
        }
    }

    /// Translate Postgres / Supabase errors into friendlier ones
    static func from(_ error: Error) -> AppError {
        let text = String(describing: error)
        if text.contains("SCAN_LIMIT_REACHED") { return .scanLimitReached }
        if let e = error as? AppError { return e }
        return .message(error.localizedDescription)
    }
}
