import Foundation

public enum MacAccessibilityTrustStatus: String, Codable, Equatable, Sendable {
    case trusted
    case notTrusted
}

public struct MacAccessibilitySnapshotLimits: Codable, Equatable, Sendable {
    public var maxDepth: Int
    public var maxChildrenPerNode: Int
    public var maxTotalNodes: Int
    public var maxTextLength: Int

    public init(
        maxDepth: Int = 2,
        maxChildrenPerNode: Int = 25,
        maxTotalNodes: Int = 100,
        maxTextLength: Int = 80
    ) {
        self.maxDepth = max(0, maxDepth)
        self.maxChildrenPerNode = max(0, maxChildrenPerNode)
        self.maxTotalNodes = max(1, maxTotalNodes)
        self.maxTextLength = max(1, maxTextLength)
    }

    public static let `default` = MacAccessibilitySnapshotLimits()
}

public struct MacAccessibilitySnapshotNode: Codable, Equatable, Sendable {
    public var nodeID: String
    public var role: String?
    public var title: String?
    public var label: String?
    public var valueSummary: String?
    public var frame: WindowTargetBounds?
    public var isEnabled: Bool?
    public var isFocused: Bool?
    public var actions: [String]
    public var children: [MacAccessibilitySnapshotNode]
    public var isChildrenTruncated: Bool

    public init(
        nodeID: String,
        role: String? = nil,
        title: String? = nil,
        label: String? = nil,
        valueSummary: String? = nil,
        frame: WindowTargetBounds? = nil,
        isEnabled: Bool? = nil,
        isFocused: Bool? = nil,
        actions: [String] = [],
        children: [MacAccessibilitySnapshotNode] = [],
        isChildrenTruncated: Bool = false
    ) {
        self.nodeID = nodeID
        self.role = role
        self.title = title
        self.label = label
        self.valueSummary = valueSummary
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.actions = actions
        self.children = children
        self.isChildrenTruncated = isChildrenTruncated
    }
}

public struct RawMacAccessibilitySnapshotNode: Codable, Equatable, Sendable {
    public var role: String?
    public var title: String?
    public var label: String?
    public var valueSummary: String?
    public var frame: WindowTargetBounds?
    public var isEnabled: Bool?
    public var isFocused: Bool?
    public var actions: [String]
    public var children: [RawMacAccessibilitySnapshotNode]

    public init(
        role: String? = nil,
        title: String? = nil,
        label: String? = nil,
        valueSummary: String? = nil,
        frame: WindowTargetBounds? = nil,
        isEnabled: Bool? = nil,
        isFocused: Bool? = nil,
        actions: [String] = [],
        children: [RawMacAccessibilitySnapshotNode] = []
    ) {
        self.role = role
        self.title = title
        self.label = label
        self.valueSummary = valueSummary
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.actions = actions
        self.children = children
    }
}

public struct MacAccessibilitySnapshotTree: Codable, Equatable, Sendable {
    public var root: MacAccessibilitySnapshotNode
    public var totalNodeCount: Int
    public var isTreeTruncated: Bool

    public init(
        root: MacAccessibilitySnapshotNode,
        totalNodeCount: Int,
        isTreeTruncated: Bool
    ) {
        self.root = root
        self.totalNodeCount = totalNodeCount
        self.isTreeTruncated = isTreeTruncated
    }
}

public enum MacAccessibilitySnapshotTreeBuilder {
    public static func build(
        root: RawMacAccessibilitySnapshotNode,
        limits: MacAccessibilitySnapshotLimits
    ) -> MacAccessibilitySnapshotTree {
        var emittedNodeCount = 0
        var isTreeTruncated = false
        let rootNode = buildNode(
            root,
            path: "ax-1",
            depth: 0,
            limits: limits,
            emittedNodeCount: &emittedNodeCount,
            isTreeTruncated: &isTreeTruncated
        ) ?? MacAccessibilitySnapshotNode(nodeID: "ax-1")

        return MacAccessibilitySnapshotTree(
            root: rootNode,
            totalNodeCount: emittedNodeCount,
            isTreeTruncated: isTreeTruncated
        )
    }

    private static func buildNode(
        _ rawNode: RawMacAccessibilitySnapshotNode,
        path: String,
        depth: Int,
        limits: MacAccessibilitySnapshotLimits,
        emittedNodeCount: inout Int,
        isTreeTruncated: inout Bool
    ) -> MacAccessibilitySnapshotNode? {
        guard emittedNodeCount < limits.maxTotalNodes else {
            isTreeTruncated = true
            return nil
        }

        emittedNodeCount += 1
        let canReadChildren = depth < limits.maxDepth
        let allowedChildCount = canReadChildren
            ? min(rawNode.children.count, limits.maxChildrenPerNode)
            : 0
        var children: [MacAccessibilitySnapshotNode] = []

        for (index, child) in rawNode.children.prefix(allowedChildCount).enumerated() {
            guard let childNode = buildNode(
                child,
                path: "\(path).\(index + 1)",
                depth: depth + 1,
                limits: limits,
                emittedNodeCount: &emittedNodeCount,
                isTreeTruncated: &isTreeTruncated
            ) else {
                break
            }

            children.append(childNode)
        }

        let omittedChildren = rawNode.children.count > children.count
        if omittedChildren {
            isTreeTruncated = true
        }

        return MacAccessibilitySnapshotNode(
            nodeID: path,
            role: summarizeText(rawNode.role, limit: limits.maxTextLength),
            title: summarizeText(rawNode.title, limit: limits.maxTextLength),
            label: summarizeText(rawNode.label, limit: limits.maxTextLength),
            valueSummary: summarizeText(rawNode.valueSummary, limit: limits.maxTextLength),
            frame: rawNode.frame,
            isEnabled: rawNode.isEnabled,
            isFocused: rawNode.isFocused,
            actions: rawNode.actions.compactMap {
                summarizeText($0, limit: limits.maxTextLength)
            },
            children: children,
            isChildrenTruncated: omittedChildren
        )
    }

    private static func summarizeText(
        _ value: String?,
        limit: Int
    ) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        guard trimmed.count <= limit else {
            return "[redacted length=\(trimmed.count)]"
        }

        return trimmed
    }
}

public struct MacAccessibilitySnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var target: MacWindowTargetCandidate
    public var limits: MacAccessibilitySnapshotLimits
    public var root: MacAccessibilitySnapshotNode
    public var totalNodeCount: Int
    public var isTreeTruncated: Bool

    public init(
        schemaVersion: Int = 1,
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits,
        root: MacAccessibilitySnapshotNode,
        totalNodeCount: Int,
        isTreeTruncated: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.target = target
        self.limits = limits
        self.root = root
        self.totalNodeCount = totalNodeCount
        self.isTreeTruncated = isTreeTruncated
    }
}
