import Foundation

// Only compile-time palette enums are substituted in the isolated harness.
// The real Appearance.swift and TimeInput.swift are compiled unchanged.
#if TIME_INPUT_ISOLATED
enum AgendaAppearanceMode { case light, dark, system }
enum AgendaAccentColor { case green, blue, purple, orange, graphite }
#endif

@main struct TimeInputTests {
    static func main() {
        var checked = 0
        func expect(_ condition: Bool, _ message: String) {
            checked += 1
            if !condition { fatalError(message) }
        }
        func minutes(_ text: String) -> Int? {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return hour * 60 + minute
        }
        // Simulate the two bound fields used by both consumers, then validate
        // their output with the unchanged consumer's accepted clock grammar.
        var typed = ""
        typed = TimeInputValue(typed).replacing(.hour, with: "00")
        expect(minutes(typed) == nil, "Missing minute must remain invalid")
        typed = TimeInputValue(typed).replacing(.minute, with: "00")
        expect(typed == "00:00" && minutes(typed) == 0, "Typed midnight")
        typed = TimeInputValue(typed).replacing(.hour, with: "23")
        typed = TimeInputValue(typed).replacing(.minute, with: "59")
        expect(typed == "23:59" && minutes(typed) == 1439, "Typed last minute")
        expect(TimeInputValue(typed).adjusting(.minute, by: 1) == "23:59", "Minute must not carry to next day")
        expect(TimeInputValue(typed).adjusting(.hour, by: 1) == "23:59", "Hour must not carry to next day")
        expect(TimeInputValue("00:00").adjusting(.minute, by: -1) == "00:00", "Minute floor")
        expect(TimeInputValue("00:00").adjusting(.hour, by: -1) == "00:00", "Hour floor")
        expect(TimeInputValue("09:58").adjusting(.minute, by: 1) == "09:59", "Single minute, no five-minute rounding")
        expect(TimeInputValue("09:37").adjusting(.hour, by: 1) == "10:37", "Hour adjustment preserves minute")
        expect(TimeInputValue("09:37").adjusting(.minute, by: -1) == "09:36", "Minute adjustment preserves hour")
        for bad in ["25:30", "12:60", "wrong", "09:bad", "12:34:56"] {
            expect(minutes(bad) == nil, "Invalid incoming clock must not save")
            let value = TimeInputValue(bad)
            expect(value.hour + ":" + value.minute != "09:00", "No fallback default for invalid value")
        }
        expect(TimeInputValue("25:30").adjusting(.hour, by: -1) == nil, "Cannot silently clamp an invalid hour")
        expect(TimeInputValue("12:60").adjusting(.minute, by: -1) == nil, "Cannot silently clamp an invalid minute")
        let corrected = TimeInputValue("25:30").replacing(.hour, with: "22")
        expect(minutes(corrected) == 22 * 60 + 30, "Explicit correction can save")
        expect(TimeInputValue("").adjusting(.hour, by: 1) == "00:", "Explicit hour choice leaves minute unset")
        expect(TimeInputValue("").adjusting(.minute, by: 1) == ":00", "Explicit minute choice leaves hour unset")
        expect(TimeInputValue("23:59").adjusting(.minute, by: Int.max) == "23:59", "Large scroll step stays bounded")
        expect(TimeInputValue("00:00").adjusting(.hour, by: Int.min) == "00:00", "Large negative step stays bounded")
        print("Time input: \(checked) checks passed")
    }
}
