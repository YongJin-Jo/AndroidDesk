import Foundation
import MTPBridge

protocol MTPServicing: Sendable {
    func deviceInfo() async throws -> MTPDeviceInfo
    func disconnect() async
    func invalidateIndex() async
    func refreshIndex() async throws -> [RemoteFile]
    func list(path: String) async throws -> [RemoteFile]
    func listChildren(storageID: UInt32, folderID: UInt32) async throws -> [RemoteFile]
    func upload(
        localURL: URL,
        remoteDirectory: String,
        storageID: UInt32?,
        folderID: UInt32?,
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
    private var connection: OpaquePointer?

    func deviceInfo() async throws -> MTPDeviceInfo {
        disconnectConnection()
        var displayName: UnsafeMutablePointer<CChar>?
        var serialNumber: UnsafeMutablePointer<CChar>?
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            ad_mtp_free_string(displayName)
            ad_mtp_free_string(serialNumber)
            ad_mtp_free_string(errorMessage)
        }

        guard let openedConnection = ad_mtp_connect(
            &displayName,
            &serialNumber,
            &errorMessage
        ) else {
            throw MTPError(message(from: errorMessage))
        }
        guard let displayName else {
            ad_mtp_disconnect(openedConnection)
            throw MTPError(message(from: errorMessage))
        }
        connection = openedConnection
        return MTPDeviceInfo(
            displayName: String(cString: displayName),
            serialNumber: serialNumber.map { String(cString: $0) } ?? ""
        )
    }

    func disconnect() async {
        disconnectConnection()
    }

    func invalidateIndex() async {
        guard let connection else { return }
        ad_mtp_invalidate_index(connection)
    }

    func refreshIndex() async throws -> [RemoteFile] {
        let connection = try activeConnection()
        var items: UnsafeMutablePointer<ADMTPItem>?
        var count = 0
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = ad_mtp_refresh_index(
            connection,
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

    func list(path: String) async throws -> [RemoteFile] {
        let connection = try activeConnection()
        var items: UnsafeMutablePointer<ADMTPItem>?
        var count = 0
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = path.withCString {
            ad_mtp_list(connection, $0, &items, &count, &errorMessage)
        }
        return try makeRemoteFiles(
            result: result,
            items: items,
            count: count,
            errorMessage: errorMessage
        )
    }

    func listChildren(storageID: UInt32, folderID: UInt32) async throws -> [RemoteFile] {
        let connection = try activeConnection()
        var items: UnsafeMutablePointer<ADMTPItem>?
        var count = 0
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = ad_mtp_list_children(
            connection,
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
        storageID: UInt32?,
        folderID: UInt32?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let connection = try activeConnection()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let reporter = MTPProgressReporter(report: progress)
        let progressContext = Unmanaged.passUnretained(reporter).toOpaque()
        let result = localURL.path.withCString { localPath in
            if let storageID, let folderID {
                return ad_mtp_upload_to_folder(
                    connection,
                    localPath,
                    storageID,
                    folderID,
                    mtpProgressCallback,
                    progressContext,
                    &errorMessage
                )
            }
            return remoteDirectory.withCString { remotePath in
                ad_mtp_upload(
                    connection,
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
        let connection = try activeConnection()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let reporter = MTPProgressReporter(report: progress)
        let progressContext = Unmanaged.passUnretained(reporter).toOpaque()
        let result = destination.path.withCString {
            ad_mtp_download(
                connection,
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

    private func activeConnection() throws -> OpaquePointer {
        guard let connection else {
            throw MTPError("MTP 연결이 열려 있지 않습니다. 기기를 다시 연결해 주세요.")
        }
        return connection
    }

    private func disconnectConnection() {
        guard let connection else { return }
        ad_mtp_disconnect(connection)
        self.connection = nil
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
