import Foundation

/// One choice in a `select` field: what the user sees, the value, and the argv it
/// contributes where the preset's template says `.option(field)`.
public struct PresetOption: Equatable, Sendable, Identifiable {
    public var label: String
    public var value: String
    /// Spliced in for `.option(field)`; `{tokens}` are substituted like any other argument.
    public var args: [String]

    public var id: String { value }

    public init(_ label: String, _ value: String, args: [String] = []) {
        self.label = label
        self.value = value
        self.args = args
    }
}

/// A single control in a preset's form.
public struct PresetField: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case select, text }

    public var id: String
    public var label: String
    public var kind: Kind
    public var options: [PresetOption]
    /// Prefilled value: the selected option, or the text field's contents.
    public var defaultValue: String
    public var placeholder: String?
    /// Text fields that must be filled in. Select fields always have a value.
    public var required: Bool
    /// What the text holds, for validation: a time, a `W:H` size, or free text.
    public var format: Format
    /// Only shown (and only validated) while another field has one of these values,
    /// e.g. the custom size while `resolution` is `custom`.
    public var visibleWhen: (field: String, values: [String])?

    public enum Format: String, Sendable { case free, time, size }

    public static func == (a: PresetField, b: PresetField) -> Bool {
        a.id == b.id && a.label == b.label && a.kind == b.kind && a.options == b.options
            && a.defaultValue == b.defaultValue && a.placeholder == b.placeholder && a.required == b.required
            && a.format == b.format && a.visibleWhen?.field == b.visibleWhen?.field
            && a.visibleWhen?.values == b.visibleWhen?.values
    }

    public static func select(_ id: String, _ label: String, _ options: [PresetOption], default value: String? = nil) -> PresetField {
        PresetField(id: id, label: label, kind: .select, options: options, defaultValue: value ?? options.first?.value ?? "",
                    placeholder: nil, required: true, format: .free, visibleWhen: nil)
    }

    public static func text(_ id: String, _ label: String, default value: String = "", placeholder: String? = nil,
                            required: Bool = false, format: Format = .free,
                            visibleWhen: (field: String, values: [String])? = nil) -> PresetField {
        PresetField(id: id, label: label, kind: .text, options: [], defaultValue: value, placeholder: placeholder,
                    required: required, format: format, visibleWhen: visibleWhen)
    }

    public func option(_ value: String) -> PresetOption? { options.first { $0.value == value } }
}

/// One element of a preset's argv template.
public enum TemplateArg: Equatable, Sendable {
    /// A literal argument; `{tokens}` are substituted.
    case arg(String)
    /// These arguments, only when `field` has a non-empty value.
    case when(String, [String])
    /// The arguments of the option selected in `field`.
    case option(String)
}

/// What extension the result gets.
public enum OutputExtension: Equatable, Sendable {
    /// The input's own (lowercased), or `fallback` when it has none.
    case input(fallback: String)
    case fixed(String)
    /// The value of a select field (e.g. `format`).
    case field(String)
}

/// An ffmpeg recipe: a form, and an argv template the form fills in.
///
/// The builder assembles `ffmpeg -hide_banner -nostdin -n <inputArgs> -i <input>... <args> <output>`,
/// so templates never mention the binary, the input or the output file.
public struct Preset: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    /// SF Symbol name.
    public var symbol: String
    /// The word the output name gets (`clip_{suffix}.mp4`), through the `naming.suffix` setting.
    public var suffix: String
    public var fields: [PresetField]
    /// Before `-i` (fast seeking with `-ss`).
    public var inputArgs: [TemplateArg]
    /// After the inputs, before the output file.
    public var args: [TemplateArg]
    public var output: OutputExtension
    /// Needs a video stream; offered but marked when the dropped file is audio only.
    public var needsVideo: Bool
    /// Takes several inputs, joined through the concat demuxer's list file.
    public var multiInput: Bool

    public init(id: String, title: String, summary: String, symbol: String, suffix: String,
                fields: [PresetField] = [], inputArgs: [TemplateArg] = [], args: [TemplateArg],
                output: OutputExtension, needsVideo: Bool = true, multiInput: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.suffix = suffix
        self.fields = fields
        self.inputArgs = inputArgs
        self.args = args
        self.output = output
        self.needsVideo = needsVideo
        self.multiInput = multiInput
    }

    public func field(_ id: String) -> PresetField? { fields.first { $0.id == id } }

    /// Whether `field` is shown for these values (see `PresetField.visibleWhen`).
    public func isVisible(_ field: PresetField, values: PresetValues) -> Bool {
        guard let rule = field.visibleWhen else { return true }
        return rule.values.contains(values[rule.field])
    }

    /// The `action presets` / `jobs` JSON form.
    public var json: [String: Any] {
        ["id": id, "title": title, "summary": summary, "symbol": symbol, "needsVideo": needsVideo,
         "multiInput": multiInput,
         "fields": fields.map { field -> [String: Any] in
             var d: [String: Any] = ["id": field.id, "label": field.label, "kind": field.kind.rawValue,
                                     "default": field.defaultValue]
             if !field.options.isEmpty { d["options"] = field.options.map(\.value) }
             if let placeholder = field.placeholder { d["placeholder"] = placeholder }
             return d
         }]
    }
}

/// A preset form's values, keyed by field id. Missing keys read as the field's default.
public struct PresetValues: Equatable, Sendable {
    public private(set) var values: [String: String]

    /// Starts from the preset's defaults.
    public init(preset: Preset) {
        values = Dictionary(uniqueKeysWithValues: preset.fields.map { ($0.id, $0.defaultValue) })
    }

    public init(_ values: [String: String]) { self.values = values }

    public subscript(_ key: String) -> String {
        get { (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { values[key] = newValue }
    }

    /// Applies `field=value` overrides (socket / CLI). Keys that are not fields of `preset`
    /// are ignored, so callers can pass their whole argument dictionary.
    public mutating func apply(_ overrides: [String: String], preset: Preset) {
        for (key, value) in overrides where preset.field(key) != nil { values[key] = value }
    }

    public func applying(_ overrides: [String: String], preset: Preset) -> PresetValues {
        var copy = self
        copy.apply(overrides, preset: preset)
        return copy
    }
}
