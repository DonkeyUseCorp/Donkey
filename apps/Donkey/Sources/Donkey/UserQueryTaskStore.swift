import DonkeyContracts
import CoreData
import Foundation

@MainActor
protocol UserQueryTaskStoring {
    func loadRecentTasks(limit: Int) -> [UserQueryNotchTask]
    func searchTasks(matching query: String, limit: Int) -> [UserQueryNotchTask]
    func upsertTask(_ task: UserQueryNotchTask)
    func deleteTask(id: String)
    func loadEvents(taskID: String) -> [UserQueryTaskEvent]
    func appendEvent(_ event: UserQueryTaskEvent)
    func loadAssets(taskID: String) -> [UserQueryTaskAsset]
    func appendAsset(_ asset: UserQueryTaskAsset)
}

@MainActor
final class CoreDataUserQueryTaskStore: UserQueryTaskStoring {
    private let context: NSManagedObjectContext?

    init(
        storeURL: URL? = nil
    ) {
        context = Self.makeContext(storeURL: storeURL ?? Self.defaultStoreURL())
    }

    func loadRecentTasks(limit: Int) -> [UserQueryNotchTask] {
        guard let context else {
            return []
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.taskEntityName)
        request.fetchLimit = limit
        request.sortDescriptors = [
            NSSortDescriptor(key: Self.updatedAtKey, ascending: false)
        ]

        guard let managedTasks = try? context.fetch(request) else {
            return []
        }

        return managedTasks.compactMap(Self.task(from:))
    }

