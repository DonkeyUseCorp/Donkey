@preconcurrency import ApplicationServices
import AppKit
import DonkeyContracts
import Foundation

public struct LocalDocumentFormField: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var isRequired: Bool
    public var currentValue: String?
    public var metadata: [String: String]

    public init(
        id: String,
        label: String,
        isRequired: Bool = false,
        currentValue: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.label = label
        self.isRequired = isRequired
        self.currentValue = currentValue
        self.metadata = metadata
    }
}

public struct LocalAppTaskContext: Equatable, Sendable {
    public var focusedAppName: String?
    public var focusedBundleIdentifier: String?
    public var focusedWindowTitle: String?
    public var focusedWindowID: UInt32?
    public var clipboardText: String?
    public var attachedFileURLs: [URL]
    public var structuredData: [String: String]
    public var observedFormFields: [LocalDocumentFormField]
    public var metadata: [String: String]

    public init(
        focusedAppName: String? = nil,
        focusedBundleIdentifier: String? = nil,
        focusedWindowTitle: String? = nil,
        focusedWindowID: UInt32? = nil,
        clipboardText: String? = nil,
        attachedFileURLs: [URL] = [],
        structuredData: [String: String] = [:],
        observedFormFields: [LocalDocumentFormField] = [],
        metadata: [String: String] = [:]
    ) {
        self.focusedAppName = focusedAppName
        self.focusedBundleIdentifier = focusedBundleIdentifier
        self.focusedWindowTitle = focusedWindowTitle
        self.focusedWindowID = focusedWindowID
        self.clipboardText = clipboardText
        self.attachedFileURLs = attachedFileURLs
        self.structuredData = structuredData
        self.observedFormFields = observedFormFields
        self.metadata = metadata
    }
}

public protocol LocalAppTaskContextProviding: Sendable {
    @MainActor
    func snapshot() -> LocalAppTaskContext
}

public struct StaticLocalAppTaskContextProvider: LocalAppTaskContextProviding {
    public var context: LocalAppTaskContext

    public init(context: LocalAppTaskContext) {
        self.context = context
    }

    @MainActor
    public func snapshot() -> LocalAppTaskContext {
        context
    }
}

public struct MacLocalAppTaskContextProvider: LocalAppTaskContextProviding {
    public init() {}

    @MainActor
    public func snapshot() -> LocalAppTaskContext {
        let focusedWindow = try? MacWindowResolver().selectTarget()
        let clipboardText = NSPasteboard.general.string(forType: .string)
        let structuredData = Self.structuredData(from: clipboardText)
        let observedFormFields = Self.observedFormFields(from: focusedWindow)

        return LocalAppTaskContext(
            focusedAppName: focusedWindow?.appName,
            focusedBundleIdentifier: focusedWindow?.bundleIdentifier,
            focusedWindowTitle: focusedWindow?.title,
            focusedWindowID: focusedWindow?.windowID,
            clipboardText: clipboardText,
            structuredData: structuredData,
            observedFormFields: observedFormFields,
            metadata: [
                "provider": "mac-local-app-task-context",
                "clipboard.hasText": String(clipboardText?.isEmpty == false),
                "focusedWindow.resolved": String(focusedWindow != nil),
                "observedFormFieldCount": String(observedFormFields.count)
            ]
        )
    }

    @MainActor
    private static func observedFormFields(
        from focusedWindow: MacWindowTargetCandidate?
    ) -> [LocalDocumentFormField] {
        guard let focusedWindow,
              AXIsProcessTrusted()
        else {
            return []
        }

        let capturer = ApplicationServicesMacAccessibilitySnapshotCapturer()
        guard let tree = try? capturer.captureTree(
            target: focusedWindow,
            limits: MacAccessibilitySnapshotLimits(maxDepth: 6, maxChildrenPerNode: 80, maxTotalNodes: 500)
        ) else {
            return []
        }

        let snapshot = MacAccessibilitySnapshot(
            target: focusedWindow,
            limits: MacAccessibilitySnapshotLimits(maxDepth: 6, maxChildrenPerNode: 80, maxTotalNodes: 500),
            root: tree.root,
            totalNodeCount: tree.totalNodeCount,
            isTreeTruncated: tree.isTreeTruncated
        )
        return LocalAppAccessibilityControlDiscovery().observedFormFields(in: snapshot)
    }

    private static func structuredData(from text: String?) -> [String: String] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }

        if let jsonData = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return object.reduce(into: [:]) { result, item in
                if let value = item.value as? String {
                    result[item.key] = value
                } else if let value = item.value as? NSNumber {
                    result[item.key] = value.stringValue
                }
            }
        }

        return text
            .split(whereSeparator: \.isNewline)
            .reduce(into: [:]) { result, line in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty else { return }
                result[key] = value
            }
    }
}
