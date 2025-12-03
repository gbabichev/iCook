import Foundation
import CloudKit

// MARK: - Source (Top-level container for recipes)
struct Source: Identifiable {
    var id: CKRecord.ID
    var name: String
    var isPersonal: Bool // true = private DB, false = shared DB
    var owner: String // iCloud user identifier
    var lastModified: Date
    
    init(id: CKRecord.ID, name: String, isPersonal: Bool, owner: String, lastModified: Date) {
        self.id = id
        self.name = name
        self.isPersonal = isPersonal
        self.owner = owner
        self.lastModified = lastModified
    }
    
    /// Convert to CloudKit CKRecord
    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: "Source", recordID: id)
        record["name"] = name
        record["isPersonal"] = isPersonal
        record["owner"] = owner
        record["lastModified"] = lastModified
        return record
    }
    
    /// Create from CloudKit CKRecord
    static func from(_ record: CKRecord) -> Source? {
        guard let name = record["name"] as? String,
              let isPersonal = record["isPersonal"] as? Bool,
              let owner = record["owner"] as? String,
              let lastModified = record["lastModified"] as? Date else {
            return nil
        }
        
        return Source(id: record.recordID, name: name, isPersonal: isPersonal, owner: owner, lastModified: lastModified)
    }
    
    // MARK: - Manual Codable Implementation
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isPersonal
        case owner
        case lastModified
        case zoneName
        case zoneOwnerName
    }
}

extension Source: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.recordName, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isPersonal, forKey: .isPersonal)
        try container.encode(owner, forKey: .owner)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(id.zoneID.zoneName, forKey: .zoneName)
        try container.encode(id.zoneID.ownerName, forKey: .zoneOwnerName)
    }
}

extension Source: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recordName = try container.decode(String.self, forKey: .id)
        if let zoneName = try container.decodeIfPresent(String.self, forKey: .zoneName) {
            let ownerName = try container.decodeIfPresent(String.self, forKey: .zoneOwnerName) ?? CKCurrentUserDefaultName
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
            self.id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        } else {
            self.id = CKRecord.ID(recordName: recordName)
        }
        self.name = try container.decode(String.self, forKey: .name)
        self.isPersonal = try container.decode(Bool.self, forKey: .isPersonal)
        self.owner = try container.decode(String.self, forKey: .owner)
        self.lastModified = try container.decode(Date.self, forKey: .lastModified)
    }
}

// MARK: - Category (Belongs to a Source)
struct Category: Identifiable, Hashable {
    var id: CKRecord.ID
    var sourceID: CKRecord.ID // Reference to Source
    var name: String
    var icon: String
    var lastModified: Date
    
    init(id: CKRecord.ID, sourceID: CKRecord.ID, name: String, icon: String, lastModified: Date = Date()) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.icon = icon
        self.lastModified = lastModified
    }
    
    /// Convert to CloudKit CKRecord
    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: "Category", recordID: id)
        record["name"] = name
        record["icon"] = icon
        record["sourceID"] = CKRecord.Reference(recordID: sourceID, action: .deleteSelf)
        record["lastModified"] = lastModified
        return record
    }
    
    /// Create from CloudKit CKRecord
    static func from(_ record: CKRecord) -> Category? {
        guard let name = record["name"] as? String,
              let icon = record["icon"] as? String,
              let sourceRef = record["sourceID"] as? CKRecord.Reference else {
            return nil
        }
        
        let lastModified = (record["lastModified"] as? Date) ?? Date()
        return Category(id: record.recordID, sourceID: sourceRef.recordID, name: name, icon: icon, lastModified: lastModified)
    }
    
    // MARK: - Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: Category, rhs: Category) -> Bool {
        lhs.id == rhs.id
    }
}

