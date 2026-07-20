import Foundation

enum FileSortOption: String, CaseIterable, Identifiable {
    case name = "이름"
    case kind = "종류"
    case size = "크기"

    var id: Self { self }
}

struct LocalFile: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let size: UInt64

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct RemoteFile: Identifiable, Hashable, Sendable {
    let objectID: UInt32
    let storageID: UInt32
    let name: String
    let isDirectory: Bool
    let size: UInt64

    var id: String { "\(storageID):\(objectID)" }
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
