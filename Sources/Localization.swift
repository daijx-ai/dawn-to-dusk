import Foundation

enum AppLanguage: String, Codable, CaseIterable {
    case chinese = "zh-Hans", english = "en"
    var label: String { self == .chinese ? "简体中文" : "English" }
    var locale: Locale { Locale(identifier: self == .english ? "en_US" : "zh_Hans_CN") }
}

enum Localization {
    static var language: AppLanguage = .chinese
    static var resourceBundle = Bundle.main { didSet { englishBundle = nil } }
    private static var englishBundle: Bundle?
    static func translate(_ key: String) -> String {
        guard language == .english else { return key }
        if englishBundle == nil, let path = resourceBundle.path(forResource: "en", ofType: "lproj") { englishBundle = Bundle(path: path) }
        guard let bundle = englishBundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func dateFormatter(chinese: String, english: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = AgendaClock.calendar.timeZone
        formatter.locale = language.locale
        formatter.dateFormat = language == .english ? english : chinese
        return formatter
    }
}

/// Keep interpolated user content separate from translation keys. In particular,
/// schedule names are never translated or interpreted as format instructions.
struct AppText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]
    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; arguments = stringInterpolation.arguments }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount) }
        mutating func appendLiteral(_ value: String) { key += value }
        mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(String(describing: value)) }
    }
}

func L(_ text: AppText) -> String {
    let pieces = Localization.translate(text.key).components(separatedBy: "%@")
    guard pieces.count == text.arguments.count + 1 else { return text.key }
    return pieces.enumerated().reduce(into: "") { output, pair in
        output += pair.element
        if pair.offset < text.arguments.count { output += text.arguments[pair.offset] }
    }
}

/// Translate only known built-in categories for display, preserving stored data.
func categoryLabel(_ value: String) -> String {
    ["生活", "工作", "学习", "健康"].contains(value) ? Localization.translate(value) : value
}