    func searchTasks(matching query: String, limit: Int) -> [UserQueryNotchTask] {
        guard let context else {
            return []
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return loadRecentTasks(limit: limit)
        }

        let matchingEventTaskIDs = taskIDsWithMatchingEvents(trimmedQuery)
        let matchingAssetTaskIDs = taskIDsWithMatchingAssets(trimmedQuery)
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.taskEntityName)
        request.fetchLimit = limit
        var predicates = [
            NSPredicate(format: "%K CONTAINS[cd] %@", Self.titleKey, trimmedQuery),
            NSPredicate(format: "%K CONTAINS[cd] %@", Self.detailKey, trimmedQuery),
            NSPredicate(format: "%K CONTAINS[cd] %@", Self.commandTextKey, trimmedQuery)
        ]
        if !matchingEventTaskIDs.isEmpty {
            predicates.append(NSPredicate(format: "%K IN %@", Self.idKey, matchingEventTaskIDs))
        }
        if !matchingAssetTaskIDs.isEmpty {
            predicates.append(NSPredicate(format: "%K IN %@", Self.idKey, matchingAssetTaskIDs))
        }
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: Self.updatedAtKey, ascending: false)
        ]

        guard let managedTasks = try? context.fetch(request) else {
            return []
        }

        return managedTasks.compactMap(Self.task(from:))
    }

    func upsertTask(_ task: UserQueryNotchTask) {
        guard let context else { return }

        let managedTask = Self.existingTask(id: task.id, in: context)
            ?? NSManagedObject(entity: Self.entityDescription(in: context), insertInto: context)

        managedTask.setValue(task.id, forKey: Self.idKey)
        managedTask.setValue(task.title, forKey: Self.titleKey)
        managedTask.setValue(task.detail, forKey: Self.detailKey)
        managedTask.setValue(task.commandText, forKey: Self.commandTextKey)
        managedTask.setValue(task.status.rawValue, forKey: Self.statusKey)
        managedTask.setValue(Int64(task.accentIndex), forKey: Self.accentIndexKey)
        managedTask.setValue(task.createdAt, forKey: Self.createdAtKey)
        managedTask.setValue(task.updatedAt, forKey: Self.updatedAtKey)
        managedTask.setValue(Self.metadataJSONString(task.metadata), forKey: Self.metadataJSONKey)

        try? context.save()
    }

    /// Permanently removes a task and everything attached to it — its row plus all
    /// stored events and assets — so a dismissed task does not reappear on relaunch.
    func deleteTask(id: String) {
        guard let context else { return }

        if let managedTask = Self.existingTask(id: id, in: context) {
            context.delete(managedTask)
        }
        Self.deleteRows(entityName: Self.eventEntityName, taskIDKey: Self.eventTaskIDKey, taskID: id, in: context)
        Self.deleteRows(entityName: Self.assetEntityName, taskIDKey: Self.assetTaskIDKey, taskID: id, in: context)

        try? context.save()
    }

    func loadAssets(taskID: String) -> [UserQueryTaskAsset] {
        guard let context else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.assetEntityName)
        request.predicate = NSPredicate(format: "%K == %@", Self.assetTaskIDKey, taskID)
        request.sortDescriptors = [
            NSSortDescriptor(key: Self.assetCreatedAtKey, ascending: true)
        ]

        guard let managedAssets = try? context.fetch(request) else {
            return []
        }

        return managedAssets.compactMap(Self.asset(from:))
    }

    func appendAsset(_ asset: UserQueryTaskAsset) {
        guard let context else { return }

        let managedAsset = NSManagedObject(
            entity: Self.assetEntityDescription(in: context),
            insertInto: context
        )
        managedAsset.setValue(asset.id, forKey: Self.assetIDKey)
        managedAsset.setValue(asset.taskID, forKey: Self.assetTaskIDKey)
        managedAsset.setValue(asset.eventID, forKey: Self.assetEventIDKey)
        managedAsset.setValue(asset.source.rawValue, forKey: Self.assetSourceKey)
        managedAsset.setValue(asset.displayName, forKey: Self.assetDisplayNameKey)
        managedAsset.setValue(asset.contentType, forKey: Self.assetContentTypeKey)
        managedAsset.setValue(asset.urlString, forKey: Self.assetURLStringKey)
        managedAsset.setValue(asset.byteCount.map(NSNumber.init(value:)), forKey: Self.assetByteCountKey)
        managedAsset.setValue(asset.createdAt, forKey: Self.assetCreatedAtKey)

        try? context.save()
    }

    func loadEvents(taskID: String) -> [UserQueryTaskEvent] {
        guard let context else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.eventEntityName)
        request.predicate = NSPredicate(format: "%K == %@", Self.eventTaskIDKey, taskID)
        request.sortDescriptors = [
            NSSortDescriptor(key: Self.eventSequenceKey, ascending: true),
            NSSortDescriptor(key: Self.eventCreatedAtKey, ascending: true)
        ]

        guard let managedEvents = try? context.fetch(request) else {
            return []
        }

        return managedEvents.compactMap(Self.event(from:))
    }

    func appendEvent(_ event: UserQueryTaskEvent) {
        guard let context else { return }

        let managedEvent = NSManagedObject(
            entity: Self.eventEntityDescription(in: context),
            insertInto: context
        )
        managedEvent.setValue(event.id, forKey: Self.eventIDKey)
        managedEvent.setValue(event.taskID, forKey: Self.eventTaskIDKey)
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
            .appendingPathComponent("UserQueryTasks.sqlite")
    }

    private static func model() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let taskEntity = NSEntityDescription()
        taskEntity.name = taskEntityName
        taskEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        taskEntity.properties = [
            attribute(idKey, type: .stringAttributeType, isOptional: false),
            attribute(titleKey, type: .stringAttributeType, isOptional: false),
            attribute(detailKey, type: .stringAttributeType, isOptional: false),
            attribute(commandTextKey, type: .stringAttributeType, isOptional: true),
            attribute(statusKey, type: .stringAttributeType, isOptional: false),
            attribute(accentIndexKey, type: .integer64AttributeType, isOptional: false),
            attribute(createdAtKey, type: .dateAttributeType, isOptional: false),
            attribute(updatedAtKey, type: .dateAttributeType, isOptional: false),
            attribute(metadataJSONKey, type: .stringAttributeType, isOptional: true)
        ]
        taskEntity.uniquenessConstraints = [[idKey]]

        let eventEntity = NSEntityDescription()
        eventEntity.name = eventEntityName
        eventEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        eventEntity.properties = [
            attribute(eventIDKey, type: .stringAttributeType, isOptional: false),
            attribute(eventTaskIDKey, type: .stringAttributeType, isOptional: false),
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
            attribute(assetTaskIDKey, type: .stringAttributeType, isOptional: false),
            attribute(assetEventIDKey, type: .stringAttributeType, isOptional: true),
            attribute(assetSourceKey, type: .stringAttributeType, isOptional: false),
            attribute(assetDisplayNameKey, type: .stringAttributeType, isOptional: false),
            attribute(assetContentTypeKey, type: .stringAttributeType, isOptional: false),
            attribute(assetURLStringKey, type: .stringAttributeType, isOptional: false),
            attribute(assetByteCountKey, type: .integer64AttributeType, isOptional: true),
            attribute(assetCreatedAtKey, type: .dateAttributeType, isOptional: false)
        ]
        assetEntity.uniquenessConstraints = [[assetIDKey]]

        model.entities = [taskEntity, eventEntity, assetEntity]
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
        NSEntityDescription.entity(forEntityName: taskEntityName, in: context)!
    }

    private static func eventEntityDescription(in context: NSManagedObjectContext) -> NSEntityDescription {
        NSEntityDescription.entity(forEntityName: eventEntityName, in: context)!
    }

    private static func assetEntityDescription(in context: NSManagedObjectContext) -> NSEntityDescription {
        NSEntityDescription.entity(forEntityName: assetEntityName, in: context)!
    }

    private static func deleteRows(
        entityName: String,
        taskIDKey: String,
        taskID: String,
        in context: NSManagedObjectContext
    ) {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "%K == %@", taskIDKey, taskID)
        guard let rows = try? context.fetch(request) else { return }
        for row in rows {
            context.delete(row)
        }
    }

    private static func existingTask(id: String, in context: NSManagedObjectContext) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: taskEntityName)
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "%K == %@", idKey, id)
        return try? context.fetch(request).first
    }

    private func taskIDsWithMatchingEvents(_ query: String) -> [String] {
        guard let context else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.eventEntityName)
        request.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", Self.eventTextKey, query)

        guard let managedEvents = try? context.fetch(request) else {
            return []
        }

        return Array(Set(managedEvents.compactMap { $0.value(forKey: Self.eventTaskIDKey) as? String }))
    }

    private func taskIDsWithMatchingAssets(_ query: String) -> [String] {
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

        return Array(Set(managedAssets.compactMap { $0.value(forKey: Self.assetTaskIDKey) as? String }))
    }

    private static func task(from managedTask: NSManagedObject) -> UserQueryNotchTask? {
        guard let id = managedTask.value(forKey: idKey) as? String,
              let title = managedTask.value(forKey: titleKey) as? String,
              let detail = managedTask.value(forKey: detailKey) as? String,
              let rawStatus = managedTask.value(forKey: statusKey) as? String,
              let status = UserQueryTaskStatus(rawValue: rawStatus),
              let createdAt = managedTask.value(forKey: createdAtKey) as? Date,
              let updatedAt = managedTask.value(forKey: updatedAtKey) as? Date else {
            return nil
        }

        let accentIndex = (managedTask.value(forKey: accentIndexKey) as? NSNumber)?.intValue ?? 0
        return UserQueryNotchTask(
            id: id,
            title: title,
            detail: detail,
            commandText: managedTask.value(forKey: commandTextKey) as? String ?? title,
            status: status,
            accentIndex: accentIndex,
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: metadata(fromJSONString: managedTask.value(forKey: metadataJSONKey) as? String)
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

    private static func event(from managedEvent: NSManagedObject) -> UserQueryTaskEvent? {
        guard let id = managedEvent.value(forKey: eventIDKey) as? String,
              let taskID = managedEvent.value(forKey: eventTaskIDKey) as? String,
              let rawRole = managedEvent.value(forKey: eventRoleKey) as? String,
              let role = UserQueryTaskEventRole(rawValue: rawRole),
              let text = managedEvent.value(forKey: eventTextKey) as? String,
              let createdAt = managedEvent.value(forKey: eventCreatedAtKey) as? Date else {
            return nil
        }

        let sequence = (managedEvent.value(forKey: eventSequenceKey) as? NSNumber)?.intValue ?? 0
        return UserQueryTaskEvent(
            id: id,
            taskID: taskID,
            role: role,
            text: text,
            sequence: sequence,
            createdAt: createdAt
        )
    }

    private static func asset(from managedAsset: NSManagedObject) -> UserQueryTaskAsset? {
        guard let id = managedAsset.value(forKey: assetIDKey) as? String,
              let taskID = managedAsset.value(forKey: assetTaskIDKey) as? String,
              let rawSource = managedAsset.value(forKey: assetSourceKey) as? String,
              let source = UserQueryTaskAssetSource(rawValue: rawSource),
              let displayName = managedAsset.value(forKey: assetDisplayNameKey) as? String,
              let contentType = managedAsset.value(forKey: assetContentTypeKey) as? String,
              let urlString = managedAsset.value(forKey: assetURLStringKey) as? String,
              let createdAt = managedAsset.value(forKey: assetCreatedAtKey) as? Date else {
            return nil
        }

        return UserQueryTaskAsset(
            id: id,
            taskID: taskID,
            eventID: managedAsset.value(forKey: assetEventIDKey) as? String,
            source: source,
            displayName: displayName,
            contentType: contentType,
            urlString: urlString,
            byteCount: (managedAsset.value(forKey: assetByteCountKey) as? NSNumber)?.int64Value,
            createdAt: createdAt
        )
    }

    private static let taskEntityName = "UserQueryStoredTask"
    private static let eventEntityName = "UserQueryStoredTaskEvent"
    private static let assetEntityName = "UserQueryStoredTaskAsset"
    private static let idKey = "id"
    private static let titleKey = "title"
    private static let detailKey = "detail"
    private static let commandTextKey = "commandText"
    private static let statusKey = "status"
    private static let accentIndexKey = "accentIndex"
    private static let createdAtKey = "createdAt"
    private static let updatedAtKey = "updatedAt"
    private static let metadataJSONKey = "metadataJSON"
    private static let eventIDKey = "id"
    private static let eventTaskIDKey = "taskID"
    private static let eventRoleKey = "role"
    private static let eventTextKey = "text"
    private static let eventSequenceKey = "sequence"
    private static let eventCreatedAtKey = "createdAt"
    private static let assetIDKey = "id"
    private static let assetTaskIDKey = "taskID"
    private static let assetEventIDKey = "eventID"
    private static let assetSourceKey = "source"
    private static let assetDisplayNameKey = "displayName"
    private static let assetContentTypeKey = "contentType"
    private static let assetURLStringKey = "urlString"
    private static let assetByteCountKey = "byteCount"
    private static let assetCreatedAtKey = "createdAt"
}
