import Foundation

@main struct LocalizationTests {
    @MainActor static func main() throws {
        var checked = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checked += 1; precondition(value(), message)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chaoxi-language-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleRoot = root.appendingPathComponent("Test.bundle")
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/en.lproj")
        try FileManager.default.copyItem(at: resources, to: bundleRoot.appendingPathComponent("en.lproj"))
        Localization.resourceBundle = Bundle(path: bundleRoot.path)!
        Localization.language = .english
        expect(L("编辑日程") == "Edit Schedule", "English editor title")
        expect(L("完成") == "Done", "Done label is concise")
        expect(L("仅改 \("2026-10-27") 这一次") == "Change only 2026-10-27", "One-day action interpolates the selected date")
        let userTitle = "读书 %@ 中文"
        expect(L("修改 \(userTitle)") == "Edit " + userTitle, "User content remains unchanged, including percent placeholders")
        expect(RepeatRule.weekdays.label == "Weekdays", "Computed model labels follow language")
        expect(categoryLabel("工作") == "Work" && categoryLabel("我的分类") == "我的分类", "Only built-in category display names are translated")
        expect(ScheduleInterval.duration(90) == "1 hr 30 min", "Interval calculations have English units")
        let stringsData = try Data(contentsOf: resources.appendingPathComponent("Localizable.strings"))
        let catalog = try PropertyListSerialization.propertyList(from: stringsData, format: nil) as! [String: String]
        for (key, translated) in catalog {
            expect(key.components(separatedBy: "%@").count == translated.components(separatedBy: "%@").count, "Translation preserves interpolation count: " + key)
        }
        let store = AgendaStore(directory: root.appendingPathComponent("Data"), seedIfEmpty: false)
        let item = AgendaItem(title: userTitle, date: AgendaClock.startOfDay(Date()), note: "不要翻译备注")
        expect(store.upsert(item), "Save private synthetic user content")
        store.settings.language = .english
        expect(store.save(), "Save English preference")
        let reloaded = AgendaStore(directory: store.fileURL.deletingLastPathComponent(), seedIfEmpty: false)
        expect(reloaded.settings.language == .english && reloaded.items == [item], "Language persists without changing any item")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgendaSettings())) as! [String: Any]
        legacy.removeValue(forKey: "languageCode")
        let old = try JSONDecoder().decode(AgendaSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(old.language == .chinese, "Old installations keep their Chinese language")
        Localization.language = .chinese
        expect(L("修改 \(userTitle)") == "修改 " + userTitle, "Switching back restores Chinese immediately")
        print("Localization: \(checked) checks passed")
    }
}
