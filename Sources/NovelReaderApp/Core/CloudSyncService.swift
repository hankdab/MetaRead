import CloudKit
import Foundation

struct CloudSyncPayload: Codable {
    var books: [CloudBookMetadata]
    var readerTheme: ReaderTheme
    var updatedAt: Date
}

struct CloudBookMetadata: Codable {
    var id: UUID
    var title: String
    var author: String
    var sourceName: String
    var format: BookFormat
    var status: ReadingStatus
    var progress: ReadingProgress
    var updatedAt: Date
}

enum CloudSyncError: LocalizedError {
    case unavailable
    case missingContainer
    case missingData

    var errorDescription: String? {
        switch self {
        case .unavailable: "当前安装包未启用 iCloud，同步功能已关闭"
        case .missingContainer: "CloudKit 容器不可用"
        case .missingData: "CloudKit 记录没有有效数据"
        }
    }
}

@MainActor
final class CloudSyncService {
    private let container: CKContainer
    private let database: CKDatabase
    private let recordID = CKRecord.ID(recordName: "library-state")

    static func makeIfAvailable(containerIdentifier: String? = nil) -> CloudSyncService? {
        guard isEnabledInBundle else { return nil }
        return CloudSyncService(containerIdentifier: containerIdentifier)
    }

    init(containerIdentifier: String? = nil) {
        if let containerIdentifier {
            container = CKContainer(identifier: containerIdentifier)
        } else {
            container = CKContainer.default()
        }
        database = container.privateCloudDatabase
    }

    func push(payload: CloudSyncPayload) async throws {
        let data = try JSONEncoder.appEncoder.encode(payload)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch {
            record = CKRecord(recordType: "LibraryState", recordID: recordID)
        }
        record["payload"] = data as CKRecordValue
        record["updatedAt"] = payload.updatedAt as CKRecordValue
        _ = try await database.save(record)
    }

    func pull() async throws -> CloudSyncPayload {
        let record = try await database.record(for: recordID)
        guard let data = record["payload"] as? Data else {
            throw CloudSyncError.missingData
        }
        return try JSONDecoder.appDecoder.decode(CloudSyncPayload.self, from: data)
    }

    private static var isEnabledInBundle: Bool {
        Bundle.main.object(forInfoDictionaryKey: "YuanYueCloudSyncEnabled") as? Bool == true
    }
}
