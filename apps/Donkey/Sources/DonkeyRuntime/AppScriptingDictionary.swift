import Foundation

/// A parsed app scripting dictionary: the app's real AppleScript vocabulary, read from its
/// `.sdef`. This is the ground truth that script generation and validation work against, so
/// generated scripts use terminology the app actually understands instead of guessed names.
public struct ScriptingDictionary: Equatable, Sendable, Codable {
    public var appName: String
    public var bundleIdentifier: String
    public var appVersion: String
    public var suites: [ScriptingSuite]

    public init(appName: String, bundleIdentifier: String, appVersion: String, suites: [ScriptingSuite]) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.appVersion = appVersion
        self.suites = suites
    }

    /// Every command name across all suites, in dictionary order (deduplicated).
    public var commandNames: [String] {
        var seen = Set<String>()
        return suites.flatMap(\.commands).map(\.name).filter { seen.insert($0).inserted }
    }
}

public struct ScriptingSuite: Equatable, Sendable, Codable {
    public var name: String
    public var code: String
    public var summary: String
    public var commands: [ScriptingCommand]
    public var classes: [ScriptingClass]
    public var enumerations: [ScriptingEnumeration]

    public init(
        name: String,
        code: String,
        summary: String = "",
        commands: [ScriptingCommand] = [],
        classes: [ScriptingClass] = [],
        enumerations: [ScriptingEnumeration] = []
    ) {
        self.name = name
        self.code = code
        self.summary = summary
        self.commands = commands
        self.classes = classes
        self.enumerations = enumerations
    }
}

public struct ScriptingCommand: Equatable, Sendable, Codable {
    public var name: String
    public var code: String
    public var summary: String
    public var directParameter: ScriptingParameter?
    public var parameters: [ScriptingParameter]
    public var resultType: String

    public init(
        name: String,
        code: String,
        summary: String = "",
        directParameter: ScriptingParameter? = nil,
        parameters: [ScriptingParameter] = [],
        resultType: String = ""
    ) {
        self.name = name
        self.code = code
        self.summary = summary
        self.directParameter = directParameter
        self.parameters = parameters
        self.resultType = resultType
    }
}

public struct ScriptingParameter: Equatable, Sendable, Codable {
    /// Empty for a command's direct parameter.
    public var name: String
    public var type: String
    public var isOptional: Bool
    public var summary: String

    public init(name: String = "", type: String, isOptional: Bool = false, summary: String = "") {
        self.name = name
        self.type = type
        self.isOptional = isOptional
        self.summary = summary
    }
}

public struct ScriptingClass: Equatable, Sendable, Codable {
    public var name: String
    public var pluralName: String
    public var summary: String
    public var properties: [ScriptingProperty]
    public var elementClassNames: [String]

    public init(
        name: String,
        pluralName: String = "",
        summary: String = "",
        properties: [ScriptingProperty] = [],
        elementClassNames: [String] = []
    ) {
        self.name = name
        self.pluralName = pluralName
        self.summary = summary
        self.properties = properties
        self.elementClassNames = elementClassNames
    }
}

public struct ScriptingProperty: Equatable, Sendable, Codable {
    public var name: String
    public var type: String
    public var isReadOnly: Bool
    public var summary: String

    public init(name: String, type: String, isReadOnly: Bool = false, summary: String = "") {
        self.name = name
        self.type = type
        self.isReadOnly = isReadOnly
        self.summary = summary
    }
}

public struct ScriptingEnumeration: Equatable, Sendable, Codable {
    public var name: String
    public var enumeratorNames: [String]

    public init(name: String, enumeratorNames: [String]) {
        self.name = name
        self.enumeratorNames = enumeratorNames
    }
}

