import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

private enum LocalDropCopier {
    static func copy(_ source: URL, to directory: URL) -> (name: String, error: Error?) {
        let hasSecurityAccess = source.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let name = source.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw MTPError("\(name)과(와) 같은 이름의 항목이 이미 있습니다.")
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return (name, nil)
        } catch {
            return (name, error)
        }
    }
}

private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

private struct RemoteTableRow: Identifiable {
    let id: String
    let file: RemoteFile?
    let placeholderName: String

    init(file: RemoteFile) {
        id = file.id
        self.file = file
        placeholderName = file.name
    }

    init(placeholderIndex: Int, name: String) {
        id = "android-loading-\(placeholderIndex)"
        file = nil
        placeholderName = name
    }

    var sortableName: String { file?.name ?? placeholderName }
    var sortableSize: UInt64 { file?.size ?? 0 }
    var sortableAddedDate: Date { file?.sortableAddedDate ?? .distantPast }
    var sortableKind: String { file?.kind ?? "" }
}

struct ContentView: View {
    private enum NativeDragSource: Equatable {
        case local
        case remote
    }

    private enum ClickTarget: Equatable {
        case local(LocalFile.ID)
        case remote(RemoteFile.ID)
    }

    @Bindable var viewModel: AndroidDeviceViewModel
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var isRemoteDropTargeted = false
    @State private var remotePathInput = "/"
    @State private var lastClickTarget: ClickTarget?
    @State private var lastClickDate: Date?
    @State private var nativeDragSource: NativeDragSource?
    @State private var renamingLocalFileID: LocalFile.ID?
    @State private var renamingRemoteFileID: RemoteFile.ID?
    @State private var localSortOrder = [KeyPathComparator(\LocalFile.name)]
    @State private var remoteSortOrder = [KeyPathComparator(\RemoteTableRow.sortableName)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                localPane
                    .frame(minWidth: 350)
                remotePane
                    .frame(minWidth: 390)
            }

            if !viewModel.transferJobs.isEmpty {
                Divider()
                NativeTransferQueueView(
                    jobs: viewModel.transferJobs,
                    progressForJob: { viewModel.progressForTransfer(id: $0) },
                    onCancel: { viewModel.cancelTransfer(id: $0) },
                    onRetry: { viewModel.retryTransfer(id: $0) },
                    onCancelAll: { viewModel.cancelAllTransfers() },
                    onRetryFailed: { viewModel.retryFailedTransfers() },
                    onClearFinished: { viewModel.clearFinishedTransfers() }
                )
                .frame(
                    minHeight: 100,
                    idealHeight: min(CGFloat(viewModel.transferJobs.count) * 53 + 48, 220),
                    maxHeight: 220
                )
            }

