import DonkeyContracts
import Foundation

public enum DocumentFormFillPlanStatus: String, Codable, Equatable, Sendable {
    case readyForReview
    case needsDocumentContext
    case needsStructuredData
    case needsFieldDiscovery
}

public struct DocumentFormFillProposal: Codable, Equatable, Sendable {
    public var fieldID: String
    public var fieldLabel: String
    public var proposedValue: String
    public var sourceKey: String
    public var confidence: Double
    public var metadata: [String: String]

    public init(
        fieldID: String,
        fieldLabel: String,
        proposedValue: String,
        sourceKey: String,
        confidence: Double,
        metadata: [String: String] = [:]
    ) {
        self.fieldID = fieldID
        self.fieldLabel = fieldLabel
        self.proposedValue = proposedValue
        self.sourceKey = sourceKey
        self.confidence = min(max(confidence, 0), 1)
        self.metadata = metadata
    }
}

public struct DocumentFormFillPlan: Codable, Equatable, Sendable {
    public var status: DocumentFormFillPlanStatus
    public var proposals: [DocumentFormFillProposal]
    public var unmappedRequiredFieldIDs: [String]
    public var unusedDataKeys: [String]
    public var metadata: [String: String]

    public init(
        status: DocumentFormFillPlanStatus,
        proposals: [DocumentFormFillProposal] = [],
        unmappedRequiredFieldIDs: [String] = [],
        unusedDataKeys: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.status = status
        self.proposals = proposals
        self.unmappedRequiredFieldIDs = unmappedRequiredFieldIDs
        self.unusedDataKeys = unusedDataKeys
        self.metadata = metadata
    }
}

public enum DocumentFormFillApprovalStatus: String, Codable, Equatable, Sendable {
    case approved
    case rejected
    case partiallyApproved
}

public struct DocumentFormFillApproval: Codable, Equatable, Sendable {
    public var id: String
    public var traceID: String
    public var status: DocumentFormFillApprovalStatus
    public var approvedProposals: [DocumentFormFillProposal]
    public var rejectedFieldIDs: [String]
    public var metadata: [String: String]

    public init(
        id: String,
        traceID: String,
        status: DocumentFormFillApprovalStatus,
        approvedProposals: [DocumentFormFillProposal],
        rejectedFieldIDs: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.traceID = traceID
        self.status = status
        self.approvedProposals = approvedProposals
        self.rejectedFieldIDs = rejectedFieldIDs
        self.metadata = metadata
    }
}

public struct DocumentFormFillPlanner: Sendable {
    public init() {}

    public func plan(
        intent: TaskIntent,
        definition: LocalAppTaskDefinition,
        context: LocalAppTaskContext
    ) -> DocumentFormFillPlan {
        guard definition.taskType == "document_form_fill" else {
            return DocumentFormFillPlan(
                status: .needsDocumentContext,
                metadata: ["reason": "unsupportedTaskType"]
            )
        }

        guard hasDocumentContext(intent: intent, context: context) else {
            return DocumentFormFillPlan(
                status: .needsDocumentContext,
                metadata: ["reason": "missingDocumentContext"]
            )
        }

        let data = effectiveStructuredData(intent: intent, context: context)
        guard !data.isEmpty else {
            return DocumentFormFillPlan(
                status: .needsStructuredData,
                metadata: ["reason": "missingStructuredData"]
            )
        }

        let fields = context.observedFormFields
        guard !fields.isEmpty else {
            return DocumentFormFillPlan(
                status: .needsFieldDiscovery,
                unusedDataKeys: data.keys.sorted(),
                metadata: [
                    "reason": "missingObservedFields",
                    "dataKeyCount": String(data.count)
                ]
            )
        }

        var usedKeys: Set<String> = []
        let proposals = fields.compactMap { field -> DocumentFormFillProposal? in
            guard let match = bestDataMatch(for: field, data: data, usedKeys: usedKeys) else {
                return nil
            }
            usedKeys.insert(match.key)
            return DocumentFormFillProposal(
                fieldID: field.id,
                fieldLabel: field.label,
                proposedValue: match.value,
                sourceKey: match.key,
                confidence: match.exact ? 0.94 : 0.72,
                metadata: ["match": match.exact ? "exact" : "fuzzy"]
            )
        }

        let mappedFieldIDs = Set(proposals.map(\.fieldID))
        let unmappedRequired = fields
            .filter { $0.isRequired && !mappedFieldIDs.contains($0.id) }
            .map(\.id)
            .sorted()
        let unusedKeys = data.keys
            .filter { !usedKeys.contains($0) }
            .sorted()

        return DocumentFormFillPlan(
            status: .readyForReview,
            proposals: proposals,
            unmappedRequiredFieldIDs: unmappedRequired,
            unusedDataKeys: unusedKeys,
            metadata: [
                "proposalCount": String(proposals.count),
                "fieldCount": String(fields.count),
                "dataKeyCount": String(data.count),
                "requiresReview": "true"
            ]
        )
    }

    public func approval(
        for plan: DocumentFormFillPlan,
        traceID: String,
        approvedFieldIDs: Set<String>
    ) -> DocumentFormFillApproval {
        let approved = plan.proposals.filter { approvedFieldIDs.contains($0.fieldID) }
        let rejected = plan.proposals
            .filter { !approvedFieldIDs.contains($0.fieldID) }
            .map(\.fieldID)
            .sorted()
        let status: DocumentFormFillApprovalStatus
        if approved.isEmpty {
            status = .rejected
        } else if rejected.isEmpty {
            status = .approved
        } else {
            status = .partiallyApproved
        }

        return DocumentFormFillApproval(
            id: "document-form-fill-approval-\(traceID)",
            traceID: traceID,
            status: status,
            approvedProposals: approved,
            rejectedFieldIDs: rejected,
            metadata: [
                "requiresUserApproval": "true",
                "approvedProposalCount": String(approved.count),
                "rejectedProposalCount": String(rejected.count)
            ]
        )
    }

    private func hasDocumentContext(
        intent: TaskIntent,
        context: LocalAppTaskContext
    ) -> Bool {
        intent.normalizedEntities["document"] != nil
            || context.focusedWindowTitle != nil
            || !context.attachedFileURLs.isEmpty
    }

    private func effectiveStructuredData(
        intent: TaskIntent,
        context: LocalAppTaskContext
    ) -> [String: String] {
        if !context.structuredData.isEmpty {
            return context.structuredData
        }

        return intent.normalizedEntities
            .filter { key, _ in
                key != "document" && key != "dataSource"
            }
    }

    private func bestDataMatch(
        for field: LocalDocumentFormField,
        data: [String: String],
        usedKeys: Set<String>
    ) -> (key: String, value: String, exact: Bool)? {
        let fieldName = normalized(field.label)
        let unused = data.filter { !usedKeys.contains($0.key) }

        if let exact = unused.first(where: { normalized($0.key) == fieldName }) {
            return (exact.key, exact.value, true)
        }

        if let fuzzy = unused.first(where: { item in
            let key = normalized(item.key)
            return fieldName.contains(key) || key.contains(fieldName)
        }) {
            return (fuzzy.key, fuzzy.value, false)
        }

        return nil
    }

    private func normalized(_ value: String) -> String {
        LocalAppTaskIntentParser.normalizedPhrase(value)
    }
}