/// Parses sdef XML into the typed model. `XMLDocument` resolves `xi:include` natively (apps like
/// Notes pull in the shared Standard Suite that way), so loading from the file URL gives the full
/// dictionary without the Xcode-only `sdef` CLI.
public enum ScriptingDictionaryParser {
    public static func suites(contentsOf url: URL) throws -> [ScriptingSuite] {
        let document = try XMLDocument(contentsOf: url, options: [.documentXInclude])
        return suites(in: document)
    }

    public static func suites(from data: Data) throws -> [ScriptingSuite] {
        let document = try XMLDocument(data: data, options: [.documentXInclude])
        return suites(in: document)
    }

    private static func suites(in document: XMLDocument) -> [ScriptingSuite] {
        guard let root = document.rootElement() else { return [] }
        return root.elements(forName: "suite").compactMap { suite in
            guard !isHidden(suite) else { return nil }
            return ScriptingSuite(
                name: attribute(suite, "name"),
                code: attribute(suite, "code"),
                summary: attribute(suite, "description"),
                commands: suite.elements(forName: "command").compactMap(command(from:)),
                classes: classes(in: suite),
                enumerations: suite.elements(forName: "enumeration").compactMap(enumeration(from:))
            )
        }
    }

    private static func command(from element: XMLElement) -> ScriptingCommand? {
        guard !isHidden(element) else { return nil }
        let direct = element.elements(forName: "direct-parameter").first.map { directElement in
            ScriptingParameter(
                type: typeString(of: directElement),
                isOptional: attribute(directElement, "optional") == "yes",
                summary: attribute(directElement, "description")
            )
        }
        let parameters = element.elements(forName: "parameter").compactMap { parameter -> ScriptingParameter? in
            guard !isHidden(parameter) else { return nil }
            return ScriptingParameter(
                name: attribute(parameter, "name"),
                type: typeString(of: parameter),
                isOptional: attribute(parameter, "optional") == "yes",
                summary: attribute(parameter, "description")
            )
        }
        let result = element.elements(forName: "result").first.map(typeString(of:)) ?? ""
        return ScriptingCommand(
            name: attribute(element, "name"),
            code: attribute(element, "code"),
            summary: attribute(element, "description"),
            directParameter: direct,
            parameters: parameters,
            resultType: result
        )
    }

    private static func classes(in suite: XMLElement) -> [ScriptingClass] {
        // `class-extension` extends an existing class (usually `application`); surface it as a
        // class named after what it extends so its properties/elements stay discoverable.
        let plain = suite.elements(forName: "class").compactMap { element -> ScriptingClass? in
            scriptingClass(from: element, name: attribute(element, "name"))
        }
        let extensions = suite.elements(forName: "class-extension").compactMap { element -> ScriptingClass? in
            scriptingClass(from: element, name: attribute(element, "extends"))
        }
        return plain + extensions
    }

    private static func scriptingClass(from element: XMLElement, name: String) -> ScriptingClass? {
        guard !isHidden(element), !name.isEmpty else { return nil }
        let properties = element.elements(forName: "property").compactMap { property -> ScriptingProperty? in
            guard !isHidden(property) else { return nil }
            return ScriptingProperty(
                name: attribute(property, "name"),
                type: typeString(of: property),
                isReadOnly: attribute(property, "access") == "r",
                summary: attribute(property, "description")
            )
        }
        let elements = element.elements(forName: "element").compactMap { child -> String? in
            guard !isHidden(child) else { return nil }
            let type = attribute(child, "type")
            return type.isEmpty ? nil : type
        }
        return ScriptingClass(
            name: name,
            pluralName: attribute(element, "plural"),
            summary: attribute(element, "description"),
            properties: properties,
            elementClassNames: elements
        )
    }

    private static func enumeration(from element: XMLElement) -> ScriptingEnumeration? {
        guard !isHidden(element) else { return nil }
        let enumerators = element.elements(forName: "enumerator").compactMap { enumerator -> String? in
            guard !isHidden(enumerator) else { return nil }
            let name = attribute(enumerator, "name")
            return name.isEmpty ? nil : name
        }
        let name = attribute(element, "name")
        guard !name.isEmpty, !enumerators.isEmpty else { return nil }
        return ScriptingEnumeration(name: name, enumeratorNames: enumerators)
    }

