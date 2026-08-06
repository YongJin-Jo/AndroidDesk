import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
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
            .disabled(viewModel.isWorking)
        }
        .padding()
    }

    private var localPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Mac의 파일", systemImage: "laptopcomputer")
                    .font(.headline)
                Spacer()
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
                sortOption: $viewModel.localSortOption,
                prompt: "Mac 파일 검색"
            )

            Table(viewModel.filteredLocalFiles, selection: localSelection) {
                TableColumn("이름") { file in
                    HStack {
                        Image(systemName: file.isDirectory ? "folder" : "doc")
                            .foregroundStyle(file.isDirectory ? .orange : .secondary)
                        Text(file.name)
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
                            handleLocalClick(file)
                        }
                    )
                    .onDrag {
                        NSItemProvider(object: file.url as NSURL)
                    }
                }
                .width(min: 100, ideal: 350, max: .infinity)
            }
            .tableColumnHeaders(.hidden)
            .overlay {
                if viewModel.filteredLocalFiles.isEmpty {
                    ContentUnavailableView(
                        viewModel.localSearchText.isEmpty ? "표시할 파일이 없습니다" : "검색 결과가 없습니다",
                        systemImage: "folder",
                        description: Text("다른 폴더를 선택하거나 접근 권한을 확인하세요.")
                    )
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                receiveFiles(from: providers)
            }
            .onKeyPress(.return) {
                if let file = viewModel.selectedLocalFile {
                    viewModel.openLocalFolder(file)
                }
                return .handled
            }

            HStack {
                Button("선택 항목 업로드") { viewModel.uploadSelectedLocalFile() }
                    .disabled(viewModel.selectedLocalFile == nil || !viewModel.isConnected || viewModel.isWorking)
                Spacer()
                Button("파일 선택…") { isImporting = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isWorking)
            }

            Text("폴더를 두 번 클릭해 이동하거나, 파일·폴더를 오른쪽 Android 영역으로 끌어놓을 수 있습니다.")
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
                Button("목록 갱신") { viewModel.loadRemoteFiles(forceRefresh: true) }
                    .disabled(!viewModel.isConnected || viewModel.isWorking)
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
                sortOption: $viewModel.remoteSortOption,
                prompt: "Android 파일 검색"
            )

            Table(viewModel.filteredRemoteFiles, selection: remoteSelection) {
                TableColumn("이름") { file in
                    HStack {
                        Image(systemName: file.isDirectory ? "folder" : "doc")
                            .foregroundStyle(file.isDirectory ? .orange : .secondary)
                        Text(file.name)
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
                            handleRemoteClick(file)
                        }
                    )
                }
                .width(min: 100, ideal: 390, max: .infinity)
            }
            .tableColumnHeaders(.hidden)
            .overlay {
                if isRemoteDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay {
                            Label("여기에 놓아 Android로 업로드", systemImage: "arrow.down.doc")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(4)
                } else if viewModel.filteredRemoteFiles.isEmpty && !viewModel.isWorking {
                    ContentUnavailableView(
                        viewModel.remoteSearchText.isEmpty ? "표시할 파일이 없습니다" : "검색 결과가 없습니다",
                        systemImage: "folder",
                        description: Text("목록 갱신을 눌러 Android 폴더를 읽으세요.")
                    )
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isRemoteDropTargeted) { providers in
                receiveFiles(from: providers)
            }
            .onKeyPress(.return) {
                if let file = viewModel.selectedRemoteFile {
                    viewModel.openRemoteFolder(file)
                }
                return .handled
            }

            HStack {
                Button("선택 항목 다운로드…") { viewModel.downloadSelectedFile() }
                    .disabled(viewModel.selectedRemoteFile == nil || viewModel.isWorking)
                Spacer()
                Button("여기로 업로드") { isImporting = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.isConnected || viewModel.isWorking)
            }
        }
        .padding()
    }

    private var statusBar: some View {
        HStack {
            if viewModel.isWorking {
                if let transferProgress = viewModel.transferProgress {
                    ProgressView(value: transferProgress)
                        .frame(width: 110)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if viewModel.isIndexingRemoteFiles {
                ProgressView()
                    .controlSize(.small)
            }
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            if viewModel.transferProgress != nil {
                Text(transferDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
    }

    private var transferDescription: String {
        let rate = ByteCountFormatter.string(
            fromByteCount: Int64(viewModel.transferRateBytesPerSecond),
            countStyle: .file
        )
        guard viewModel.transferTotalBytes > 0 else { return "\(rate)/s" }
        let transferred = ByteCountFormatter.string(
            fromByteCount: Int64(viewModel.transferBytes),
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(viewModel.transferTotalBytes),
            countStyle: .file
        )
        return "\(transferred) / \(total) · \(rate)/s"
    }

    private func fileControls(
        searchText: Binding<String>,
        sortOption: Binding<FileSortOption>,
        prompt: String
    ) -> some View {
        HStack(spacing: 8) {
            TextField(prompt, text: searchText)
                .textFieldStyle(.roundedBorder)
            Picker("정렬", selection: sortOption) {
                ForEach(FileSortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 90)
        }
    }

    private func receiveFiles(from providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { viewModel.upload(urls: [url]) }
            }
        }
        return !providers.isEmpty
    }

    private var localSelection: Binding<LocalFile.ID?> {
        Binding(
            get: { viewModel.selectedLocalFile?.id },
            set: { id in
                viewModel.selectedLocalFile = viewModel.filteredLocalFiles.first { $0.id == id }
            }
        )
    }

    private var remoteSelection: Binding<RemoteFile.ID?> {
        Binding(
            get: { viewModel.selectedRemoteFile?.id },
            set: { id in
                viewModel.selectedRemoteFile = viewModel.filteredRemoteFiles.first { $0.id == id }
            }
        )
    }

    private func handleLocalClick(_ file: LocalFile) {
        viewModel.selectedLocalFile = file
        if registerClick(on: .local(file.id)) {
            viewModel.openLocalFolder(file)
        }
    }

    private func handleRemoteClick(_ file: RemoteFile) {
        viewModel.selectedRemoteFile = file
        if registerClick(on: .remote(file.id)) {
            viewModel.openRemoteFolder(file)
        }
    }

    private func registerClick(on target: ClickTarget) -> Bool {
        let now = Date()
        let isDoubleClick = lastClickTarget == target
            && now.timeIntervalSince(lastClickDate ?? .distantPast) <= NSEvent.doubleClickInterval

        if isDoubleClick {
            lastClickTarget = nil
            lastClickDate = nil
        } else {
            lastClickTarget = target
            lastClickDate = now
        }
        return isDoubleClick
    }
}