            Divider()
            statusBar
        }
        .task {
            await Task.yield()
            viewModel.start()
        }
        .onChange(of: viewModel.remoteDirectory, initial: true) { _, path in
            remotePathInput = path
        }
        .onChange(of: viewModel.localDirectory) { _, _ in
            cancelLocalRename()
        }
        .onDisappear {
            viewModel.stop()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            viewModel.upload(urls: urls)
        }
        .alert("AndroidDesk", isPresented: $viewModel.isShowingError) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: viewModel.isConnected ? "iphone.gen3.radiowaves.left.and.right" : "cable.connector.slash")
                .font(.title2)
                .foregroundStyle(viewModel.isConnected ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("AndroidDesk")
                    .font(.headline)
                Text(viewModel.deviceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.refreshDevice()
            } label: {
                Label("새로고침", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isWorking || viewModel.isTransferQueueActive)
        }
        .padding()
    }

    private var localPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Mac의 파일", systemImage: "laptopcomputer")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.createLocalFolder()
                } label: {
                    Label("새 폴더", systemImage: "folder.badge.plus")
                }
                .disabled(viewModel.isWorking)
                Button("폴더 선택…") { viewModel.chooseLocalFolder() }
                    .disabled(viewModel.isWorking)
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.openParentLocalFolder()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("상위 폴더")
                .disabled(viewModel.localDirectory.pathComponents.count <= 1 || viewModel.isWorking)

                Text(viewModel.localDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            fileControls(
                searchText: $viewModel.localSearchText,
                prompt: "Mac 파일 검색"
            )

            Table(
                displayedLocalFiles,
                selection: $viewModel.selectedLocalFileIDs,
                sortOrder: $localSortOrder
            ) {
                TableColumn(
                    "이름",
                    sortUsing: KeyPathComparator(\LocalFile.name)
                ) { file in
                    HStack {
                        Image(systemName: file.isDirectory ? "folder" : "doc")
                            .foregroundStyle(file.isDirectory ? .orange : .secondary)
                        if renamingLocalFileID == file.id {
                            NativeInlineRenameField(
                                initialText: file.name,
                                onCommit: { name in
                                    finishLocalRename(file, name: name)
                                },
                                onCancel: {
                                    cancelLocalRename()
                                }
                            )
                            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 24)
                            .zIndex(1)
                        } else {
                            Text(file.name)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 28,
                        maxHeight: .infinity,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            guard renamingLocalFileID == nil else { return }
                            handleLocalClick(file)
                        }
                    )
                    .contextMenu {
                        Button("열기") {
                            viewModel.selectedLocalFileIDs = [file.id]
                            viewModel.openLocalFolder(file)
                        }
                        .disabled(!file.isDirectory)

                        Button("이름 변경…") {
                            beginLocalRename(file)
                        }

                        Divider()
                        Button("휴지통으로 이동", role: .destructive) {
                            cancelLocalRename()
                            if !viewModel.selectedLocalFileIDs.contains(file.id) {
                                viewModel.selectedLocalFileIDs = [file.id]
                            }
                            viewModel.deleteSelectedLocalFiles()
                        }
                    }
                }
                .width(min: 160, ideal: 260, max: 420)
                TableColumn(
                    "크기",
                    sortUsing: KeyPathComparator(\LocalFile.size)
                ) { file in
                    Text(fileSizeText(size: file.size, isDirectory: file.isDirectory))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 72, ideal: 88, max: 110)
                TableColumn(
                    "추가된 날짜",
                    sortUsing: KeyPathComparator(\LocalFile.sortableAddedDate)
                ) { file in
                    Text(fileDateText(file.addedDate))
                        .foregroundStyle(.secondary)
                }
                .width(min: 125, ideal: 145, max: 180)
                TableColumn(
                    "종류",
                    sortUsing: KeyPathComparator(\LocalFile.kind)
                ) { file in
                    Text(file.kind)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 115, max: 160)
            }
            .tableColumnHeaders(.visible)
            .background {
                NativeFileTableBridge(
                    dragWriters: { indexes in
                        indexes.compactMap { index in
                            guard displayedLocalFiles.indices.contains(index) else { return nil }
                            return displayedLocalFiles[index].url as NSURL as any NSPasteboardWriting
                        }
                    },
                    onDragBegan: {
                        nativeDragSource = .local
                    },
                    onDragEnded: {
                        nativeDragSource = nil
                    },
                    editingRow: renamingLocalFileID.flatMap { fileID in
                        displayedLocalFiles.firstIndex { $0.id == fileID }
                    },
                    onCreateFolder: {
                        viewModel.createLocalFolder()
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay {
                if viewModel.filteredLocalFiles.isEmpty {
                    ContentUnavailableView(
                        viewModel.localSearchText.isEmpty ? "표시할 파일이 없습니다" : "검색 결과가 없습니다",
                        systemImage: "folder",
                        description: Text("다른 폴더를 선택하거나 접근 권한을 확인하세요.")
                    )
                }
            }
            .onDrop(of: [.fileURL, .data, .folder], isTargeted: $isDropTargeted) { providers in
                guard nativeDragSource != .local else { return false }
                return receiveFilesOnMac(from: providers)
            }
            .onKeyPress(.return) {
                guard renamingLocalFileID == nil,
                      viewModel.selectedLocalFiles.count == 1,
                      let file = viewModel.selectedLocalFile,
                      !viewModel.isWorking else { return .ignored }
                beginLocalRename(file)
                return .handled
            }
            .onKeyPress(.delete) {
                guard renamingLocalFileID == nil,
                      !viewModel.selectedLocalFiles.isEmpty,
                      !viewModel.isWorking else { return .ignored }
                viewModel.deleteSelectedLocalFiles()
                return .handled
            }

            HStack {
                Button(localUploadButtonTitle) { viewModel.uploadSelectedLocalFiles() }
                    .disabled(
                        viewModel.selectedLocalFiles.isEmpty
                            || !viewModel.isConnected
                            || viewModel.isWorking
                    )
                Spacer()
                Button("파일 선택…") { isImporting = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isWorking)
            }

            Text("⌘·Shift로 여러 항목을 선택하거나, 파일·폴더를 양쪽 영역 또는 Finder로 끌어 전송할 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var remotePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Android 파일", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.createRemoteFolder()
                } label: {
                    Label("새 폴더", systemImage: "folder.badge.plus")
                }
                .disabled(
                    !viewModel.isConnected
                        || viewModel.isWorking
                        || viewModel.isTransferQueueActive
                )
                Button("목록 갱신") { viewModel.loadRemoteFiles(forceRefresh: true) }
                    .disabled(
                        !viewModel.isConnected
                            || viewModel.isWorking
                            || viewModel.isTransferQueueActive
                    )
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.openParentRemoteFolder()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("상위 폴더")
                .disabled(viewModel.remoteDirectory == "/" || viewModel.isWorking)

                TextField("MTP 폴더 (예: /Download)", text: $remotePathInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.openRemotePath(remotePathInput) }
            }

            fileControls(
                searchText: $viewModel.remoteSearchText,
                prompt: "Android 파일 검색"
            )

            Table(
                remoteTableRows,
                selection: remoteTableSelection,
                sortOrder: $remoteSortOrder
            ) {
                TableColumn(
                    "이름",
                    sortUsing: KeyPathComparator(\RemoteTableRow.sortableName)
                ) { row in
                    if let file = row.file {
                        remoteFileRow(file)
                    } else {
                        remoteSkeletonRow(name: row.placeholderName)
                    }
                }
                .width(min: 160, ideal: 280, max: 440)
                TableColumn(
                    "크기",
                    sortUsing: KeyPathComparator(\RemoteTableRow.sortableSize)
                ) { row in
                    if let file = row.file {
                        Text(fileSizeText(size: file.size, isDirectory: file.isDirectory))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        remoteSkeletonMetadata(width: 54)
                    }
                }
                .width(min: 72, ideal: 88, max: 110)
                TableColumn(
                    "추가된 날짜",
                    sortUsing: KeyPathComparator(\RemoteTableRow.sortableAddedDate)
                ) { row in
                    if let file = row.file {
                        Text(fileDateText(file.addedDate))
                            .foregroundStyle(.secondary)
                    } else {
                        remoteSkeletonMetadata(width: 100)
                    }
                }
                .width(min: 125, ideal: 145, max: 180)
                TableColumn(
                    "종류",
                    sortUsing: KeyPathComparator(\RemoteTableRow.sortableKind)
                ) { row in
                    if let file = row.file {
                        Text(file.kind)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    } else {
                        remoteSkeletonMetadata(width: 68)
                    }
                }
                .width(min: 90, ideal: 115, max: 160)
            }
            .tableColumnHeaders(.visible)
            .background {
                NativeFileTableBridge(
                    dragWriters: { indexes in
                        indexes.compactMap { index in
                            guard displayedRemoteFiles.indices.contains(index) else { return nil }
                            return viewModel.filePromiseProvider(
                                for: displayedRemoteFiles[index]
                            ) as any NSPasteboardWriting
                        }
                    },
                    onDragBegan: {
                        nativeDragSource = .remote
                    },
                    onDragEnded: {
                        nativeDragSource = nil
                    },
                    editingRow: renamingRemoteFileID.flatMap { fileID in
                        displayedRemoteFiles.firstIndex { $0.id == fileID }
                    },
                    onCreateFolder: viewModel.isLoadingRemoteFiles || viewModel.isTransferQueueActive ? nil : {
                        viewModel.createRemoteFolder()
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay {
                if isRemoteDropTargeted && !viewModel.isLoadingRemoteFiles {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay {
                            Label("여기에 놓아 Android로 업로드", systemImage: "arrow.down.doc")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(4)
                } else if !viewModel.isLoadingRemoteFiles
                            && viewModel.filteredRemoteFiles.isEmpty
                            && !viewModel.isWorking {
                    ContentUnavailableView(
                        viewModel.remoteSearchText.isEmpty ? "표시할 파일이 없습니다" : "검색 결과가 없습니다",
                        systemImage: "folder",
                        description: Text("목록 갱신을 눌러 Android 폴더를 읽으세요.")
                    )
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isRemoteDropTargeted) { providers in
                guard nativeDragSource != .remote else { return false }
                return receiveFilesForUpload(from: providers)
            }
            .onKeyPress(.return) {
                guard renamingRemoteFileID == nil,
                      viewModel.selectedRemoteFiles.count == 1,
                      let file = viewModel.selectedRemoteFile,
                      !viewModel.isWorking,
                      !viewModel.isTransferQueueActive else { return .ignored }
                beginRemoteRename(file)
                return .handled
            }
            .onKeyPress(.delete) {
                guard renamingRemoteFileID == nil,
                      !viewModel.selectedRemoteFiles.isEmpty,
                      !viewModel.isWorking,
                      !viewModel.isTransferQueueActive else { return .ignored }
                viewModel.deleteSelectedRemoteFiles()
                return .handled
            }

            HStack {
                Button(remoteDownloadButtonTitle) { viewModel.downloadSelectedFiles() }
                    .disabled(viewModel.selectedRemoteFiles.isEmpty || viewModel.isWorking)
                Spacer()
                Button("여기로 업로드") { isImporting = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.isConnected || viewModel.isWorking)
            }
        }
        .padding()
    }

    private var remoteTableRows: [RemoteTableRow] {
        if viewModel.isLoadingRemoteFiles {
            let names = [
                "Android 파일을 불러오는 중입니다",
                "파일 이름을 확인하는 중",
                "폴더 정보를 불러오는 중입니다",
                "Android 저장소 항목을 확인하는 중",
                "파일 정보를 불러오는 중",
                "폴더 내용을 확인하는 중입니다",
                "저장소 항목을 불러오는 중",
                "파일 목록을 확인하는 중입니다"
            ]
            return names.enumerated().map {
                RemoteTableRow(placeholderIndex: $0.offset, name: $0.element)
            }
        }
        return viewModel.filteredRemoteFiles
            .map(RemoteTableRow.init(file:))
            .sorted(using: remoteSortOrder)
    }

    private var displayedLocalFiles: [LocalFile] {
        viewModel.filteredLocalFiles.sorted(using: localSortOrder)
    }

    private var displayedRemoteFiles: [RemoteFile] {
        remoteTableRows.compactMap(\.file)
    }

    private var remoteTableSelection: Binding<Set<RemoteFile.ID>> {
        Binding(
            get: { viewModel.isLoadingRemoteFiles ? [] : viewModel.selectedRemoteFileIDs },
            set: { selection in
                guard !viewModel.isLoadingRemoteFiles else { return }
                viewModel.selectedRemoteFileIDs = selection
            }
        )
    }

    @ViewBuilder
    private func remoteFileRow(_ file: RemoteFile) -> some View {
        HStack {
            Image(systemName: file.isDirectory ? "folder" : "doc")
                .foregroundStyle(file.isDirectory ? .orange : .secondary)
            if renamingRemoteFileID == file.id {
                NativeInlineRenameField(
                    initialText: file.name,
                    onCommit: { name in
                        finishRemoteRename(file, name: name)
                    },
                    onCancel: {
                        cancelRemoteRename()
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 24)
                .zIndex(1)
            } else {
                Text(file.name)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                guard renamingRemoteFileID == nil else { return }
                handleRemoteClick(file)
            }
        )
        .contextMenu {
            Button("열기") {
                viewModel.selectedRemoteFileIDs = [file.id]
                viewModel.openRemoteFolder(file)
            }
            .disabled(!file.isDirectory)

            Button("이름 변경…") {
                beginRemoteRename(file)
            }
            .disabled(viewModel.isTransferQueueActive)

            Divider()
            Button("삭제", role: .destructive) {
                cancelRemoteRename()
                if !viewModel.selectedRemoteFileIDs.contains(file.id) {
                    viewModel.selectedRemoteFileIDs = [file.id]
                }
                viewModel.deleteSelectedRemoteFiles()
            }
            .disabled(viewModel.isTransferQueueActive)
        }
    }

    private func remoteSkeletonRow(name: String) -> some View {
        HStack(spacing: 10) {
            NativeSkeletonPulseView(cornerRadius: 4)
                .frame(width: 18, height: 18)
            Text(name)
                .hidden()
                .overlay {
                    NativeSkeletonPulseView(cornerRadius: 4)
                        .frame(height: 12)
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func remoteSkeletonMetadata(width: CGFloat) -> some View {
        NativeSkeletonPulseView(cornerRadius: 4)
            .frame(width: width, height: 12)
            .accessibilityHidden(true)
    }

    private func fileSizeText(size: UInt64, isDirectory: Bool) -> String {
        guard !isDirectory else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: size),
            countStyle: .file
        )
    }

    private func fileDateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private var statusBar: some View {
        HStack {
            if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
            } else if viewModel.isIndexingRemoteFiles {
                ProgressView()
                    .controlSize(.small)
            }
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
    }

    private func fileControls(
        searchText: Binding<String>,
        prompt: String
    ) -> some View {
        TextField(prompt, text: searchText)
            .textFieldStyle(.roundedBorder)
    }

    private func receiveFilesForUpload(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let collector = DroppedURLCollector()
        let group = DispatchGroup()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                collector.append(url)
            }
        }
        group.notify(queue: .main) {
            viewModel.upload(urls: collector.values)
        }
        return true
    }

    private func receiveFilesOnMac(from providers: [NSItemProvider]) -> Bool {
        let destinationDirectory = viewModel.localDirectory
        let model = viewModel
        let report: @Sendable (String, Error?) -> Void = { [weak model] name, error in
            DispatchQueue.main.async {
                model?.reportLocalDrop(name: name, error: error)
            }
        }
        var acceptedProvider = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                acceptedProvider = true
                provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    options: nil
                ) { item, error in
                    guard error == nil,
                          let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        report("파일", error ?? MTPError("드롭한 파일 위치를 읽을 수 없습니다."))
                        return
                    }
                    let result = LocalDropCopier.copy(url, to: destinationDirectory)
                    report(result.name, result.error)
                }
                continue
            }

            let typeIdentifier = [UTType.folder, UTType.data]
                .map(\.identifier)
                .first { provider.hasItemConformingToTypeIdentifier($0) }
            guard let typeIdentifier else { continue }
            acceptedProvider = true
            let suggestedName = provider.suggestedName ?? "파일"
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    report(
                        suggestedName,
                        error ?? MTPError("Android 파일을 다운로드할 수 없습니다.")
                    )
                    return
                }
                let result = LocalDropCopier.copy(url, to: destinationDirectory)
                report(result.name, result.error)
            }
        }
        return acceptedProvider
    }

    private var localUploadButtonTitle: String {
        let count = viewModel.selectedLocalFiles.count
        return count > 1 ? "선택한 \(count)개 업로드" : "선택 항목 업로드"
    }

    private var remoteDownloadButtonTitle: String {
        let count = viewModel.selectedRemoteFiles.count
        return count > 1 ? "선택한 \(count)개 다운로드…" : "선택 항목 다운로드…"
    }

    private func beginLocalRename(_ file: LocalFile) {
        guard !viewModel.isWorking else { return }
        viewModel.selectedLocalFileIDs = [file.id]
        renamingLocalFileID = file.id
        resetClickTracking()
    }

    private func finishLocalRename(_ file: LocalFile, name: String) {
        guard renamingLocalFileID == file.id else { return }
        renamingLocalFileID = nil
        viewModel.renameLocalFile(file, to: name)
    }

    private func cancelLocalRename() {
        renamingLocalFileID = nil
    }

    private func beginRemoteRename(_ file: RemoteFile) {
        guard viewModel.isConnected,
              !viewModel.isWorking,
              !viewModel.isTransferQueueActive else { return }
        viewModel.selectedRemoteFileIDs = [file.id]
        renamingRemoteFileID = file.id
        resetClickTracking()
    }

    private func finishRemoteRename(_ file: RemoteFile, name: String) {
        guard renamingRemoteFileID == file.id else { return }
        renamingRemoteFileID = nil
        viewModel.renameRemoteFile(file, to: name)
    }

    private func cancelRemoteRename() {
        renamingRemoteFileID = nil
    }

    private func handleLocalClick(_ file: LocalFile) {
        guard !isModifiedSelection else {
            resetClickTracking()
            return
        }
        viewModel.selectedLocalFileIDs = [file.id]
        if registerClick(on: .local(file.id)) {
            viewModel.openLocalFolder(file)
        }
    }

    private func handleRemoteClick(_ file: RemoteFile) {
        guard !viewModel.isWorking else {
            resetClickTracking()
            return
        }
        guard !isModifiedSelection else {
            resetClickTracking()
            return
        }
        viewModel.selectedRemoteFileIDs = [file.id]
        if registerClick(on: .remote(file.id)) {
            viewModel.openRemoteFolder(file)
        }
    }

    private var isModifiedSelection: Bool {
        !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
    }

    private func resetClickTracking() {
        lastClickTarget = nil
        lastClickDate = nil
    }

    private func registerClick(on target: ClickTarget) -> Bool {
        let now = Date()
        let isDoubleClick = lastClickTarget == target
            && now.timeIntervalSince(lastClickDate ?? .distantPast) <= NSEvent.doubleClickInterval

        if isDoubleClick {
            resetClickTracking()
        } else {
            lastClickTarget = target
            lastClickDate = now
        }
        return isDoubleClick
    }
}