    /// The AppleScript type of a parameter/property/result: either a `type` attribute or nested
    /// `<type>` elements (used for union types and `list of` markers).
    private static func typeString(of element: XMLElement) -> String {
        if case let type = attribute(element, "type"), !type.isEmpty {
            return type
        }
        return element.elements(forName: "type")
            .map { nested -> String in
                let name = attribute(nested, "type")
                return attribute(nested, "list") == "yes" ? "list of \(name)" : name
            }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private static func isHidden(_ element: XMLElement) -> Bool {
        let hidden = attribute(element, "hidden").lowercased()
        return hidden == "yes" || hidden == "true"
    }

    private static func attribute(_ element: XMLElement, _ name: String) -> String {
        element.attribute(forName: name)?.stringValue ?? ""
    }
}

/// Finds the sdef file an installed app ships.
public enum ScriptingDefinitionLocator {
    public static func sdefURL(forBundleAt bundleURL: URL) -> URL? {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let info = Bundle(url: bundleURL)?.infoDictionary
        if let declared = info?["OSAScriptingDefinition"] as? String, !declared.isEmpty {
            // Usually a Resources-relative filename; some apps use bundle-relative or absolute paths.
            let candidates = [
                resources.appendingPathComponent(declared),
                bundleURL.appendingPathComponent(declared),
                URL(fileURLWithPath: declared)
            ]
            if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                return found
            }
        }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else {
            return nil
        }
        return items
            .filter { $0.lowercased().hasSuffix(".sdef") }
            .sorted()
            .first
            .map { resources.appendingPathComponent($0) }
    }
}

/// Fallback for apps with no plain `.sdef` on disk (aete-only or dynamically generated
/// dictionaries): the public OpenScripting API resolves the full dictionary the same way Script
/// Editor does. The symbol ships in Carbon but has no header in the Command Line Tools SDK, so it
/// is resolved at runtime instead of imported.
public enum OpenScriptingSdefLoader {
    public static func copySdefData(forBundleAt bundleURL: URL) -> Data? {
        typealias CopyScriptingDefinition = @convention(c) (
            CFURL, Int32, UnsafeMutablePointer<Unmanaged<CFData>?>
        ) -> Int32
        guard let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(carbon) }
        guard let symbol = dlsym(carbon, "OSACopyScriptingDefinitionFromURL") else { return nil }
        let copy = unsafeBitCast(symbol, to: CopyScriptingDefinition.self)
        var sdef: Unmanaged<CFData>?
        guard copy(bundleURL as CFURL, 0, &sdef) == 0, let sdef else { return nil }
        return sdef.takeRetainedValue() as Data
    }
}

/// Renders a dictionary into a bounded plain-text digest for prompts and planner results.
/// Condensing is structural only (drop descriptions, collapse the training-data-known Standard
/// Suite, shrink classes) — never filtered against the user's goal text.
public enum ScriptingDictionaryDigest {
    public static let defaultBudget = 4_500
    public static let truncationMarker = "…truncated; call app_commands with suite=<name> for full detail"

    /// Suite names whose contents every AppleScript author already knows; collapsed first.
    private static let standardSuiteNames: Set<String> = ["standard suite"]

    struct Options {
        var includeSummaries = true
        var collapseStandardSuites = false
        var classPropertyNamesOnly = false
    }

    public static func render(_ dictionary: ScriptingDictionary, budget: Int = defaultBudget) -> String {
        let tiers: [Options] = [
            Options(),
            Options(includeSummaries: false, collapseStandardSuites: true),
            Options(includeSummaries: false, collapseStandardSuites: true, classPropertyNamesOnly: true)
        ]
        for options in tiers {
            let rendered = render(dictionary, options: options)
            if rendered.count <= budget { return rendered }
        }
        let smallest = render(dictionary, options: tiers[tiers.count - 1])
        return String(smallest.prefix(max(0, budget - truncationMarker.count - 1))) + "\n" + truncationMarker
    }