extension Category: Codable {
    enum CodingKeys: String, CodingKey {
        case recordName
        case zoneName
        case zoneOwnerName
        case sourceRecordName
        case sourceZoneName
        case sourceZoneOwnerName
        case name
        case icon
        case lastModified
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.recordName, forKey: .recordName)
        try container.encode(id.zoneID.zoneName, forKey: .zoneName)
        try container.encode(id.zoneID.ownerName, forKey: .zoneOwnerName)
        try container.encode(sourceID.recordName, forKey: .sourceRecordName)
        try container.encode(sourceID.zoneID.zoneName, forKey: .sourceZoneName)
        try container.encode(sourceID.zoneID.ownerName, forKey: .sourceZoneOwnerName)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(lastModified, forKey: .lastModified)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let recordName = try container.decode(String.self, forKey: .recordName)
        let zoneName = try container.decode(String.self, forKey: .zoneName)
        let zoneOwner = try container.decode(String.self, forKey: .zoneOwnerName)
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwner)
        self.id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        
        let sourceRecordName = try container.decode(String.self, forKey: .sourceRecordName)
        let sourceZoneName = try container.decode(String.self, forKey: .sourceZoneName)
        let sourceZoneOwner = try container.decode(String.self, forKey: .sourceZoneOwnerName)
        let sourceZoneID = CKRecordZone.ID(zoneName: sourceZoneName, ownerName: sourceZoneOwner)
        self.sourceID = CKRecord.ID(recordName: sourceRecordName, zoneID: sourceZoneID)
        
        self.name = try container.decode(String.self, forKey: .name)
        self.icon = try container.decode(String.self, forKey: .icon)
        self.lastModified = try container.decode(Date.self, forKey: .lastModified)
    }
}

// MARK: - Recipe Step
struct RecipeStep: Codable, Hashable {
    var stepNumber: Int
    var instruction: String
    var ingredients: [String]
    
    enum CodingKeys: String, CodingKey {
        case stepNumber = "step_number"
        case instruction
        case ingredients
    }
}

// MARK: - Recipe (Belongs to a Source and Category)
struct Recipe: Identifiable, Hashable {
    var id: CKRecord.ID
    var sourceID: CKRecord.ID // Reference to Source
    var categoryID: CKRecord.ID // Reference to Category
    var name: String
    var recipeTime: Int // in minutes
    var details: String?
    var imageAsset: CKAsset? // CloudKit asset instead of URL
    var cachedImagePath: String?
    var recipeSteps: [RecipeStep]
    var lastModified: Date
    
    init(
        id: CKRecord.ID,
        sourceID: CKRecord.ID,
        categoryID: CKRecord.ID,
        name: String,
        recipeTime: Int,
        details: String? = nil,
        imageAsset: CKAsset? = nil,
        cachedImagePath: String? = nil,
        recipeSteps: [RecipeStep] = [],
        lastModified: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.categoryID = categoryID
        self.name = name
        self.recipeTime = recipeTime
        self.details = details
        self.imageAsset = imageAsset
        self.cachedImagePath = cachedImagePath
        self.recipeSteps = recipeSteps
        self.lastModified = lastModified
    }
    
    /// Computed property for backward compatibility with legacy code
    var ingredients: [String]? {
        let allIngredients = recipeSteps.flatMap { $0.ingredients }
        return allIngredients.isEmpty ? nil : Array(Set(allIngredients)).sorted()
    }
    
    /// Convert to CloudKit CKRecord
    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: "Recipe", recordID: id)
        record["name"] = name
        record["recipeTime"] = recipeTime
        record["details"] = details
        record["sourceID"] = CKRecord.Reference(recordID: sourceID, action: .deleteSelf)
        record["categoryID"] = CKRecord.Reference(recordID: categoryID, action: .none)
        record["lastModified"] = lastModified
        
        // Store image asset
        if let imageAsset = imageAsset {
            record["imageAsset"] = imageAsset
        }
        
        // Store recipe steps as JSON
        do {
            let stepsData = try JSONEncoder().encode(recipeSteps)
            record["recipeSteps"] = String(data: stepsData, encoding: .utf8) ?? "[]"
        } catch {
            record["recipeSteps"] = "[]"
        }
        
        return record
    }
    
    /// Create from CloudKit CKRecord
    static func from(_ record: CKRecord) -> Recipe? {
        guard let name = record["name"] as? String,
              let recipeTime = record["recipeTime"] as? Int,
              let sourceRef = record["sourceID"] as? CKRecord.Reference,
              let categoryRef = record["categoryID"] as? CKRecord.Reference else {
            return nil
        }
        
        let details = record["details"] as? String
        let imageAsset = record["imageAsset"] as? CKAsset
        let lastModified = (record["lastModified"] as? Date) ?? Date()
        
        var recipeSteps: [RecipeStep] = []
        if let stepsJSON = record["recipeSteps"] as? String,
           let stepsData = stepsJSON.data(using: .utf8) {
            do {
                recipeSteps = try JSONDecoder().decode([RecipeStep].self, from: stepsData)
            } catch {
                printD("Failed to decode recipe steps: \(error)")
            }
        }
        
        return Recipe(
            id: record.recordID,
            sourceID: sourceRef.recordID,
            categoryID: categoryRef.recordID,
            name: name,
            recipeTime: recipeTime,
            details: details,
            imageAsset: imageAsset,
            recipeSteps: recipeSteps,
            lastModified: lastModified
        )
    }
    
    // MARK: - Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: Recipe, rhs: Recipe) -> Bool {
        lhs.id == rhs.id
    }
}

