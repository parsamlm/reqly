import Foundation
import Testing

@testable import ReqlyApp

/// Times and dates follow LC_TIME as the C library chooses it, not only the language.
@Suite struct TimeLocaleTests {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-03 at 16:05:59.250 in UTC.
    static let afternoon = Date(timeIntervalSince1970: 1_791_000_000 + 12 * 3600 + 359.25)
    /// What stands for Foundation's own locale, which C and POSIX mean.
    static let fallback = Locale(identifier: "fr_CA")

    static func locale(_ environment: [String: String]) -> String {
        TimeLocale.locale(in: environment, fallback: fallback).identifier
    }

    @Test func takesLCAllThenLCTimeThenLang() {
        // GNOME's Formats set to the United Kingdom, its language to English (US).
        #expect(Self.locale(["LANG": "en_US.UTF-8", "LC_TIME": "en_GB.UTF-8"]) == "en_GB")
        #expect(Self.locale(["LANG": "en_US.UTF-8", "LC_TIME": "en_GB.UTF-8", "LC_ALL": "de_DE.UTF-8"]) == "de_DE")
        #expect(Self.locale(["LANG": "nl_NL.UTF-8"]) == "nl_NL")
        // An empty one is as good as none, and LC_MESSAGES and LANGUAGE are for words, not times.
        #expect(Self.locale(["LC_ALL": "", "LC_TIME": "", "LANG": "pt_BR.UTF-8"]) == "pt_BR")
        #expect(Self.locale(["LC_MESSAGES": "de_DE.UTF-8", "LANGUAGE": "de", "LANG": "en_GB.UTF-8"]) == "en_GB")
    }

    @Test func meansTheDefaultByCAndPOSIX() {
        #expect(Self.locale([:]) == "fr_CA")
        #expect(Self.locale(["LANG": "C"]) == "fr_CA")
        #expect(Self.locale(["LANG": "C.UTF-8"]) == "fr_CA")
        #expect(Self.locale(["LC_ALL": "POSIX", "LANG": "en_GB.UTF-8"]) == "fr_CA")
        // As in the C library, C in LC_TIME is C for times, whatever LANG is.
        #expect(Self.locale(["LC_TIME": "C", "LANG": "de_DE.UTF-8"]) == "fr_CA")
        #expect(Self.locale(["LANG": "not a locale"]) == "fr_CA")
    }

    @Test func readsPOSIXNames() {
        #expect(TimeLocale.identifier(posix: "en_GB.UTF-8") == "en_GB")
        #expect(TimeLocale.identifier(posix: "en_GB.utf8") == "en_GB")
        #expect(TimeLocale.identifier(posix: "de_DE@euro") == "de_DE")
        #expect(TimeLocale.identifier(posix: "de_DE.ISO-8859-15@euro") == "de_DE")
        #expect(TimeLocale.identifier(posix: "sr_RS@latin") == "sr_Latn_RS")
        #expect(TimeLocale.identifier(posix: "uz_UZ.UTF-8@cyrillic") == "uz_Cyrl_UZ")
        #expect(TimeLocale.identifier(posix: "ca_ES.UTF-8@valencia") == "ca_ES_VALENCIA")
        #expect(TimeLocale.identifier(posix: "zh_TW.Big5") == "zh_TW")
        #expect(TimeLocale.identifier(posix: "es_419.UTF-8") == "es_419")
        #expect(TimeLocale.identifier(posix: "fil_PH.UTF-8") == "fil_PH")
        #expect(TimeLocale.identifier(posix: "eo") == "eo")
        for name in [
            "C", "POSIX", "C.UTF-8", "", "xx_YY.UTF-8", "EN_US", "en_us", "en_GB_X", "/usr/lib/locale", "en_G",
        ] {
            #expect(TimeLocale.identifier(posix: name) == nil, "\(name)")
        }
    }

    @Test func givesTheClockOfLCTime() {
        let british = TimeLocale.locale(in: ["LANG": "en_US.UTF-8", "LC_TIME": "en_GB.UTF-8"])
        let american = TimeLocale.locale(in: ["LANG": "en_US.UTF-8"])
        #expect(Format.time(Self.afternoon, locale: british, timeZone: Self.utc) == "16:05:59")
        #expect(Format.time(Self.afternoon, locale: american, timeZone: Self.utc) == "4:05:59\u{202F}PM")
        #expect(DetailsFormat.moment(Self.afternoon, locale: british, timeZone: Self.utc) == "3 Oct at 16:05:59.250")
        #expect(DetailsFormat.day(Self.afternoon, locale: british, timeZone: Self.utc) == "3 Oct 2026 at 16:05")
        #expect(Format.date(Self.afternoon, locale: british, timeZone: Self.utc) == "3 Oct 2026")
        #expect(Format.date(Self.afternoon, locale: american, timeZone: Self.utc) == "Oct 3, 2026")
        let german = TimeLocale.locale(in: ["LC_ALL": "de_DE@euro"])
        #expect(Format.time(Self.afternoon, locale: german, timeZone: Self.utc) == "16:05:59")
    }

    @Test func keepsNumbersAndTimesApart() {
        // A row's and the heading's numbers by the language, their times by LC_TIME.
        let british = Locale(identifier: "en_GB")
        let german = Locale(identifier: "de_DE")
        var summary = RowTextTests.summary()
        summary.duration = 1.2391
        let row = RowText(summary, locale: german, timeLocale: british, timeZone: Self.utc)
        #expect(row.duration == "1,24 s")
        #expect(row.time == "11:05:59")
        let heading = DetailsHeading(
            summary, reason: "OK", grpc: nil, locale: german, timeLocale: british, timeZone: Self.utc)
        #expect(heading.facts.last == "11:05:59")
        #expect(heading.facts.contains("1,24 s"))
    }
}