    /// Full detail for one suite — the drill-down path when the whole-dictionary digest condensed it.
    public static func render(suite: ScriptingSuite, of dictionary: ScriptingDictionary, budget: Int = defaultBudget) -> String {
        let header = headerLine(dictionary)
        let body = renderSuite(suite, options: Options())
        let rendered = header + "\n" + body
        guard rendered.count > budget else { return rendered }
        return String(rendered.prefix(max(0, budget - truncationMarker.count - 1))) + "\n" + truncationMarker
    }

    static func render(_ dictionary: ScriptingDictionary, options: Options) -> String {
        // App-specific suites carry the unfamiliar terminology; keep them ahead of standard suites
        // so condensation trims the well-known material first.
        let ordered = dictionary.suites.sorted { isStandard($0) == isStandard($1) ? false : !isStandard($0) }
        let body = ordered.map { suite in
            if options.collapseStandardSuites, isStandard(suite) {
                let names = suite.commands.map(\.name).joined(separator: ", ")
                return "suite \"\(suite.name)\": commands(\(names))"
            }
            return renderSuite(suite, options: options)
        }
        return ([headerLine(dictionary)] + body).joined(separator: "\n")
    }

    private static func headerLine(_ dictionary: ScriptingDictionary) -> String {
        var header = "app \"\(dictionary.appName)\""
        if !dictionary.bundleIdentifier.isEmpty { header += " (\(dictionary.bundleIdentifier))" }
        return header + " scripting dictionary:"
    }

    private static func renderSuite(_ suite: ScriptingSuite, options: Options) -> String {
        var lines = ["suite \"\(suite.name)\":"]
        for command in suite.commands {
            lines.append("  " + renderCommand(command, options: options))
        }
        for scriptingClass in suite.classes {
            lines.append("  " + renderClass(scriptingClass, options: options))
        }
        for enumeration in suite.enumerations {
            lines.append("  enum \(enumeration.name): \(enumeration.enumeratorNames.joined(separator: " / "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderCommand(_ command: ScriptingCommand, options: Options) -> String {
        var parts: [String] = []
        if let direct = command.directParameter {
            parts.append("direct=(\(direct.type))" + (direct.isOptional ? " optional" : ""))
        }
        let parameters = command.parameters.map { parameter in
            "\(parameter.name) (\(parameter.type)\(parameter.isOptional ? ", optional" : ""))"
        }
        parts.append(contentsOf: parameters)
        var line = "command \"\(command.name)\""
        if !parts.isEmpty { line += ": " + parts.joined(separator: "; ") }
        if !command.resultType.isEmpty { line += " -> \(command.resultType)" }
        if options.includeSummaries, !command.summary.isEmpty { line += " — \(command.summary)" }
        return line
    }

    private static func renderClass(_ scriptingClass: ScriptingClass, options: Options) -> String {
        var line = "class \(scriptingClass.name)"
        if !scriptingClass.properties.isEmpty {
            let properties = scriptingClass.properties.map { property -> String in
                if options.classPropertyNamesOnly { return property.name }
                var rendered = "\(property.name): \(property.type)"
                if property.isReadOnly { rendered += " [r]" }
                return rendered
            }
            line += ": properties(\(properties.joined(separator: ", ")))"
        }
        if !scriptingClass.elementClassNames.isEmpty {
            line += "; elements(\(scriptingClass.elementClassNames.joined(separator: ", ")))"
        }
        if options.includeSummaries, !scriptingClass.summary.isEmpty { line += " — \(scriptingClass.summary)" }
        return line
    }

    private static func isStandard(_ suite: ScriptingSuite) -> Bool {
        standardSuiteNames.contains(suite.name.lowercased())
    }
}
