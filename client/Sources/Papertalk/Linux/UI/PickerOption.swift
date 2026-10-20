#if os(Linux)
import Foundation

/// A Picker value with a readable label: SwiftCrossUI's Picker shows
/// `"\(option)"`, so the raw values (Depth cases, Kokoro voice ids) are wrapped.
struct PickerOption<Value: Equatable>: Equatable, CustomStringConvertible {
    let value: Value
    let description: String

    static func == (a: PickerOption, b: PickerOption) -> Bool { a.value == b.value }
}

extension PickerOption where Value == Depth {
    static var depths: [PickerOption] { Depth.allCases.map { PickerOption(value: $0, description: $0.label) } }
}

extension PickerOption where Value == String {
    static var voices: [PickerOption] { KokoroSpeech.allVoices.map { PickerOption(value: $0, description: KokoroSpeech.label($0)) } }
    static var genders: [PickerOption] { [PickerOption(value: "female", description: L("Female")),
                                          PickerOption(value: "male", description: L("Male"))] }
}
#endif
