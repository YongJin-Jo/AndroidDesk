import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AndroidDeviceViewModel {
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
    var selectedLocalFile: LocalFile?
    var localSearchText = ""
    var localSortOption: FileSortOption = .name
    var remoteDirectory = "/"
    var remoteFiles: [RemoteFile] = []
    var selectedRemoteFile: RemoteFile?
    var remoteSearchText = ""
    var remoteSortOption: FileSortOption = .name
    var statusMessage = "준비됨"
    var isWorking = false
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
    private var transferStartedAt: Date?
    private var currentTransferID: UUID?

    init(service: any MTPServicing) {
        self.service = service
    }

    func start() {
        loadLocalFiles()
        refreshDevice()
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
            selectedLocalFile = nil
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

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = "표시할 Mac 폴더 선택"
        panel.prompt = "선택"
        panel.directoryURL = localDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        localDirectory = directory
        loadLocalFiles()
    }

    func refreshDevice() {
        guard !isWorking else { return }
        isConnected = false
        deviceDescription = "MTP 기기를 확인하는 중…"
        resetRemoteNavigation()
        remoteFiles = []
        selectedRemoteFile = nil
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

        if remoteDirectory == "/", !forceRefresh, !cachedRootFiles.isEmpty {
            remoteFiles = cachedRootFiles
            selectedRemoteFile = nil
            statusMessage = "캐시된 루트 목록 \(cachedRootFiles.count)개 항목을 표시합니다."
            return
        }

        if let storageID = remoteStorageID,
           let folderID = remoteFolderID,
           !forceRefresh,
           let cachedFiles = cachedFolderFiles[RemoteFolderKey(storageID: storageID, folderID: folderID)] {
            remoteFiles = cachedFiles
            selectedRemoteFile = nil
            statusMessage = "캐시된 폴더 목록 \(cachedFiles.count)개 항목을 표시합니다."
            return
        }

        let directory = remoteDirectory
        let service = service
        if let storageID = remoteStorageID, let folderID = remoteFolderID {
            perform(status: "Android 파일 목록을 읽는 중…") {
                try await service.listChildren(storageID: storageID, folderID: folderID)
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
                try await service.list(path: directory).sorted { lhs, rhs in
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

    func upload(urls: [URL]) {
        guard !isWorking else { return }
        guard isConnected else { refreshDevice(); return }
        let destination = remoteDirectory
        let service = service
        let transferID = beginTransferProgress()

        perform(status: "파일을 Android로 전송하는 중…") {
            for url in urls {
                let allowed = url.startAccessingSecurityScopedResource()
                defer { if allowed { url.stopAccessingSecurityScopedResource() } }
                try await service.upload(localURL: url, remoteDirectory: destination) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateTransferProgress(progress, for: transferID)
                    }
                }
            }
            return urls.count
        } onFinish: { [weak self] in
            self?.finishTransferProgress(for: transferID)
        } onSuccess: { [weak self] count in
            self?.statusMessage = "\(count)개 항목을 Android로 전송했습니다."
            self?.scheduleRemoteReload()
        }
    }

    func uploadSelectedLocalFile() {
        guard let file = selectedLocalFile else { return }
        upload(urls: [file.url])
    }

    func downloadSelectedFile() {
        guard !isWorking, isConnected, let file = selectedRemoteFile else { return }
        guard let destination = selectDownloadDestination(for: file) else { return }
        let service = service
        let transferID = beginTransferProgress()

        perform(status: "파일을 Mac으로 다운로드하는 중…") {
            try await service.download(file: file, destination: destination) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateTransferProgress(progress, for: transferID)
                }
            }
            return file.name
        } onFinish: { [weak self] in
            self?.finishTransferProgress(for: transferID)
        } onSuccess: { [weak self] name in
            self?.statusMessage = "\(name)을(를) 다운로드했습니다."
        }
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
        selectedRemoteFile = nil
        statusMessage = "\(files.count)개 항목을 불러왔습니다."
    }

    private func resetRemoteNavigation() {
        remoteDirectory = "/"
        remoteFolderStack = []
        remoteStorageID = nil
        remoteFolderID = nil
        cachedRootFiles = []
        cachedFolderFiles = [:]
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
