import DonkeyContracts
import Foundation

public enum LocalAppTaskDefinitionLoaderError: Error, Equatable, Sendable {
    case unsupportedFileExtension(String)
    case unreadableDirectory(URL)
    case decodeFailed(URL, String)
}

public struct LocalAppTaskDefinitionLoader: Sendable {
    public var decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("TaskDefinitions", isDirectory: true)
    }

    public func load(from url: URL) throws -> [LocalAppTaskDefinition] {
        switch url.pathExtension.lowercased() {
        case "json":
            return try loadJSON(from: url)
        case "jsonl":
            return try loadJSONLines(from: url)
        default:
            throw LocalAppTaskDefinitionLoaderError.unsupportedFileExtension(url.pathExtension)
        }
    }

    public func loadDirectory(_ directoryURL: URL) throws -> [LocalAppTaskDefinition] {
        guard let fileURLs = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw LocalAppTaskDefinitionLoaderError.unreadableDirectory(directoryURL)
        }

        var definitions: [LocalAppTaskDefinition] = []
        for case let fileURL as URL in fileURLs {
            guard ["json", "jsonl"].contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            definitions.append(contentsOf: try load(from: fileURL))
        }
        return definitions
    }

    public func mergedWithBuiltIns(from directoryURL: URL) throws -> [LocalAppTaskDefinition] {
        BuiltInLocalAppTaskDefinitions.defaults + (try loadDirectory(directoryURL))
    }

    public func defaultDefinitions() -> [LocalAppTaskDefinition] {
        (try? mergedWithBuiltIns(from: Self.defaultDirectoryURL))
            ?? BuiltInLocalAppTaskDefinitions.defaults
    }

    private func loadJSON(from url: URL) throws -> [LocalAppTaskDefinition] {
        do {
            let data = try Data(contentsOf: url)
            if let array = try? decoder.decode([LocalAppTaskDefinition].self, from: data) {
                return array
            }
            return [try decoder.decode(LocalAppTaskDefinition.self, from: data)]
        } catch {
            throw LocalAppTaskDefinitionLoaderError.decodeFailed(url, String(describing: error))
        }
    }

    private func loadJSONLines(from url: URL) throws -> [LocalAppTaskDefinition] {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return try text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { line in
                    try decoder.decode(LocalAppTaskDefinition.self, from: Data(line.utf8))
                }
        } catch {
            throw LocalAppTaskDefinitionLoaderError.decodeFailed(url, String(describing: error))
        }
    }
}

public extension LocalAppTaskCatalog {
    static func defaultLocal(
        availabilityProvider: any LocalAppAvailabilityProviding = MacLocalAppAvailabilityProvider(),
        loader: LocalAppTaskDefinitionLoader = LocalAppTaskDefinitionLoader()
    ) -> LocalAppTaskCatalog {
        LocalAppTaskCatalog(
            taskDefinitions: loader.defaultDefinitions(),
            availabilityProvider: availabilityProvider
        )
    }
}
