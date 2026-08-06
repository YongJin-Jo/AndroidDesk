import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

private final class FilePromiseCompletion: @unchecked Sendable {
    private let completion: (Error?) -> Void

    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func callAsFunction(_ error: Error?) {
        completion(error)
    }
}

private final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let fileName: String
    private let writePromise: @Sendable (URL, FilePromiseCompletion) -> Void

    init(
        fileName: String,
        writePromise: @escaping @Sendable (URL, FilePromiseCompletion) -> Void
    ) {
        self.fileName = fileName
        self.writePromise = writePromise
    }

    @MainActor
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        fileName
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        writePromise(url, FilePromiseCompletion(completionHandler))
    }

    @MainActor
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }
}

@MainActor
@Observable
final class AndroidDeviceViewModel {
    private static let localDirectoryBookmarkKey = "localDirectoryBookmark"

    private struct RemoteFolderKey: Hashable {
        let storageID: UInt32
        let folderID: UInt32
    }

    private struct RemoteFolderLocation {
        let path: String
        let storageID: UInt32?
        let folderID: UInt32?
    }

    var deviceDescription = "기기를 확인하는 중…"
    var isConnected = false
    var localDirectory = FileManager.default.homeDirectoryForCurrentUser
    var localFiles: [LocalFile] = []
    var selectedLocalFileIDs: Set<LocalFile.ID> = []
    var localSearchText = ""
    var localSortOption: FileSortOption = .name
    var remoteDirectory = "/"
    var remoteFiles: [RemoteFile] = []
    var selectedRemoteFileIDs: Set<RemoteFile.ID> = []
    var remoteSearchText = ""
    var remoteSortOption: FileSortOption = .name
    var statusMessage = "준비됨"
    var isWorking = false
    var isIndexingRemoteFiles = false
    var transferProgress: Double?
    var transferBytes: UInt64 = 0
    var transferTotalBytes: UInt64 = 0
    var transferRateBytesPerSecond: UInt64 = 0
    var isShowingError = false
    var errorMessage = ""

    private let service: any MTPServicing
    private var remoteFolderStack: [RemoteFolderLocation] = []
    private var remoteStorageID: UInt32?
    private var remoteFolderID: UInt32?
    private var cachedRootFiles: [RemoteFile] = []
    private var cachedFolderFiles: [RemoteFolderKey: [RemoteFile]] = [:]
    private var hasRemoteIndex = false
    private var connectionGeneration = UUID()
    private var indexGeneration = UUID()
    private var transferStartedAt: Date?
    private var currentTransferID: UUID?
    private var isAccessingLocalDirectory = false
    private var activeFilePromises = 0
    private var filePromiseTransferID: UUID?
    private var failedFilePromises = 0

    init(service: any MTPServicing) {
        self.service = service
    }

    func start() {
        if !restoreLocalDirectoryAccess() {
            chooseLocalFolder()
        }
        refreshDevice()
    }

    func stop() {
        connectionGeneration = UUID()
        isConnected = false
        markRemoteIndexStale()
        let service = service
        Task {
            await service.disconnect()
        }
    }

