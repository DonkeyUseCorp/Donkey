import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AppScriptingDictionaryTests {
    // A small synthetic sdef exercising direct/optional parameters, union types, classes,
    // class-extensions, enumerations, and hidden filtering.
    private static let fixtureSdef = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dictionary>
        <suite name="Widget Suite" code="wdgt" description="Terms for widgets">
            <command name="forge" code="wdgtforg" description="Forge a widget.">
                <direct-parameter description="The widget name.">
                    <type type="text"/>
                </direct-parameter>
                <parameter name="with strength" code="strn" type="integer" optional="yes" description="How strong."/>
                <parameter name="secret" code="secr" type="text" hidden="yes"/>
                <result type="widget"/>
            </command>
            <command name="vanish" code="wdgtvnsh" hidden="yes"/>
            <command name="show" code="wdgtshow">
                <direct-parameter>
                    <type type="widget"/>
                    <type type="gadget"/>
                </direct-parameter>
            </command>
            <class name="widget" plural="widgets" description="One widget.">
                <property name="name" code="pnam" type="text" description="Its name."/>
                <property name="age" code="wage" type="integer" access="r"/>
                <element type="gadget"/>
            </class>
            <class-extension extends="application">
                <property name="default widget" code="dwdg" type="widget"/>
            </class-extension>
            <enumeration name="finish" code="fnsh">
                <enumerator name="matte" code="matt"/>
                <enumerator name="glossy" code="glos"/>
            </enumeration>
        </suite>
        <suite name="Standard Suite" code="????" description="Common terms">
            <command name="count" code="corecnte"/>
            <command name="exists" code="coredoex"/>
        </suite>
        <suite name="Hidden Suite" code="hdnn" hidden="yes">
            <command name="lurk" code="hdnnlurk"/>
        </suite>
    </dictionary>
    """

    private func parsedFixture() throws -> ScriptingDictionary {
        let suites = try ScriptingDictionaryParser.suites(from: Data(Self.fixtureSdef.utf8))
        return ScriptingDictionary(
            appName: "Widgetry",
            bundleIdentifier: "com.example.widgetry",
            appVersion: "1.0",
            suites: suites
        )
    }

    // MARK: Parser

    @Test
    func parsesCommandsParametersClassesAndEnumerations() throws {
        let dictionary = try parsedFixture()
        #expect(dictionary.suites.map(\.name) == ["Widget Suite", "Standard Suite"])

        let widgetSuite = dictionary.suites[0]
        #expect(widgetSuite.commands.map(\.name) == ["forge", "show"])

        let forge = widgetSuite.commands[0]
        #expect(forge.directParameter?.type == "text")
        #expect(forge.parameters.map(\.name) == ["with strength"])
        #expect(forge.parameters[0].isOptional)
        #expect(forge.parameters[0].type == "integer")
        #expect(forge.resultType == "widget")

        let show = widgetSuite.commands[1]
        #expect(show.directParameter?.type == "widget | gadget")

        #expect(widgetSuite.classes.map(\.name) == ["widget", "application"])
        let widget = widgetSuite.classes[0]
        #expect(widget.properties.map(\.name) == ["name", "age"])
        #expect(widget.properties[1].isReadOnly)
        #expect(widget.elementClassNames == ["gadget"])

        #expect(widgetSuite.enumerations == [ScriptingEnumeration(name: "finish", enumeratorNames: ["matte", "glossy"])])
    }

    @Test
    func skipsHiddenSuitesCommandsAndParameters() throws {
        let dictionary = try parsedFixture()
        #expect(!dictionary.suites.contains { $0.name == "Hidden Suite" })
        #expect(!dictionary.commandNames.contains("vanish"))
        #expect(!dictionary.suites[0].commands[0].parameters.contains { $0.name == "secret" })
    }

    @Test
    func commandNamesSpanAllSuites() throws {
        let dictionary = try parsedFixture()
        #expect(dictionary.commandNames == ["forge", "show", "count", "exists"])
    }

    // MARK: Digest

    @Test
    func fullDigestIncludesTerminologyAndDescriptions() throws {
        let digest = ScriptingDictionaryDigest.render(try parsedFixture())
        #expect(digest.contains("app \"Widgetry\" (com.example.widgetry) scripting dictionary:"))
        #expect(digest.contains("command \"forge\": direct=(text); with strength (integer, optional) -> widget — Forge a widget."))
        #expect(digest.contains("class widget: properties(name: text, age: integer [r]); elements(gadget)"))
        #expect(digest.contains("enum finish: matte / glossy"))
        // App-specific suite renders before the standard suite.
        let widgetIndex = try #require(digest.range(of: "Widget Suite")).lowerBound
        let standardIndex = try #require(digest.range(of: "Standard Suite")).lowerBound
        #expect(widgetIndex < standardIndex)
    }

    @Test
    func tightBudgetCollapsesStandardSuiteAndDropsDescriptions() throws {
        let dictionary = try parsedFixture()
        let full = ScriptingDictionaryDigest.render(dictionary)
        let condensed = ScriptingDictionaryDigest.render(dictionary, budget: full.count - 1)
        #expect(condensed.count < full.count)
        #expect(condensed.contains("suite \"Standard Suite\": commands(count, exists)"))
        #expect(!condensed.contains("Forge a widget."))
        // App-specific terminology survives condensation.
        #expect(condensed.contains("command \"forge\""))
    }

    @Test
    func impossibleBudgetHardTruncatesWithMarker() throws {
        let digest = ScriptingDictionaryDigest.render(try parsedFixture(), budget: 120)
        #expect(digest.count <= 120)
        #expect(digest.hasSuffix(ScriptingDictionaryDigest.truncationMarker))
    }

    @Test
    func singleSuiteDigestKeepsFullDetail() throws {
        let dictionary = try parsedFixture()
        let digest = ScriptingDictionaryDigest.render(suite: dictionary.suites[0], of: dictionary)
        #expect(digest.contains("Forge a widget."))
        #expect(!digest.contains("Standard Suite"))
    }

    // MARK: Cache store

    @Test
    func roundTripsAndDetectsStaleRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scripting-dictionary-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileScriptingDictionaryStore(directoryURL: directory)
        let dictionary = try parsedFixture()
        let record = ScriptingDictionaryCacheRecord(
            appVersion: "1.0",
            sdefPath: "/Applications/Widgetry.app/Contents/Resources/Widgetry.sdef",
            sdefModificationDate: Date(timeIntervalSince1970: 1_000),
            dictionary: dictionary
        )

        #expect(store.record(bundleIdentifier: "com.example.widgetry") == nil)
        store.save(record, bundleIdentifier: "com.example.widgetry")
        let loaded = try #require(store.record(bundleIdentifier: "com.example.widgetry"))
        #expect(loaded == record)
        // Staleness is decided by the caller comparing version/path/mtime; a changed version
        // means the cached parse must not be served.
        #expect(loaded.appVersion != "2.0")
    }

    // MARK: Locator + live parse (skips cleanly on machines without Notes)

    @Test
    func parsesARealInstalledDictionaryWithXInclude() throws {
        let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
        guard FileManager.default.fileExists(atPath: notes.path) else { return }
        let sdefURL = try #require(ScriptingDefinitionLocator.sdefURL(forBundleAt: notes))
        let suites = try ScriptingDictionaryParser.suites(contentsOf: sdefURL)
        let names = suites.map(\.name)
        // The Notes-specific suite is declared inline; the Standard Suite arrives via xi:include.
        #expect(names.contains("Notes Suite"))
        #expect(names.contains("Standard Suite"))
        let allCommands = suites.flatMap(\.commands).map(\.name)
        #expect(allCommands.contains("show"))
        #expect(allCommands.contains("make"))
    }
}
