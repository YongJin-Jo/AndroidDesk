import Foundation
import MTPBridge

protocol MTPServicing: Sendable {
    func deviceInfo() async throws -> MTPDeviceInfo
    func list(path: String) async throws -> [RemoteFile]
    func listChildren(storageID: UInt32, folderID: UInt32) async throws -> [RemoteFile]
    func upload(
        localURL: URL,
        remoteDirectory: String,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws
    func download(
        file: RemoteFile,
        destination: URL,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws
}

private final class MTPProgressReporter: @unchecked Sendable {
    private let report: @Sendable (TransferProgress) -> Void
    private let lock = NSLock()
    private var lastReportAt = Date.distantPast
    private var lastTransferredBytes: UInt64 = 0

    init(report: @escaping @Sendable (TransferProgress) -> Void) {
        self.report = report
    }

    func receive(bytesTransferred: UInt64, totalBytes: UInt64) {
        let now = Date()
        lock.lock()
        let isNewFile = bytesTransferred < lastTransferredBytes
        let shouldReport = isNewFile
            || bytesTransferred == totalBytes
            || now.timeIntervalSince(lastReportAt) >= 0.1
        if shouldReport {
            lastReportAt = now
        }
        lastTransferredBytes = bytesTransferred
        lock.unlock()

        guard shouldReport else { return }
        report(TransferProgress(bytesTransferred: bytesTransferred, totalBytes: totalBytes))
    }
}

private let mtpProgressCallback: ADMTPProgressCallback = { bytesTransferred, totalBytes, context in
    guard let context else { return 0 }
    let reporter = Unmanaged<MTPProgressReporter>.fromOpaque(context).takeUnretainedValue()
    reporter.receive(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
    return 0
}

actor MTPService: MTPServicing {
    func deviceInfo() async throws -> MTPDeviceInfo {
        var displayName: UnsafeMutablePointer<CChar>?
        var serialNumber: UnsafeMutablePointer<CChar>?
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            ad_mtp_free_string(displayName)
            ad_mtp_free_string(serialNumber)
            ad_mtp_free_string(errorMessage)
        }

        guard ad_mtp_device_info(&displayName, &serialNumber, &errorMessage) == 0,
              let displayName else {
            throw MTPError(message(from: errorMessage))
        }
        return MTPDeviceInfo(
            displayName: String(cString: displayName),
            serialNumber: serialNumber.map { String(cString: $0) } ?? ""
        )
    }

    func list(path: String) async throws -> [RemoteFile] {
        var items: UnsafeMutablePointer<ADMTPItem>?
        var count = 0
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = path.withCString {
            ad_mtp_list($0, &items, &count, &errorMessage)
        }
        return try makeRemoteFiles(
            result: result,
            items: items,
            count: count,
            errorMessage: errorMessage
        )
    }

    func listChildren(storageID: UInt32, folderID: UInt32) async throws -> [RemoteFile] {
        var items: UnsafeMutablePointer<ADMTPItem>?
        var count = 0
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = ad_mtp_list_children(
            storageID,
            folderID,
            &items,
            &count,
            &errorMessage
        )
        return try makeRemoteFiles(
            result: result,
            items: items,
            count: count,
            errorMessage: errorMessage
        )
    }

    func upload(
        localURL: URL,
        remoteDirectory: String,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let reporter = MTPProgressReporter(report: progress)
        let progressContext = Unmanaged.passUnretained(reporter).toOpaque()
        let result = localURL.path.withCString { localPath in
            remoteDirectory.withCString { remotePath in
                ad_mtp_upload(
                    localPath,
                    remotePath,
                    mtpProgressCallback,
                    progressContext,
                    &errorMessage
                )
            }
        }
        defer { ad_mtp_free_string(errorMessage) }
        guard result == 0 else { throw MTPError(message(from: errorMessage)) }
    }

    func download(
        file: RemoteFile,
        destination: URL,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let reporter = MTPProgressReporter(report: progress)
        let progressContext = Unmanaged.passUnretained(reporter).toOpaque()
        let result = destination.path.withCString {
            ad_mtp_download(
                file.objectID,
                file.storageID,
                file.isDirectory ? 1 : 0,
                $0,
                mtpProgressCallback,
                progressContext,
                &errorMessage
            )
        }
        defer { ad_mtp_free_string(errorMessage) }
        guard result == 0 else { throw MTPError(message(from: errorMessage)) }
    }

    private func message(from pointer: UnsafeMutablePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? "MTP 작업에 실패했습니다."
    }

    private func makeRemoteFiles(
        result: Int32,
        items: UnsafeMutablePointer<ADMTPItem>?,
        count: Int,
        errorMessage: UnsafeMutablePointer<CChar>?
    ) throws -> [RemoteFile] {
        defer {
            ad_mtp_free_items(items, count)
            ad_mtp_free_string(errorMessage)
        }
        guard result == 0 else { throw MTPError(message(from: errorMessage)) }
        guard let items else { return [] }

        return (0..<count).map { index in
            let item = items[index]
            return RemoteFile(
                objectID: item.object_id,
                storageID: item.storage_id,
                name: item.name.map { String(cString: $0) } ?? "이름 없음",
                isDirectory: item.is_directory != 0,
                size: item.size
            )
        }
    }
}