    func loadLocalFiles() {
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: localDirectory,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            localFiles = urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys),
                      let isDirectory = values.isDirectory else { return nil }
                return LocalFile(
                    url: url,
                    isDirectory: isDirectory,
                    size: UInt64(values.fileSize ?? 0)
                )
            }
            selectedLocalFileIDs = Set(filteredLocalFiles.prefix(1).map(\.id))
        } catch {
            showError(error)
        }
    }

    func openLocalFolder(_ file: LocalFile) {
        guard file.isDirectory else { return }
        localDirectory = file.url
        loadLocalFiles()
    }

    func openParentLocalFolder() {
        let parent = localDirectory.deletingLastPathComponent()
        guard parent != localDirectory else { return }
        localDirectory = parent
        loadLocalFiles()
    }

    @discardableResult
    func chooseLocalFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "접근할 Mac 폴더 선택"
        panel.prompt = "접근 허용"
        panel.directoryURL = localDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else {
            statusMessage = "Mac 파일을 보려면 접근할 폴더를 선택하세요."
            return false
        }
        setLocalDirectory(directory, persistAccess: true)
        loadLocalFiles()
        return true
    }

    func refreshDevice() {
        guard !isWorking else { return }
        connectionGeneration = UUID()
        isConnected = false
        isIndexingRemoteFiles = false
        deviceDescription = "MTP 기기를 확인하는 중…"
        resetRemoteNavigation()
        remoteFiles = []
        selectedRemoteFileIDs = []
        let service = service

        perform(status: "Android 기기를 확인하는 중…") {
            try await service.deviceInfo()
        } onSuccess: { [weak self] device in
            self?.deviceDescription = device.serialNumber.isEmpty
                ? "MTP 연결됨 · \(device.displayName)"
                : "MTP 연결됨 · \(device.displayName) · \(device.serialNumber)"
            self?.isConnected = true
            self?.statusMessage = "MTP 기기가 연결되었습니다."
            self?.scheduleRemoteReload()
        }
    }

    func loadRemoteFiles(forceRefresh: Bool = false) {
        guard !isWorking else { return }
        guard isConnected else { refreshDevice(); return }

        if forceRefresh {
            markRemoteIndexStale()
        }

        if remoteDirectory == "/", !forceRefresh, !cachedRootFiles.isEmpty {
            remoteFiles = cachedRootFiles
            selectedRemoteFileIDs = Set(filteredRemoteFiles.prefix(1).map(\.id))
            statusMessage = "캐시된 루트 목록 \(cachedRootFiles.count)개 항목을 표시합니다."
            return
        }

        if let storageID = remoteStorageID,
           let folderID = remoteFolderID,
           !forceRefresh,
           let cachedFiles = cachedFolderFiles[RemoteFolderKey(storageID: storageID, folderID: folderID)] {
            remoteFiles = cachedFiles
            selectedRemoteFileIDs = Set(filteredRemoteFiles.prefix(1).map(\.id))
            statusMessage = "캐시된 폴더 목록 \(cachedFiles.count)개 항목을 표시합니다."
            return
        }

        let directory = remoteDirectory
        let service = service
        if let storageID = remoteStorageID, let folderID = remoteFolderID {
            perform(status: "Android 파일 목록을 읽는 중…") {
                if forceRefresh {
                    await service.invalidateIndex()
                }
                return try await service.listChildren(storageID: storageID, folderID: folderID)
                    .sorted { lhs, rhs in
                        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
            } onSuccess: { [weak self] files in
                self?.receiveRemoteFiles(
                    files,
                    for: directory,
                    folderKey: RemoteFolderKey(storageID: storageID, folderID: folderID)
                )
            }
        } else {
            perform(status: "Android 파일 목록을 읽는 중…") {
                if forceRefresh {
                    await service.invalidateIndex()
                }
                return try await service.list(path: directory).sorted { lhs, rhs in
                    lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            } onSuccess: { [weak self] files in
                self?.receiveRemoteFiles(files, for: directory)
            }
        }
    }

    func openRemoteFolder(_ file: RemoteFile) {
        guard file.isDirectory else { return }
        remoteFolderStack.append(currentRemoteLocation)
        remoteDirectory = remoteDirectory == "/"
            ? "/\(file.name)"
            : "\(remoteDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(file.name)"
        remoteDirectory = "/" + remoteDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        remoteStorageID = file.storageID
        remoteFolderID = file.objectID
        loadRemoteFiles()
    }

    func openParentRemoteFolder() {
        if let parent = remoteFolderStack.popLast() {
            remoteDirectory = parent.path
            remoteStorageID = parent.storageID
            remoteFolderID = parent.folderID
            loadRemoteFiles()
            return
        }
        let components = remoteDirectory.split(separator: "/")
        guard !components.isEmpty else { return }
        openRemotePath("/" + components.dropLast().joined(separator: "/"))
    }

    func openRemotePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteDirectory = trimmed.isEmpty || trimmed == "/"
            ? "/"
            : "/" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        remoteFolderStack = []
        remoteStorageID = nil
        remoteFolderID = nil
        loadRemoteFiles()
    }

    var filteredLocalFiles: [LocalFile] {
        sort(localFiles.filter { file in
            localSearchText.isEmpty || file.name.localizedCaseInsensitiveContains(localSearchText)
        }, by: localSortOption)
    }

    var filteredRemoteFiles: [RemoteFile] {
        sort(remoteFiles.filter { file in
            remoteSearchText.isEmpty || file.name.localizedCaseInsensitiveContains(remoteSearchText)
        }, by: remoteSortOption)
    }

    var selectedLocalFiles: [LocalFile] {
        filteredLocalFiles.filter { selectedLocalFileIDs.contains($0.id) }
    }

    var selectedRemoteFiles: [RemoteFile] {
        filteredRemoteFiles.filter { selectedRemoteFileIDs.contains($0.id) }
    }

    var selectedLocalFile: LocalFile? { selectedLocalFiles.first }
    var selectedRemoteFile: RemoteFile? { selectedRemoteFiles.first }

    func createRemoteFolder() {
        guard isConnected, !isWorking else { return }
        guard let name = requestRemoteName(
            title: "새 폴더",
            message: "Android의 현재 위치에 생성할 폴더 이름을 입력하세요.",
            initialValue: "새 폴더"
        ) else { return }
        guard !remoteFiles.contains(where: { $0.name == name }) else {
            showError(MTPError("\(name)과(와) 같은 이름의 항목이 이미 있습니다."))
            return
        }

        let directory = remoteDirectory
        let storageID = remoteStorageID
        let folderID = remoteFolderID
        let service = service
        perform(status: "Android에 \(name) 폴더를 만드는 중…") {
            try await service.createFolder(
                name: name,
                remoteDirectory: directory,
                storageID: storageID,
                folderID: folderID
            )
        } onSuccess: { [weak self] _ in
            self?.markRemoteIndexStale()
            self?.statusMessage = "\(name) 폴더를 만들었습니다."
            self?.scheduleRemoteReload()
        }
    }

    func renameRemoteFile(_ file: RemoteFile, to proposedName: String) {
        guard isConnected, !isWorking else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            showError(MTPError("이름은 비어 있을 수 없으며 '/'를 포함할 수 없습니다."))
            return
        }
        guard name != file.name else { return }
        guard !remoteFiles.contains(where: {
            $0.objectID != file.objectID && $0.name == name
        }) else {
            showError(MTPError("\(name)과(와) 같은 이름의 항목이 이미 있습니다."))
            return
        }

        updateRemoteFile(file, name: name)
        isWorking = true
        statusMessage = "\(file.name)의 이름을 \(name)(으)로 변경하는 중…"
        let service = service
        Task { [weak self] in
            do {
                try await service.rename(file: file, to: name)
                await Task.yield()
                guard let self else { return }
                self.isWorking = false
                self.markRemoteIndexStale()
                self.statusMessage = "\(file.name)의 이름을 \(name)(으)로 변경했습니다."
                self.scheduleRemoteReload()
            } catch {
                await Task.yield()
                guard let self else { return }
                self.isWorking = false
                self.updateRemoteFile(file, name: file.name)
                self.showError(error)
            }
        }
    }

    func deleteSelectedRemoteFiles() {
        let files = selectedRemoteFiles
        guard isConnected, !isWorking, !files.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = files.count == 1
            ? "\(files[0].name)을(를) 삭제하시겠습니까?"
            : "선택한 \(files.count)개 항목을 삭제하시겠습니까?"
        alert.informativeText = "Android에서 즉시 삭제되며 이 작업은 되돌릴 수 없습니다."
        let deleteButton = alert.addButton(withTitle: "삭제")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let service = service
        perform(status: "Android 항목 \(files.count)개를 삭제하는 중…") {
            for file in files {
                try await service.delete(file: file)
            }
            return files.count
        } onFinish: { [weak self] in
            self?.markRemoteIndexStale()
            self?.scheduleRemoteReload()
        } onSuccess: { [weak self] count in
            self?.statusMessage = "Android 항목 \(count)개를 삭제했습니다."
        }
    }

    func upload(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isWorking else { return }
        guard isConnected else { refreshDevice(); return }
        let destination = remoteDirectory
        let destinationStorageID = remoteStorageID
        let destinationFolderID = remoteFolderID
        let service = service
        let transferID = beginTransferProgress()

        perform(status: "파일을 Android로 전송하는 중…") {
            for url in urls {
                let allowed = url.startAccessingSecurityScopedResource()
                defer { if allowed { url.stopAccessingSecurityScopedResource() } }
                try await service.upload(
                    localURL: url,
                    remoteDirectory: destination,
                    storageID: destinationStorageID,
                    folderID: destinationFolderID
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateTransferProgress(progress, for: transferID)
                    }
                }
            }
            return urls.count
        } onFinish: { [weak self] in
            self?.finishTransferProgress(for: transferID)
        } onSuccess: { [weak self] count in
            self?.markRemoteIndexStale()
            self?.statusMessage = "\(count)개 항목을 Android로 전송했습니다."
            self?.scheduleRemoteReload()
        }
    }

    func uploadSelectedLocalFiles() {
        upload(urls: selectedLocalFiles.map(\.url))
    }

    func downloadSelectedFiles() {
        let files = selectedRemoteFiles
        guard !isWorking, isConnected, !files.isEmpty else { return }
        guard let downloads = selectDownloadDestinations(for: files) else { return }
        let service = service
        let transferID = beginTransferProgress()

        perform(status: "\(files.count)개 항목을 Mac으로 다운로드하는 중…") {
            for (file, destination) in downloads {
                try await service.download(file: file, destination: destination) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateTransferProgress(progress, for: transferID)
                    }
                }
            }
            return files.count
        } onFinish: { [weak self] in
            self?.finishTransferProgress(for: transferID)
        } onSuccess: { [weak self] count in
            self?.statusMessage = "\(count)개 항목을 다운로드했습니다."
        }
    }

    func filePromiseProvider(for file: RemoteFile) -> NSFilePromiseProvider {
        let fileExtension = URL(fileURLWithPath: file.name).pathExtension
        let contentType = file.isDirectory
            ? UTType.folder
            : UTType(filenameExtension: fileExtension) ?? UTType.data
        let promiseDelegate = RemoteFilePromiseDelegate(fileName: file.name) { [weak self] destination, completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(CancellationError())
                    return
                }
                guard self.isConnected,
                      !self.isWorking || self.activeFilePromises > 0 else {
                    completion(MTPError("다른 전송 작업이 진행 중이거나 기기가 연결되어 있지 않습니다."))
                    return
                }

                let transferID = self.beginFilePromiseTransfer()
                do {
                    try await self.service.download(file: file, destination: destination) { [weak self] value in
                        Task { @MainActor [weak self] in
                            self?.updateTransferProgress(value, for: transferID)
                        }
                    }
                    self.finishFilePromiseTransfer(succeeded: true)
                    completion(nil)
                } catch {
                    self.finishFilePromiseTransfer(succeeded: false)
                    self.showError(error)
                    completion(error)
                }
            }
        }
        let provider = NSFilePromiseProvider(fileType: contentType.identifier, delegate: promiseDelegate)
        provider.userInfo = promiseDelegate
        return provider
    }

    func reportLocalDrop(name: String, error: Error?) {
        if let error {
            showError(error)
        } else {
            loadLocalFiles()
            statusMessage = "\(name)을(를) Mac 폴더로 복사했습니다."
        }
    }

    private func requestRemoteName(
        title: String,
        message: String,
        initialValue: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")

        let nameField = NSTextField(string: initialValue)
        nameField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField
        nameField.selectText(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            showError(MTPError("이름은 비어 있을 수 없으며 '/'를 포함할 수 없습니다."))
            return nil
        }
        return name
    }

    private func updateRemoteFile(_ file: RemoteFile, name: String) {
        let updatedFile = RemoteFile(
            objectID: file.objectID,
            storageID: file.storageID,
            name: name,
            isDirectory: file.isDirectory,
            size: file.size
        )
        let replace: (RemoteFile) -> RemoteFile = { candidate in
            candidate.objectID == file.objectID && candidate.storageID == file.storageID
                ? updatedFile
                : candidate
        }
        remoteFiles = remoteFiles.map(replace)
        cachedRootFiles = cachedRootFiles.map(replace)
        cachedFolderFiles = cachedFolderFiles.mapValues { $0.map(replace) }
    }

    private func selectDownloadDestination(for file: RemoteFile) -> URL? {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if file.isDirectory {
            let panel = NSOpenPanel()
            panel.title = "다운로드할 폴더 위치 선택"
            panel.prompt = "선택"
            panel.directoryURL = downloads
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let selectedDirectory = panel.url else { return nil }
            return selectedDirectory.appendingPathComponent(file.name, isDirectory: true)
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.directoryURL = downloads
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func selectDownloadDestinations(for files: [RemoteFile]) -> [(RemoteFile, URL)]? {
        guard files.count > 1 else {
            guard let file = files.first,
                  let destination = selectDownloadDestination(for: file) else { return nil }
            return [(file, destination)]
        }

        let panel = NSOpenPanel()
        panel.title = "\(files.count)개 항목을 다운로드할 폴더 선택"
        panel.prompt = "선택"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return nil }
        return files.map { file in
            (file, directory.appendingPathComponent(file.name, isDirectory: file.isDirectory))
        }
    }

    private func perform<T: Sendable>(
        status: String,
        operation: @escaping @Sendable () async throws -> T,
        onFinish: @escaping () -> Void = {},
        onSuccess: @escaping (T) -> Void
    ) {
        isWorking = true
        statusMessage = status
        Task {
            do {
                let value = try await operation()
                await Task.yield()
                isWorking = false
                onFinish()
                onSuccess(value)
            } catch {
                await Task.yield()
                isWorking = false
                onFinish()
                showError(error)
            }
        }
    }

    private func beginTransferProgress() -> UUID {
        let transferID = UUID()
        currentTransferID = transferID
        transferProgress = 0
        transferBytes = 0
        transferTotalBytes = 0
        transferRateBytesPerSecond = 0
        transferStartedAt = Date()
        return transferID
    }

    private func beginFilePromiseTransfer() -> UUID {
        if activeFilePromises == 0 {
            filePromiseTransferID = beginTransferProgress()
            failedFilePromises = 0
        }
        activeFilePromises += 1
        isWorking = true
        statusMessage = "\(activeFilePromises)개 Android 항목을 Mac으로 전송하는 중…"
        guard let filePromiseTransferID else {
            preconditionFailure("파일 약속 전송 ID가 준비되지 않았습니다.")
        }
        return filePromiseTransferID
    }

    private func finishFilePromiseTransfer(succeeded: Bool) {
        if !succeeded {
            failedFilePromises += 1
        }
        activeFilePromises = max(activeFilePromises - 1, 0)
        guard activeFilePromises == 0 else { return }

        if let filePromiseTransferID {
            finishTransferProgress(for: filePromiseTransferID)
        }
        self.filePromiseTransferID = nil
        isWorking = false
        statusMessage = failedFilePromises == 0
            ? "선택한 Android 항목을 Mac으로 전송했습니다."
            : "Android 항목 \(failedFilePromises)개를 전송하지 못했습니다."
    }

    private func updateTransferProgress(_ progress: TransferProgress, for transferID: UUID) {
        guard currentTransferID == transferID else { return }
        let now = Date()
        if progress.bytesTransferred < transferBytes || transferStartedAt == nil {
            transferStartedAt = now
        }
        let elapsed = max(now.timeIntervalSince(transferStartedAt ?? now), 0.001)
        transferBytes = progress.bytesTransferred
        transferTotalBytes = progress.totalBytes
        transferProgress = progress.totalBytes > 0
            ? min(Double(progress.bytesTransferred) / Double(progress.totalBytes), 1)
            : nil
        transferRateBytesPerSecond = UInt64(Double(progress.bytesTransferred) / elapsed)
    }

    private func finishTransferProgress(for transferID: UUID) {
        guard currentTransferID == transferID else { return }
        currentTransferID = nil
        transferProgress = nil
        transferBytes = 0
        transferTotalBytes = 0
        transferRateBytesPerSecond = 0
        transferStartedAt = nil
    }

    private var currentRemoteLocation: RemoteFolderLocation {
        RemoteFolderLocation(
            path: remoteDirectory,
            storageID: remoteStorageID,
            folderID: remoteFolderID
        )
    }

    private func restoreLocalDirectoryAccess() -> Bool {
        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.localDirectoryBookmarkKey) else {
            return false
        }

        do {
            var isStale = false
            let directory = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            setLocalDirectory(directory, persistAccess: isStale)
            guard FileManager.default.isReadableFile(atPath: directory.path) else {
                releaseLocalDirectoryAccess()
                UserDefaults.standard.removeObject(forKey: Self.localDirectoryBookmarkKey)
                return false
            }
            loadLocalFiles()
            return true
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.localDirectoryBookmarkKey)
            return false
        }
    }

    private func setLocalDirectory(_ directory: URL, persistAccess: Bool) {
        releaseLocalDirectoryAccess()
        localDirectory = directory
        isAccessingLocalDirectory = directory.startAccessingSecurityScopedResource()

        guard persistAccess else { return }
        do {
            let bookmarkData = try directory.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: Self.localDirectoryBookmarkKey)
        } catch {
            showError(error)
        }
    }

    private func releaseLocalDirectoryAccess() {
        guard isAccessingLocalDirectory else { return }
        localDirectory.stopAccessingSecurityScopedResource()
        isAccessingLocalDirectory = false
    }

    private func receiveRemoteFiles(
        _ files: [RemoteFile],
        for directory: String,
        folderKey: RemoteFolderKey? = nil
    ) {
        guard remoteDirectory == directory else { return }
        if directory == "/" {
            cachedRootFiles = files
        }
        if let folderKey {
            cachedFolderFiles[folderKey] = files
        }
        remoteFiles = files
        selectedRemoteFileIDs = Set(filteredRemoteFiles.prefix(1).map(\.id))
        statusMessage = "\(files.count)개 항목을 불러왔습니다."
        if directory == "/", !hasRemoteIndex {
            startRemoteIndexing()
        }
    }

    private func startRemoteIndexing() {
        guard isConnected, !isIndexingRemoteFiles, !hasRemoteIndex else { return }
        isIndexingRemoteFiles = true
        statusMessage = "Android 전체 파일 인덱스를 백그라운드에서 준비하는 중…"
        let generation = connectionGeneration
        let requestedIndexGeneration = indexGeneration
        let service = service

        Task {
            do {
                let indexedRootFiles = try await service.refreshIndex().sorted { lhs, rhs in
                    lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                await Task.yield()
                guard connectionGeneration == generation,
                      indexGeneration == requestedIndexGeneration,
                      isConnected else { return }
                isIndexingRemoteFiles = false
                hasRemoteIndex = true
                cachedRootFiles = indexedRootFiles
                if remoteDirectory == "/" {
                    remoteFiles = indexedRootFiles
                    selectedRemoteFileIDs = Set(filteredRemoteFiles.prefix(1).map(\.id))
                    statusMessage = "Android 인덱스 준비 완료 · \(indexedRootFiles.count)개 최상위 항목"
                }
            } catch {
                guard connectionGeneration == generation,
                      indexGeneration == requestedIndexGeneration else { return }
                isIndexingRemoteFiles = false
                statusMessage = "빠른 목록 모드로 연결됨 · 전체 인덱스는 준비하지 못했습니다."
            }
        }
    }

    private func markRemoteIndexStale() {
        indexGeneration = UUID()
        isIndexingRemoteFiles = false
        hasRemoteIndex = false
        cachedRootFiles = []
        cachedFolderFiles = [:]
    }

    private func resetRemoteNavigation() {
        remoteDirectory = "/"
        remoteFolderStack = []
        remoteStorageID = nil
        remoteFolderID = nil
        markRemoteIndexStale()
    }

    private func scheduleRemoteReload() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.loadRemoteFiles(forceRefresh: true)
        }
    }

    private func showError(_ error: Error) {
        statusMessage = "작업을 완료하지 못했습니다."
        errorMessage = error.localizedDescription
        isShowingError = true
    }

    private func sort(_ files: [LocalFile], by option: FileSortOption) -> [LocalFile] {
        files.sorted { lhs, rhs in
            switch option {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .kind:
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func sort(_ files: [RemoteFile], by option: FileSortOption) -> [RemoteFile] {
        files.sorted { lhs, rhs in
            switch option {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .kind:
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
