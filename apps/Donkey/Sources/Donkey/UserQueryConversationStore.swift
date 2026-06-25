import DonkeyContracts
import CoreData
import Foundation

@MainActor
protocol UserQueryConversationStoring {
    func loadRecentConversations(limit: Int) -> [UserQueryConversation]
    func searchConversations(matching query: String, limit: Int) -> [UserQueryConversation]
    func upsertConversation(_ conversation: UserQueryConversation)
    func deleteConversation(id: String)
    func loadEvents(conversationID: String) -> [UserQueryConversationEvent]
    func appendEvent(_ event: UserQueryConversationEvent)
    func loadAssets(conversationID: String) -> [UserQueryConversationAsset]
    func appendAsset(_ asset: UserQueryConversationAsset)
}

@MainActor
final class CoreDataUserQueryConversationStore: UserQueryConversationStoring {
    private let context: NSManagedObjectContext?

    init(
        storeURL: URL? = nil
    ) {
        context = Self.makeContext(storeURL: storeURL ?? Self.defaultStoreURL())
    }

    func loadRecentConversations(limit: Int) -> [UserQueryConversation] {
        guard let context else {
            return []
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.conversationEntityName)
        request.fetchLimit = limit
        request.sortDescriptors = [
            NSSortDescriptor(key: Self.updatedAtKey, ascending: false)
        ]

        guard let managedConversations = try? context.fetch(request) else {
            return []
        }

        return managedConversations.compactMap(Self.conversation(from:))
    }

