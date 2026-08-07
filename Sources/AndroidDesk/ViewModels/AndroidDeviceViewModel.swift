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

    private struct RemoteSelectionTarget {
        let directory: String
        let name: String
    }

    private enum TransferRequest {
        case upload(
            localURL: URL,
            remoteDirectory: String,
            storageID: UInt32?,
            folderID: UInt32?
        )
        case download(file: RemoteFile, destination: URL)
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
    var isLoadingRemoteFiles = true
    var isIndexingRemoteFiles = false
    var transferProgress: Double?
    var transferBytes: UInt64 = 0
    var transferTotalBytes: UInt64 = 0
    var transferRateBytesPerSecond: UInt64 = 0
    var transferJobs: [TransferJob] = []
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
    private var remoteSelectionAfterReload: RemoteSelectionTarget?
    private var transferRequests: [UUID: TransferRequest] = [:]
    private var filePromiseCompletions: [UUID: FilePromiseCompletion] = [:]
    private var activeTransferProgress: Progress?
    private var queueNeedsRemoteReload = false
    private var queueNeedsLocalReload = false
    private var isAccessingLocalDirectory = false

    var isTransferQueueActive: Bool {
        transferJobs.contains { $0.state == .waiting || $0.state == .transferring }
    }

    func progressForTransfer(id: UUID) -> Progress? {
        currentTransferID == id ? activeTransferProgress : nil
    }

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
        cancelAllTransfers()
        connectionGeneration = UUID()
        isConnected = false
        isLoadingRemoteFiles = false
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

    func createLocalFolder() {
        guard !isWorking else { return }
        guard let name = requestName(
            title: "새 폴더",
            message: "Mac의 현재 위치에 생성할 폴더 이름을 입력하세요.",
            initialValue: "새 폴더"
        ) else { return }

        let folderURL = localDirectory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folderURL.path) else {
            showError(MTPError("\(name)과(와) 같은 이름의 항목이 이미 있습니다."))
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: false
            )
            loadLocalFiles()
            selectedLocalFileIDs = [folderURL]
            statusMessage = "Mac에 \(name) 폴더를 만들었습니다."
        } catch {
            showError(error)
        }
    }

    func renameLocalFile(_ file: LocalFile, to proposedName: String) {
        guard !isWorking else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidFileName(name) else {
            showError(MTPError("이름은 비어 있을 수 없으며 '/'를 포함할 수 없습니다."))
            return
        }
        guard name != file.name else { return }

        let destination = file.url.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: file.isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            showError(MTPError("\(name)과(와) 같은 이름의 항목이 이미 있습니다."))
            return
        }

        do {
            try FileManager.default.moveItem(at: file.url, to: destination)
            loadLocalFiles()
            selectedLocalFileIDs = [destination]
            statusMessage = "\(file.name)의 이름을 \(name)(으)로 변경했습니다."
        } catch {
            showError(error)
        }
    }

    func deleteSelectedLocalFiles() {
        let files = selectedLocalFiles
        guard !isWorking, !files.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = files.count == 1
            ? "\(files[0].name)을(를) 휴지통으로 이동하시겠습니까?"
            : "선택한 \(files.count)개 항목을 휴지통으로 이동하시겠습니까?"
        alert.informativeText = "Finder의 휴지통에서 다시 복원할 수 있습니다."
        let deleteButton = alert.addButton(withTitle: "휴지통으로 이동")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            for file in files {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: file.url, resultingItemURL: &resultingURL)
            }
            loadLocalFiles()
            statusMessage = "Mac 항목 \(files.count)개를 휴지통으로 이동했습니다."
        } catch {
            loadLocalFiles()
            showError(error)
        }
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
        guard !isWorking, !isTransferQueueActive else { return }
        connectionGeneration = UUID()
        isConnected = false
        isLoadingRemoteFiles = true
        isIndexingRemoteFiles = false
        deviceDescription = "MTP 기기를 확인하는 중…"
        resetRemoteNavigation()
        remoteFiles = []
        selectedRemoteFileIDs = []
        let service = service

        perform(status: "Android 기기를 확인하는 중…") {
            try await service.deviceInfo()
        } onFinish: { [weak self] in
            self?.isLoadingRemoteFiles = false
        } onSuccess: { [weak self] device in
            self?.isLoadingRemoteFiles = true
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
            isLoadingRemoteFiles = false
            remoteFiles = cachedRootFiles
            selectedRemoteFileIDs = Set(filteredRemoteFiles.prefix(1).map(\.id))
            statusMessage = "캐시된 루트 목록 \(cachedRootFiles.count)개 항목을 표시합니다."
            return
        }

        if let storageID = remoteStorageID,
           let folderID = remoteFolderID,
           !forceRefresh,
           let cachedFiles = cachedFolderFiles[RemoteFolderKey(storageID: storageID, folderID: folderID)] {
            isLoadingRemoteFiles = false
            remoteFiles = cachedFiles
            selectedRemoteFileIDs = Set(filteredRemoteFiles.prefix(1).map(\.id))
            statusMessage = "캐시된 폴더 목록 \(cachedFiles.count)개 항목을 표시합니다."
            return
        }

        let directory = remoteDirectory
        let service = service
        isLoadingRemoteFiles = true
        remoteFiles = []
        selectedRemoteFileIDs = []
        if let storageID = remoteStorageID, let folderID = remoteFolderID {
            perform(status: "Android 파일 목록을 읽는 중…") {
                if forceRefresh {
                    await service.invalidateIndex()
                }
                return try await service.listChildren(storageID: storageID, folderID: folderID)
                    .sorted { lhs, rhs in
                        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
            } onFinish: { [weak self] in
                self?.isLoadingRemoteFiles = false
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
            } onFinish: { [weak self] in
                self?.isLoadingRemoteFiles = false
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
        guard isConnected, !isWorking, !isTransferQueueActive else { return }
        guard let name = requestName(
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
        let previousSelection = selectedRemoteFileIDs
        let optimisticStorageID = storageID ?? remoteFiles.first?.storageID ?? 0
        let optimisticFolder = RemoteFile(
            objectID: optimisticRemoteObjectID(storageID: optimisticStorageID),
            storageID: optimisticStorageID,
            name: name,
            isDirectory: true,
            size: 0
        )
        insertRemoteFile(optimisticFolder)
        selectedRemoteFileIDs = [optimisticFolder.id]
        isWorking = true
        statusMessage = "Android에 \(name) 폴더를 만드는 중…"
        let service = service
        Task { [weak self] in
            do {
                try await service.createFolder(
                    name: name,
                    remoteDirectory: directory,
                    storageID: storageID,
                    folderID: folderID
                )
                await Task.yield()
                guard let self else { return }
                self.isWorking = false
                self.remoteSelectionAfterReload = RemoteSelectionTarget(
                    directory: directory,
                    name: name
                )
                self.markRemoteIndexStale()
                self.statusMessage = "\(name) 폴더를 만들었습니다."
                self.reconcileRemoteFilesAfterMutation()
            } catch {
                await Task.yield()
                guard let self else { return }
                self.isWorking = false
                self.removeRemoteFiles([optimisticFolder])
                if self.remoteDirectory == directory {
                    self.selectedRemoteFileIDs = previousSelection
                }
                self.showError(error)
            }
        }
    }

    func renameRemoteFile(_ file: RemoteFile, to proposedName: String) {
        guard isConnected, !isWorking, !isTransferQueueActive else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidFileName(name) else {
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
        let directory = remoteDirectory
        let service = service
        Task { [weak self] in
            do {
                try await service.rename(file: file, to: name)
                await Task.yield()
                guard let self else { return }
                self.isWorking = false
                self.remoteSelectionAfterReload = RemoteSelectionTarget(
                    directory: directory,
                    name: name
                )
                self.markRemoteIndexStale()
                self.statusMessage = "\(file.name)의 이름을 \(name)(으)로 변경했습니다."
                self.reconcileRemoteFilesAfterMutation()
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
        guard isConnected, !isWorking, !isTransferQueueActive, !files.isEmpty else { return }

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

        let directory = remoteDirectory
        let displayedFilesBeforeDeletion = remoteFiles
        removeRemoteFiles(files)
        selectedRemoteFileIDs = Set(filteredRemoteFiles.prefix(1).map(\.id))
        isWorking = true
        statusMessage = "Android 항목 \(files.count)개를 삭제하는 중…"
        let service = service
        Task { [weak self] in
            var failedFiles: [RemoteFile] = []
            var failureMessages: [String] = []
            for file in files {
                do {
                    try await service.delete(file: file)
                } catch {
                    failedFiles.append(file)
                    failureMessages.append("\(file.name): \(error.localizedDescription)")
                }
            }
            await Task.yield()
            guard let self else { return }

            self.isWorking = false
            self.markRemoteIndexStale()
            if self.remoteDirectory == directory, !failedFiles.isEmpty {
                self.restoreRemoteFiles(failedFiles, from: displayedFilesBeforeDeletion)
                self.selectedRemoteFileIDs = Set(failedFiles.map(\.id))
            }

            let deletedCount = files.count - failedFiles.count
            self.statusMessage = failedFiles.isEmpty
                ? "Android 항목 \(deletedCount)개를 삭제했습니다."
                : "Android 항목 \(deletedCount)개 삭제 · \(failedFiles.count)개 실패"
            if !failureMessages.isEmpty {
                self.showError(MTPError(failureMessages.joined(separator: "\n")))
            }
            self.reconcileRemoteFilesAfterMutation()
        }
    }

    func upload(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isWorking else { return }
        guard isConnected else { refreshDevice(); return }
        let destination = remoteDirectory
        let destinationStorageID = remoteStorageID
        let destinationFolderID = remoteFolderID

        for url in urls {
            enqueueTransfer(
                name: url.lastPathComponent,
                direction: .upload,
                totalBytes: localItemSize(at: url),
                request: .upload(
                    localURL: url,
                    remoteDirectory: destination,
                    storageID: destinationStorageID,
                    folderID: destinationFolderID
                )
            )
        }
        statusMessage = "Android 업로드 \(urls.count)개를 대기열에 추가했습니다."
    }

    func uploadSelectedLocalFiles() {
        upload(urls: selectedLocalFiles.map(\.url))
    }

    func downloadSelectedFiles() {
        let files = selectedRemoteFiles
        guard !isWorking, isConnected, !files.isEmpty else { return }
        guard let downloads = selectDownloadDestinations(for: files) else { return }

        for (file, destination) in downloads {
            enqueueTransfer(
                name: file.name,
                direction: .download,
                totalBytes: file.size,
                request: .download(file: file, destination: destination)
            )
        }
        statusMessage = "Mac 다운로드 \(files.count)개를 대기열에 추가했습니다."
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
                guard self.isConnected, !self.isWorking else {
                    completion(MTPError("다른 전송 작업이 진행 중이거나 기기가 연결되어 있지 않습니다."))
                    return
                }
                let transferID = self.enqueueTransfer(
                    name: file.name,
                    direction: .download,
                    totalBytes: file.size,
                    request: .download(file: file, destination: destination)
                )
                self.filePromiseCompletions[transferID] = completion
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

    private func requestName(
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
        guard isValidFileName(name) else {
            showError(MTPError("이름은 비어 있을 수 없으며 '/'를 포함할 수 없습니다."))
            return nil
        }
        return name
    }

    private func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
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

    private func optimisticRemoteObjectID(storageID: UInt32) -> UInt32 {
        var candidate = UInt32.max
        while remoteFiles.contains(where: {
            $0.storageID == storageID && $0.objectID == candidate
        }) {
            candidate &-= 1
        }
        return candidate
    }

    private func insertRemoteFile(_ file: RemoteFile) {
        remoteFiles.append(file)
        if remoteDirectory == "/" {
            cachedRootFiles = remoteFiles
        } else if let storageID = remoteStorageID, let folderID = remoteFolderID {
            cachedFolderFiles[RemoteFolderKey(storageID: storageID, folderID: folderID)] = remoteFiles
        }
    }

    private func removeRemoteFiles(_ files: [RemoteFile]) {
        let fileIDs = Set(files.map(\.id))
        remoteFiles.removeAll { fileIDs.contains($0.id) }
        cachedRootFiles.removeAll { fileIDs.contains($0.id) }
        cachedFolderFiles = cachedFolderFiles.mapValues { cachedFiles in
            cachedFiles.filter { !fileIDs.contains($0.id) }
        }
    }

    private func restoreRemoteFiles(_ files: [RemoteFile], from snapshot: [RemoteFile]) {
        let fileIDs = Set(files.map(\.id))
        let restoredFiles = snapshot.filter { fileIDs.contains($0.id) }
        let currentIDs = Set(remoteFiles.map(\.id))
        remoteFiles.append(contentsOf: restoredFiles.filter { !currentIDs.contains($0.id) })
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

    @discardableResult
    private func enqueueTransfer(
        name: String,
        direction: TransferDirection,
        totalBytes: UInt64,
        request: TransferRequest
    ) -> UUID {
        let id = UUID()
        transferRequests[id] = request
        transferJobs.append(
            TransferJob(
                id: id,
                name: name,
                direction: direction,
                state: .waiting,
                bytesTransferred: 0,
                totalBytes: totalBytes,
                bytesPerSecond: 0,
                errorMessage: nil
            )
        )
        startNextTransferIfNeeded()
        return id
    }

    func cancelTransfer(id: UUID) {
        guard let index = transferJobs.firstIndex(where: { $0.id == id }) else { return }
        switch transferJobs[index].state {
        case .waiting:
            transferJobs[index].state = .cancelled
            transferJobs[index].errorMessage = "사용자가 전송을 취소했습니다."
            filePromiseCompletions.removeValue(forKey: id)?.callAsFunction(CancellationError())
        case .transferring:
            guard currentTransferID == id else { return }
            activeTransferProgress?.cancel()
            statusMessage = "\(transferJobs[index].name) 전송을 취소하는 중…"
        case .completed, .failed, .cancelled:
            return
        }
        startNextTransferIfNeeded()
    }

    func cancelAllTransfers() {
        activeTransferProgress?.cancel()
        for index in transferJobs.indices where transferJobs[index].state == .waiting {
            let id = transferJobs[index].id
            transferJobs[index].state = .cancelled
            transferJobs[index].errorMessage = "사용자가 전송을 취소했습니다."
            filePromiseCompletions.removeValue(forKey: id)?.callAsFunction(CancellationError())
        }
    }

    func retryTransfer(id: UUID) {
        guard isConnected,
              let index = transferJobs.firstIndex(where: { $0.id == id }),
              transferJobs[index].canRetry,
              transferRequests[id] != nil else { return }
        transferJobs[index].state = .waiting
        transferJobs[index].bytesTransferred = 0
        transferJobs[index].bytesPerSecond = 0
        transferJobs[index].errorMessage = nil
        startNextTransferIfNeeded()
    }

    func retryFailedTransfers() {
        guard isConnected else { return }
        for index in transferJobs.indices
        where transferJobs[index].canRetry && transferRequests[transferJobs[index].id] != nil {
            transferJobs[index].state = .waiting
            transferJobs[index].bytesTransferred = 0
            transferJobs[index].bytesPerSecond = 0
            transferJobs[index].errorMessage = nil
        }
        startNextTransferIfNeeded()
    }

    func clearFinishedTransfers() {
        let removableIDs = Set(
            transferJobs.lazy
                .filter { !$0.canCancel }
                .map(\.id)
        )
        transferJobs.removeAll { removableIDs.contains($0.id) }
        for id in removableIDs {
            transferRequests.removeValue(forKey: id)
            filePromiseCompletions.removeValue(forKey: id)
        }
    }

    private func startNextTransferIfNeeded() {
        guard currentTransferID == nil, isConnected,
              let index = transferJobs.firstIndex(where: { $0.state == .waiting }) else {
            if currentTransferID == nil {
                finishTransferQueueIfNeeded()
            }
            return
        }

        let id = transferJobs[index].id
        let cancellation = TransferCancellationToken()
        let foundationProgress = Progress(
            totalUnitCount: max(Int64(clamping: transferJobs[index].totalBytes), 1)
        )
        foundationProgress.isCancellable = true
        foundationProgress.isPausable = false
        foundationProgress.cancellationHandler = {
            cancellation.cancel()
        }

        transferJobs[index].state = .transferring
        transferJobs[index].errorMessage = nil
        currentTransferID = id
        activeTransferProgress = foundationProgress
        transferProgress = transferJobs[index].totalBytes > 0 ? 0 : nil
        transferBytes = 0
        transferTotalBytes = transferJobs[index].totalBytes
        transferRateBytesPerSecond = 0
        transferStartedAt = Date()
        statusMessage = "\(transferJobs[index].name)을(를) 전송하는 중…"

        Task { [weak self] in
            await self?.executeTransfer(id: id, cancellation: cancellation)
        }
    }

    private func executeTransfer(id: UUID, cancellation: TransferCancellationToken) async {
        guard let request = transferRequests[id] else {
            finishTransfer(id: id, error: MTPError("전송 정보를 찾지 못했습니다."))
            return
        }

        do {
            switch request {
            case let .upload(localURL, remoteDirectory, storageID, folderID):
                queueNeedsRemoteReload = true
                let allowed = localURL.startAccessingSecurityScopedResource()
                defer { if allowed { localURL.stopAccessingSecurityScopedResource() } }
                try await service.upload(
                    localURL: localURL,
                    remoteDirectory: remoteDirectory,
                    storageID: storageID,
                    folderID: folderID,
                    cancellation: cancellation
                ) { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.updateTransferProgress(value, for: id)
                    }
                }
            case let .download(file, destination):
                queueNeedsLocalReload = true
                try await service.download(
                    file: file,
                    destination: destination,
                    cancellation: cancellation
                ) { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.updateTransferProgress(value, for: id)
                    }
                }
            }
            finishTransfer(id: id, error: nil)
        } catch {
            finishTransfer(id: id, error: error)
        }
    }

    private func finishTransfer(id: UUID, error: Error?) {
        guard let index = transferJobs.firstIndex(where: { $0.id == id }) else { return }
        let wasCancelled = activeTransferProgress?.isCancelled == true || error is CancellationError
        if let error {
            transferJobs[index].state = wasCancelled ? .cancelled : .failed
            transferJobs[index].errorMessage = wasCancelled
                ? "사용자가 전송을 취소했습니다."
                : error.localizedDescription
        } else {
            transferJobs[index].state = .completed
            transferJobs[index].bytesTransferred = max(
                transferJobs[index].bytesTransferred,
                transferJobs[index].totalBytes
            )
            transferJobs[index].errorMessage = nil
        }

        let completion = filePromiseCompletions.removeValue(forKey: id)
        if wasCancelled {
            completion?.callAsFunction(CancellationError())
        } else {
            completion?.callAsFunction(error)
        }

        finishTransferProgress(for: id)
        activeTransferProgress = nil
        startNextTransferIfNeeded()
    }

    private func finishTransferQueueIfNeeded() {
        guard !transferJobs.contains(where: { $0.state == .waiting || $0.state == .transferring }) else {
            return
        }
        if queueNeedsRemoteReload {
            queueNeedsRemoteReload = false
            markRemoteIndexStale()
            reconcileRemoteFilesAfterMutation()
        }
        if queueNeedsLocalReload {
            queueNeedsLocalReload = false
            loadLocalFiles()
        }

        let completed = transferJobs.lazy.filter { $0.state == .completed }.count
        let failed = transferJobs.lazy.filter { $0.state == .failed }.count
        let cancelled = transferJobs.lazy.filter { $0.state == .cancelled }.count
        if completed + failed + cancelled > 0 {
            statusMessage = "전송 완료 \(completed)개 · 실패 \(failed)개 · 취소 \(cancelled)개"
        }
    }

    private func localItemSize(at url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory != true else { return 0 }
        return UInt64(values?.fileSize ?? 0)
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
        activeTransferProgress?.totalUnitCount = max(Int64(clamping: progress.totalBytes), 1)
        activeTransferProgress?.completedUnitCount = Int64(clamping: progress.bytesTransferred)
        guard let index = transferJobs.firstIndex(where: { $0.id == transferID }) else { return }
        transferJobs[index].bytesTransferred = progress.bytesTransferred
        transferJobs[index].totalBytes = progress.totalBytes
        transferJobs[index].bytesPerSecond = transferRateBytesPerSecond
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
        if let selectionTarget = remoteSelectionAfterReload,
           selectionTarget.directory == directory,
           let selectedFile = filteredRemoteFiles.first(where: { $0.name == selectionTarget.name }) {
            selectedRemoteFileIDs = [selectedFile.id]
        } else {
            selectedRemoteFileIDs = Set(filteredRemoteFiles.prefix(1).map(\.id))
        }
        if remoteSelectionAfterReload?.directory == directory {
            remoteSelectionAfterReload = nil
        }
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
                let indexedFolderFiles = try await buildIndexedFolderCache(
                    rootFiles: indexedRootFiles,
                    service: service
                )
                await Task.yield()
                guard connectionGeneration == generation,
                      indexGeneration == requestedIndexGeneration,
                      isConnected else { return }
                isIndexingRemoteFiles = false
                hasRemoteIndex = true
                cachedRootFiles = indexedRootFiles
                cachedFolderFiles.merge(indexedFolderFiles) { current, _ in current }
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

    private func buildIndexedFolderCache(
        rootFiles: [RemoteFile],
        service: any MTPServicing
    ) async throws -> [RemoteFolderKey: [RemoteFile]] {
        var cache: [RemoteFolderKey: [RemoteFile]] = [:]
        var pendingFolders = rootFiles.filter(\.isDirectory)
        var visitedFolders: Set<RemoteFolderKey> = []

        while let folder = pendingFolders.popLast() {
            let key = RemoteFolderKey(storageID: folder.storageID, folderID: folder.objectID)
            guard visitedFolders.insert(key).inserted else { continue }

            let children = try await service.listChildren(
                storageID: folder.storageID,
                folderID: folder.objectID
            ).sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            cache[key] = children
            pendingFolders.append(contentsOf: children.filter(\.isDirectory))
        }

        return cache
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

    private func reconcileRemoteFilesAfterMutation() {
        let directory = remoteDirectory
        let storageID = remoteStorageID
        let folderID = remoteFolderID
        let service = service

        Task { [weak self] in
            do {
                let files: [RemoteFile]
                let folderKey: RemoteFolderKey?
                if let storageID, let folderID {
                    files = try await service.listChildren(
                        storageID: storageID,
                        folderID: folderID
                    ).sorted { lhs, rhs in
                        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    folderKey = RemoteFolderKey(storageID: storageID, folderID: folderID)
                } else {
                    files = try await service.list(path: directory).sorted { lhs, rhs in
                        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    folderKey = nil
                }

                await Task.yield()
                guard let self, self.remoteDirectory == directory else { return }
                self.receiveRemoteFiles(files, for: directory, folderKey: folderKey)
            } catch {
                // 낙관적 결과를 유지하고 사용자가 명시적으로 새로고침할 때 다시 동기화한다.
            }
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
