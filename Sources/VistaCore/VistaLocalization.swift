import Foundation

/// Resource lookup only; never changes system or saved language preferences.
public enum VistaL10n {
    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
        return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
    }
    public static var isEnglish: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true }
}


/// Keeps notices offline; only explicit HTTP(S) destinations become interactive.
enum VistaNoticeLinks {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    static func render(_ source: String, markdown: Bool) -> AttributedString {
        let parsed = markdown
            ? ((try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source))
            : AttributedString(source)
        var result = parsed
        for run in Array(result.runs) {
            if let url = run.link, !allows(url) { result[run.range].link = nil }
        }
        let plain = String(result.characters)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = match.url, allows(url),
                      let textRange = Range(match.range, in: plain),
                      let range = Range(textRange, in: result),
                      result[range].runs.allSatisfy({ $0.link == nil }) else { continue }
                let visible = plain[textRange].lowercased()
                guard visible.hasPrefix("https://") || visible.hasPrefix("http://") else { continue }
                result[range].link = url
            }
        }
        return result
    }
}
