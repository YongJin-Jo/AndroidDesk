import Foundation

struct LocalFile: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let size: UInt64
    let addedDate: Date?
    let kind: String

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var sortableAddedDate: Date { addedDate ?? .distantPast }
}

struct RemoteFile: Identifiable, Hashable, Sendable {
    let objectID: UInt32
    let storageID: UInt32
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let addedDate: Date?
    let kind: String

    var id: String { "\(storageID):\(objectID)" }
    var sortableAddedDate: Date { addedDate ?? .distantPast }
}

struct MTPDeviceInfo: Sendable {
    let displayName: String
    let serialNumber: String
}

struct TransferProgress: Sendable {
    let bytesTransferred: UInt64
    let totalBytes: UInt64
}

struct MTPError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var errorDescription: String? {
        message.isEmpty ? "MTP 작업에 실패했습니다." : message
    }
}
