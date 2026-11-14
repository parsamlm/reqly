import Foundation

/// The locale Reqly writes times and dates in, chosen as the C library chooses LC_TIME's: from
/// LC_ALL, then LC_TIME, then LANG, the first that's set. So a desktop whose formats differ from
/// its language, as GNOME's Formats setting makes them by setting LC_TIME, has its own clock and
/// dates. Foundation's Locale.current doesn't read these on Linux (Swift 6.4's is en_001, whatever
/// they say), so it's only the default: for C and POSIX, for none set, and for a name that isn't a
/// locale's.
enum TimeLocale {
    /// This run's, from its environment, which doesn't change while it runs.
    static let current = locale(in: ProcessInfo.processInfo.environment)

    /// The locale `environment` gives times, or `fallback` when it gives none.
    static func locale(in environment: [String: String], fallback: Locale = .current) -> Locale {
        let name = ["LC_ALL", "LC_TIME", "LANG"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty }
        return name.flatMap(identifier(posix:)).map(Locale.init(identifier:)) ?? fallback
    }

    /// The identifier of a POSIX locale's name, `language[_territory][.codeset][@modifier]`: `en_GB`
    /// for `en_GB.UTF-8`, `de_DE` for `de_DE@euro`, `sr_Latn_RS` for `sr_RS@latin`. Nil for C and
    /// POSIX, which are no language, and for a language ICU has no formats for.
    static func identifier(posix name: String) -> String? {
        var rest = Substring(name)
        var modifier = ""
        if let at = rest.firstIndex(of: "@") {
            modifier = String(rest[rest.index(after: at)...]).lowercased()
            rest = rest[..<at]
        }
        if let dot = rest.firstIndex(of: ".") {
            rest = rest[..<dot]
        }
        let parts = rest.split(separator: "_", omittingEmptySubsequences: false)
        guard let language = parts.first, parts.count <= 2, (2...3).contains(language.count),
            language.allSatisfy({ $0.isASCII && $0.isLowercase }), knownLanguages.contains(String(language))
        else { return nil }
        var identifier = String(language)
        if let script = scripts[modifier] {
            identifier += "_\(script)"
        }
        if parts.count == 2 {
            let territory = parts[1]
            let isRegion =
                (territory.count == 2 && territory.allSatisfy { $0.isASCII && $0.isUppercase })
                || (territory.count == 3 && territory.allSatisfy { $0.isASCII && $0.isNumber })
            guard isRegion else { return nil }
            identifier += "_\(territory)"
            if modifier == "valencia" {
                identifier += "_VALENCIA"
            }
        }
        return identifier
    }

    /// The modifiers that name a script, as glibc's locales use them.
    private static let scripts = ["latin": "Latn", "cyrillic": "Cyrl", "devanagari": "Deva"]

    /// The languages ICU has formats for. Its identifiers with territories leave out aliases, such
    /// as zh_TW for zh_Hant_TW, which work, so only the language is looked up here.
    private static let knownLanguages = Set(
        Locale.availableIdentifiers.map { String($0.prefix { $0 != "_" }) })
}
