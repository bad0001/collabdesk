import Foundation

enum JSONValue: Codable, Equatable {
    case string(String), int(Int), bool(Bool), null, array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .int(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil(); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
    var text: String { switch self { case .string(let v): return v; case .int(let v): return String(v); default: return "" } }
    var any: Any { switch self { case .string(let v): return v; case .int(let v): return v; case .bool(let v): return v; case .null: return NSNull(); case .array(let v): return v.map(\.any); case .object(let v): return v.mapValues(\.any) } }
}
struct LedgerField: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var type: String
    var options: [String]? = nil
    var choices: [String] { options ?? [] }
    static let types = ["text", "select", "rating", "date", "url", "longtext", "member", "status"]
    var typeLabel: String { ["text":"短文本", "longtext":"长文本", "select":"单选", "rating":"星级", "date":"日期", "url":"链接", "member":"成员", "status":"状态"][type] ?? type }
}
struct LedgerFilter: Codable, Equatable { var fieldId: String; var op: String; var value: JSONValue? = nil }
struct LedgerSort: Codable, Equatable { var fieldId: String; var descending: Bool = false }
struct LedgerViewDefinition: Codable, Equatable, Identifiable {
    var id: String; var name: String; var filters: [LedgerFilter]? = []; var sorts: [LedgerSort]? = []
}
struct RecordLibrary: Codable, Equatable, Identifiable {
    var id: Int; var name: String; var fields: [LedgerField]; var views: [LedgerViewDefinition]; var workerAccess: String
    var version: Int; var createdBy: String; var createdAt: String; var updatedAt: String
}
struct LedgerRecord: Codable, Equatable, Identifiable {
    var id: Int; var libraryId: Int; var title: String; var values: [String: JSONValue]; var body: String; var archived: Bool
    var version: Int; var taskIds: [String]; var createdBy: String; var createdAt: String; var updatedAt: String
    func value(_ key: String) -> JSONValue {
        switch key { case "title": return .string(title); case "createdAt": return .string(createdAt); case "updatedAt": return .string(updatedAt); default: return values[key] ?? .null }
    }
    func matches(_ filter: LedgerFilter) -> Bool {
        let a = value(filter.fieldId), b = filter.value ?? .null
        switch filter.op {
        case "equals": return a == b
        case "not_equals": return a != b
        case "contains": return a.text.localizedCaseInsensitiveContains(b.text)
        case "is_empty": return a == .null || a.text.isEmpty
        case "gte", "lte":
            if case .int(let x) = a, case .int(let y) = b { return filter.op == "gte" ? x >= y : x <= y }
            guard a != .null, b != .null else { return false }
            return filter.op == "gte" ? a.text >= b.text : a.text <= b.text
        default: return false
        }
    }
}
struct RecordHistory: Codable, Equatable, Identifiable {
    var id: Int; var libraryId: Int; var recordId: Int?; var kind: String; var actorId: String; var actorName: String
    var before: JSONValue?; var after: JSONValue?; var timestamp: String
}
struct PushStatus: Codable, Equatable {
    var configured: Bool; var registeredDevices: Int; var queued: Int; var acceptedByAPNs: Int; var failed: Int; var deliveryNote: String
    var configProblem: String? = nil
}
struct BackupInfo: Codable, Equatable { var createdAt: String; var filename: String; var sha256: String; var bytes: Int }
struct BackupStatus: Codable, Equatable { var intervalSeconds: Int; var retainedCopies: Int; var location: String; var latest: BackupInfo?; var offsiteConfigured: Bool }