    func searchConversations(matching query: String, limit: Int) -> [UserQueryConversation] {
        guard let context else {
            return []
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return loadRecentConversations(limit: limit)
        }

        let matchingEventConversationIDs = conversationIDsWithMatchingEvents(trimmedQuery)
        let matchingAssetConversationIDs = conversationIDsWithMatchingAssets(trimmedQuery)
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.conversationEntityName)
        request.fetchLimit = limit
        var predicates = [
            NSPredicate(format: "%K CONTAINS[cd] %@", Self.titleKey, trimmedQuery),
            NSPredicate(format: "%K CONTAINS[cd] %@", Self.detailKey, trimmedQuery),
            NSPredicate(format: "%K CONTAINS[cd] %@", Self.commandTextKey, trimmedQuery)
        ]
        if !matchingEventConversationIDs.isEmpty {
            predicates.append(NSPredicate(format: "%K IN %@", Self.idKey, matchingEventConversationIDs))
        }
        if !matchingAssetConversationIDs.isEmpty {
            predicates.append(NSPredicate(format: "%K IN %@", Self.idKey, matchingAssetConversationIDs))
        }
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: Self.updatedAtKey, ascending: false)
        ]

        guard let managedConversations = try? context.fetch(request) else {
            return []
        }

        return managedConversations.compactMap(Self.conversation(from:))
    }

    func upsertConversation(_ conversation: UserQueryConversation) {
        guard let context else { return }

        let managedConversation = Self.existingConversation(id: conversation.id, in: context)
            ?? NSManagedObject(entity: Self.entityDescription(in: context), insertInto: context)

        managedConversation.setValue(conversation.id, forKey: Self.idKey)
        managedConversation.setValue(conversation.title, forKey: Self.titleKey)
        managedConversation.setValue(conversation.detail, forKey: Self.detailKey)
        managedConversation.setValue(conversation.commandText, forKey: Self.commandTextKey)
        managedConversation.setValue(conversation.status.rawValue, forKey: Self.statusKey)
        managedConversation.setValue(Int64(conversation.accentIndex), forKey: Self.accentIndexKey)
        managedConversation.setValue(conversation.origin.rawValue, forKey: Self.originKey)
        managedConversation.setValue(conversation.createdAt, forKey: Self.createdAtKey)
        managedConversation.setValue(conversation.updatedAt, forKey: Self.updatedAtKey)
        managedConversation.setValue(conversation.accumulatedActiveSeconds, forKey: Self.accumulatedActiveSecondsKey)
        managedConversation.setValue(conversation.runningSince, forKey: Self.runningSinceKey)
        managedConversation.setValue(Self.metadataJSONString(conversation.metadata), forKey: Self.metadataJSONKey)

        try? context.save()
    }

    /// Permanently removes a conversation and everything attached to it — its row plus all
    /// stored events and assets — so a dismissed conversation does not reappear on relaunch.
    func deleteConversation(id: String) {
        guard let context else { return }

        if let managedConversation = Self.existingConversation(id: id, in: context) {
            context.delete(managedConversation)
        }
        Self.deleteRows(entityName: Self.eventEntityName, conversationIDKey: Self.eventConversationIDKey, conversationID: id, in: context)
        Self.deleteRows(entityName: Self.assetEntityName, conversationIDKey: Self.assetConversationIDKey, conversationID: id, in: context)

        try? context.save()
    }

    func loadAssets(conversationID: String) -> [UserQueryConversationAsset] {
        guard let context else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.assetEntityName)
        request.predicate = NSPredicate(format: "%K == %@", Self.assetConversationIDKey, conversationID)
        request.sortDescriptors = [
            NSSortDescriptor(key: Self.assetCreatedAtKey, ascending: true)
        ]

        guard let managedAssets = try? context.fetch(request) else {
            return []
        }

        return managedAssets.compactMap(Self.asset(from:))
    }

    func appendAsset(_ asset: UserQueryConversationAsset) {
        guard let context else { return }

        let managedAsset = NSManagedObject(
            entity: Self.assetEntityDescription(in: context),
            insertInto: context
        )
        managedAsset.setValue(asset.id, forKey: Self.assetIDKey)
        managedAsset.setValue(asset.conversationID, forKey: Self.assetConversationIDKey)
        managedAsset.setValue(asset.eventID, forKey: Self.assetEventIDKey)
        managedAsset.setValue(asset.source.rawValue, forKey: Self.assetSourceKey)
        managedAsset.setValue(asset.displayName, forKey: Self.assetDisplayNameKey)
        managedAsset.setValue(asset.contentType, forKey: Self.assetContentTypeKey)
        managedAsset.setValue(asset.urlString, forKey: Self.assetURLStringKey)
        managedAsset.setValue(asset.byteCount.map(NSNumber.init(value:)), forKey: Self.assetByteCountKey)
        managedAsset.setValue(asset.createdAt, forKey: Self.assetCreatedAtKey)

        try? context.save()
    }

    func loadEvents(conversationID: String) -> [UserQueryConversationEvent] {
        guard let context else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.eventEntityName)
        request.predicate = NSPredicate(format: "%K == %@", Self.eventConversationIDKey, conversationID)
        request.sortDescriptors = [
            NSSortDescriptor(key: Self.eventSequenceKey, ascending: true),
            NSSortDescriptor(key: Self.eventCreatedAtKey, ascending: true)
        ]

        guard let managedEvents = try? context.fetch(request) else {
            return []
        }

        return managedEvents.compactMap(Self.event(from:))
    }

    func appendEvent(_ event: UserQueryConversationEvent) {
        guard let context else { return }

        let managedEvent = NSManagedObject(
            entity: Self.eventEntityDescription(in: context),
            insertInto: context
        )
        managedEvent.setValue(event.id, forKey: Self.eventIDKey)
        managedEvent.setValue(event.conversationID, forKey: Self.eventConversationIDKey)
        managedEvent.setValue(event.role.rawValue, forKey: Self.eventRoleKey)
        managedEvent.setValue(event.text, forKey: Self.eventTextKey)
        managedEvent.setValue(Int64(event.sequence), forKey: Self.eventSequenceKey)
        managedEvent.setValue(event.createdAt, forKey: Self.eventCreatedAtKey)

        try? context.save()
    }

    private static func makeContext(storeURL: URL) -> NSManagedObjectContext? {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model())
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: [
                    NSMigratePersistentStoresAutomaticallyOption: true,
                    NSInferMappingModelAutomaticallyOption: true
                ]
            )
        } catch {
            return nil
        }

        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        return context
    }

    private static func defaultStoreURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("UserQueryConversations.sqlite")
    }

    private static func model() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let conversationEntity = NSEntityDescription()
        conversationEntity.name = conversationEntityName
        conversationEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        conversationEntity.properties = [
            attribute(idKey, type: .stringAttributeType, isOptional: false),
            attribute(titleKey, type: .stringAttributeType, isOptional: false),
            attribute(detailKey, type: .stringAttributeType, isOptional: false),
            attribute(commandTextKey, type: .stringAttributeType, isOptional: true),
            attribute(statusKey, type: .stringAttributeType, isOptional: false),
            attribute(accentIndexKey, type: .integer64AttributeType, isOptional: false),
            // Optional so lightweight migration can add it to stores written before origin existed; a
            // null on an old row decodes to `.user` below.
            attribute(originKey, type: .stringAttributeType, isOptional: true),
            attribute(createdAtKey, type: .dateAttributeType, isOptional: false),
            attribute(updatedAtKey, type: .dateAttributeType, isOptional: false),
            // Optional so lightweight migration can add them to stores written before cumulative time
            // existed; a null on an old row reads back as 0 / nil below.
            attribute(accumulatedActiveSecondsKey, type: .doubleAttributeType, isOptional: true),
            // The open-stretch anchor. Non-nil persists "was running when we last saved" across a relaunch,
            // so the in-flight stretch can be banked at `updatedAt` and the clock continue rather than reset.
            attribute(runningSinceKey, type: .dateAttributeType, isOptional: true),
            attribute(metadataJSONKey, type: .stringAttributeType, isOptional: true)
        ]
        conversationEntity.uniquenessConstraints = [[idKey]]

        let eventEntity = NSEntityDescription()
        eventEntity.name = eventEntityName
        eventEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        eventEntity.properties = [
            attribute(eventIDKey, type: .stringAttributeType, isOptional: false),
            attribute(eventConversationIDKey, type: .stringAttributeType, isOptional: false),
            attribute(eventRoleKey, type: .stringAttributeType, isOptional: false),
            attribute(eventTextKey, type: .stringAttributeType, isOptional: false),
            attribute(eventSequenceKey, type: .integer64AttributeType, isOptional: false),
            attribute(eventCreatedAtKey, type: .dateAttributeType, isOptional: false)
        ]
        eventEntity.uniquenessConstraints = [[eventIDKey]]

        let assetEntity = NSEntityDescription()
        assetEntity.name = assetEntityName
        assetEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        assetEntity.properties = [
            attribute(assetIDKey, type: .stringAttributeType, isOptional: false),
            attribute(assetConversationIDKey, type: .stringAttributeType, isOptional: false),
            attribute(assetEventIDKey, type: .stringAttributeType, isOptional: true),
            attribute(assetSourceKey, type: .stringAttributeType, isOptional: false),
            attribute(assetDisplayNameKey, type: .stringAttributeType, isOptional: false),
            attribute(assetContentTypeKey, type: .stringAttributeType, isOptional: false),
            attribute(assetURLStringKey, type: .stringAttributeType, isOptional: false),
            attribute(assetByteCountKey, type: .integer64AttributeType, isOptional: true),
            attribute(assetCreatedAtKey, type: .dateAttributeType, isOptional: false)
        ]
        assetEntity.uniquenessConstraints = [[assetIDKey]]

        model.entities = [conversationEntity, eventEntity, assetEntity]
        return model
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        isOptional: Bool
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = isOptional
        return attribute
    }

    private static func entityDescription(in context: NSManagedObjectContext) -> NSEntityDescription {
        NSEntityDescription.entity(forEntityName: conversationEntityName, in: context)!
    }

    private static func eventEntityDescription(in context: NSManagedObjectContext) -> NSEntityDescription {
        NSEntityDescription.entity(forEntityName: eventEntityName, in: context)!
    }

    private static func assetEntityDescription(in context: NSManagedObjectContext) -> NSEntityDescription {
        NSEntityDescription.entity(forEntityName: assetEntityName, in: context)!
    }

    private static func deleteRows(
        entityName: String,
        conversationIDKey: String,
        conversationID: String,
        in context: NSManagedObjectContext
    ) {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "%K == %@", conversationIDKey, conversationID)
        guard let rows = try? context.fetch(request) else { return }
        for row in rows {
            context.delete(row)
        }
    }

    private static func existingConversation(id: String, in context: NSManagedObjectContext) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: conversationEntityName)
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "%K == %@", idKey, id)
        return try? context.fetch(request).first
    }

    private func conversationIDsWithMatchingEvents(_ query: String) -> [String] {
        guard let context else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.eventEntityName)
        request.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", Self.eventTextKey, query)

        guard let managedEvents = try? context.fetch(request) else {
            return []
        }

        return Array(Set(managedEvents.compactMap { $0.value(forKey: Self.eventConversationIDKey) as? String }))
    }

    private func conversationIDsWithMatchingAssets(_ query: String) -> [String] {
        guard let context else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.assetEntityName)
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "%K CONTAINS[cd] %@", Self.assetDisplayNameKey, query),
            NSPredicate(format: "%K CONTAINS[cd] %@", Self.assetContentTypeKey, query),
            NSPredicate(format: "%K CONTAINS[cd] %@", Self.assetURLStringKey, query)
        ])

        guard let managedAssets = try? context.fetch(request) else {
            return []
        }

        return Array(Set(managedAssets.compactMap { $0.value(forKey: Self.assetConversationIDKey) as? String }))
    }

    private static func conversation(from managedConversation: NSManagedObject) -> UserQueryConversation? {
        guard let id = managedConversation.value(forKey: idKey) as? String,
              let title = managedConversation.value(forKey: titleKey) as? String,
              let detail = managedConversation.value(forKey: detailKey) as? String,
              let rawStatus = managedConversation.value(forKey: statusKey) as? String,
              let status = UserQueryConversationStatus(rawValue: rawStatus),
              let createdAt = managedConversation.value(forKey: createdAtKey) as? Date,
              let updatedAt = managedConversation.value(forKey: updatedAtKey) as? Date else {
            return nil
        }

        let accentIndex = (managedConversation.value(forKey: accentIndexKey) as? NSNumber)?.intValue ?? 0
        let origin = (managedConversation.value(forKey: originKey) as? String)
            .flatMap(UserQueryConversationOrigin.init(rawValue:)) ?? .user
        return UserQueryConversation(
            id: id,
            title: title,
            detail: detail,
            commandText: managedConversation.value(forKey: commandTextKey) as? String ?? title,
            status: status,
            accentIndex: accentIndex,
            origin: origin,
            createdAt: createdAt,
            updatedAt: updatedAt,
            accumulatedActiveSeconds: (managedConversation.value(forKey: accumulatedActiveSecondsKey) as? NSNumber)?.doubleValue ?? 0,
            runningSince: managedConversation.value(forKey: runningSinceKey) as? Date,
            metadata: metadata(fromJSONString: managedConversation.value(forKey: metadataJSONKey) as? String)
        )
    }

    private static func metadataJSONString(_ metadata: [String: String]) -> String? {
        guard !metadata.isEmpty,
              let data = try? JSONEncoder().encode(metadata) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func metadata(fromJSONString string: String?) -> [String: String] {
        guard let string,
              let data = string.data(using: .utf8),
              let metadata = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        return metadata
    }

    private static func event(from managedEvent: NSManagedObject) -> UserQueryConversationEvent? {
        guard let id = managedEvent.value(forKey: eventIDKey) as? String,
              let conversationID = managedEvent.value(forKey: eventConversationIDKey) as? String,
              let rawRole = managedEvent.value(forKey: eventRoleKey) as? String,
              let role = UserQueryConversationEventRole(rawValue: rawRole),
              let text = managedEvent.value(forKey: eventTextKey) as? String,
              let createdAt = managedEvent.value(forKey: eventCreatedAtKey) as? Date else {
            return nil
        }

        let sequence = (managedEvent.value(forKey: eventSequenceKey) as? NSNumber)?.intValue ?? 0
        return UserQueryConversationEvent(
            id: id,
            conversationID: conversationID,
            role: role,
            text: text,
            sequence: sequence,
            createdAt: createdAt
        )
    }

    private static func asset(from managedAsset: NSManagedObject) -> UserQueryConversationAsset? {
        guard let id = managedAsset.value(forKey: assetIDKey) as? String,
              let conversationID = managedAsset.value(forKey: assetConversationIDKey) as? String,
              let rawSource = managedAsset.value(forKey: assetSourceKey) as? String,
              let source = UserQueryConversationAssetSource(rawValue: rawSource),
              let displayName = managedAsset.value(forKey: assetDisplayNameKey) as? String,
              let contentType = managedAsset.value(forKey: assetContentTypeKey) as? String,
              let urlString = managedAsset.value(forKey: assetURLStringKey) as? String,
              let createdAt = managedAsset.value(forKey: assetCreatedAtKey) as? Date else {
            return nil
        }

        return UserQueryConversationAsset(
            id: id,
            conversationID: conversationID,
            eventID: managedAsset.value(forKey: assetEventIDKey) as? String,
            source: source,
            displayName: displayName,
            contentType: contentType,
            urlString: urlString,
            byteCount: (managedAsset.value(forKey: assetByteCountKey) as? NSNumber)?.int64Value,
            createdAt: createdAt
        )
    }

    private static let conversationEntityName = "UserQueryStoredConversation"
    private static let eventEntityName = "UserQueryStoredConversationEvent"
    private static let assetEntityName = "UserQueryStoredConversationAsset"
    private static let idKey = "id"
    private static let titleKey = "title"
    private static let detailKey = "detail"
    private static let commandTextKey = "commandText"
    private static let statusKey = "status"
    private static let accentIndexKey = "accentIndex"
    private static let originKey = "origin"
    private static let createdAtKey = "createdAt"
    private static let updatedAtKey = "updatedAt"
    private static let accumulatedActiveSecondsKey = "accumulatedActiveSeconds"
    private static let runningSinceKey = "runningSince"
    private static let metadataJSONKey = "metadataJSON"
    private static let eventIDKey = "id"
    private static let eventConversationIDKey = "conversationID"
    private static let eventRoleKey = "role"
    private static let eventTextKey = "text"
    private static let eventSequenceKey = "sequence"
    private static let eventCreatedAtKey = "createdAt"
    private static let assetIDKey = "id"
    private static let assetConversationIDKey = "conversationID"
    private static let assetEventIDKey = "eventID"
    private static let assetSourceKey = "source"
    private static let assetDisplayNameKey = "displayName"
    private static let assetContentTypeKey = "contentType"
    private static let assetURLStringKey = "urlString"
    private static let assetByteCountKey = "byteCount"
    private static let assetCreatedAtKey = "createdAt"
}
