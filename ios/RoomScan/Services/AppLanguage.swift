import Foundation
import SwiftUI
import Observation

/// In-app language override (English default). Swizzles Bundle.main so every
/// LocalizedStringKey / String(localized:) lookup uses the chosen .lproj at runtime.
@Observable
@MainActor
final class AppLanguage {
    static let shared = AppLanguage()

    struct Option: Identifiable, Hashable {
        let code: String; let name: String; let flag: String
        var id: String { code }
    }
    static let options: [Option] = [
        .init(code: "en", name: "English", flag: "🇺🇸"),
        .init(code: "es", name: "Español", flag: "🇪🇸"),
        .init(code: "tr", name: "Türkçe", flag: "🇹🇷"),
        .init(code: "hi", name: "हिन्दी", flag: "🇮🇳"),
        .init(code: "pt-BR", name: "Português", flag: "🇧🇷"),
        .init(code: "ru", name: "Русский", flag: "🇷🇺"),
    ]

    private static let key = "app.language"
    var code: String {
        didSet { UserDefaults.standard.set(code, forKey: Self.key); Self.apply(code) }
    }
    var locale: Locale { Locale(identifier: code) }

    private init() {
        code = UserDefaults.standard.string(forKey: Self.key) ?? "en"
        Self.apply(code)
    }

    private static func apply(_ code: String) {
        LocalizedBundle.install()
        let path = Bundle.main.path(forResource: code, ofType: "lproj")
            ?? Bundle.main.path(forResource: String(code.prefix(2)), ofType: "lproj")
        LocalizedBundle.current = path.flatMap(Bundle.init(path:))
        UserDefaults.standard.set([code], forKey: "AppleLanguages")   // system-provided strings follow on next launch
    }
}

/// Bundle subclass swapped in for Bundle.main
final class LocalizedBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var current: Bundle?
    private nonisolated(unsafe) static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        object_setClass(Bundle.main, LocalizedBundle.self)
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let b = Self.current { return b.localizedString(forKey: key, value: value, table: tableName) }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}