extension Recipe: Codable {
    enum CodingKeys: String, CodingKey {
        case recordName
        case zoneName
        case zoneOwnerName
        case sourceRecordName
        case sourceZoneName
        case sourceZoneOwnerName
        case categoryRecordName
        case categoryZoneName
        case categoryZoneOwnerName
        case name
        case recipeTime
        case details
        case cachedImagePath
        case recipeSteps
        case lastModified
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.recordName, forKey: .recordName)
        try container.encode(id.zoneID.zoneName, forKey: .zoneName)
        try container.encode(id.zoneID.ownerName, forKey: .zoneOwnerName)
        try container.encode(sourceID.recordName, forKey: .sourceRecordName)
        try container.encode(sourceID.zoneID.zoneName, forKey: .sourceZoneName)
        try container.encode(sourceID.zoneID.ownerName, forKey: .sourceZoneOwnerName)
        try container.encode(categoryID.recordName, forKey: .categoryRecordName)
        try container.encode(categoryID.zoneID.zoneName, forKey: .categoryZoneName)
        try container.encode(categoryID.zoneID.ownerName, forKey: .categoryZoneOwnerName)
        try container.encode(name, forKey: .name)
        try container.encode(recipeTime, forKey: .recipeTime)
        try container.encode(details, forKey: .details)
        try container.encodeIfPresent(cachedImagePath, forKey: .cachedImagePath)
        try container.encode(recipeSteps, forKey: .recipeSteps)
        try container.encode(lastModified, forKey: .lastModified)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let recordName = try container.decode(String.self, forKey: .recordName)
        let zoneName = try container.decode(String.self, forKey: .zoneName)
        let zoneOwner = try container.decode(String.self, forKey: .zoneOwnerName)
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwner)
        self.id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        
        let sourceRecordName = try container.decode(String.self, forKey: .sourceRecordName)
        let sourceZoneName = try container.decode(String.self, forKey: .sourceZoneName)
        let sourceZoneOwner = try container.decode(String.self, forKey: .sourceZoneOwnerName)
        let sourceZoneID = CKRecordZone.ID(zoneName: sourceZoneName, ownerName: sourceZoneOwner)
        self.sourceID = CKRecord.ID(recordName: sourceRecordName, zoneID: sourceZoneID)
        
        let categoryRecordName = try container.decode(String.self, forKey: .categoryRecordName)
        let categoryZoneName = try container.decode(String.self, forKey: .categoryZoneName)
        let categoryZoneOwner = try container.decode(String.self, forKey: .categoryZoneOwnerName)
        let categoryZoneID = CKRecordZone.ID(zoneName: categoryZoneName, ownerName: categoryZoneOwner)
        self.categoryID = CKRecord.ID(recordName: categoryRecordName, zoneID: categoryZoneID)
        
        self.name = try container.decode(String.self, forKey: .name)
        self.recipeTime = try container.decode(Int.self, forKey: .recipeTime)
        self.details = try container.decodeIfPresent(String.self, forKey: .details)
        self.cachedImagePath = try container.decodeIfPresent(String.self, forKey: .cachedImagePath)
        self.recipeSteps = try container.decode([RecipeStep].self, forKey: .recipeSteps)
        self.lastModified = try container.decode(Date.self, forKey: .lastModified)
        self.imageAsset = nil
    }
}
