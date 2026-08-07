import Foundation

enum TransferDirection: String, Sendable {
    case upload = "Android로 업로드"
    case download = "Mac으로 다운로드"
}

enum TransferJobState: String, Sendable {
    case waiting = "대기 중"
    case transferring = "전송 중"
    case completed = "완료"
    case failed = "실패"
    case cancelled = "취소됨"
}

struct TransferJob: Identifiable, Sendable {
    let id: UUID
    let name: String
    let direction: TransferDirection
    var state: TransferJobState
    var bytesTransferred: UInt64
    var totalBytes: UInt64
    var bytesPerSecond: UInt64
    var errorMessage: String?

    var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(Double(bytesTransferred) / Double(totalBytes), 1)
    }

    var canCancel: Bool {
        state == .waiting || state == .transferring
    }

    var canRetry: Bool {
        state == .failed || state == .cancelled
    }
}

final class TransferCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
