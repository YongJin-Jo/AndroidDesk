import AppKit
import SwiftUI

struct NativeTransferQueueView: NSViewRepresentable {
    let jobs: [TransferJob]
    let progressForJob: (UUID) -> Progress?
    let onCancel: (UUID) -> Void
    let onRetry: (UUID) -> Void
    let onCancelAll: () -> Void
    let onRetryFailed: () -> Void
    let onClearFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            jobs: jobs,
            progressForJob: progressForJob,
            onCancel: onCancel,
            onRetry: onRetry,
            onCancelAll: onCancelAll,
            onRetryFailed: onRetryFailed,
            onClearFinished: onClearFinished
        )
    }

    func makeNSView(context: Context) -> TransferQueueContainerView {
        TransferQueueContainerView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: TransferQueueContainerView, context: Context) {
        context.coordinator.jobs = jobs
        context.coordinator.progressForJob = progressForJob
        context.coordinator.onCancel = onCancel
        context.coordinator.onRetry = onRetry
        context.coordinator.onCancelAll = onCancelAll
        context.coordinator.onRetryFailed = onRetryFailed
        context.coordinator.onClearFinished = onClearFinished
        nsView.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var jobs: [TransferJob]
        var progressForJob: (UUID) -> Progress?
        var onCancel: (UUID) -> Void
        var onRetry: (UUID) -> Void
        var onCancelAll: () -> Void
        var onRetryFailed: () -> Void
        var onClearFinished: () -> Void

        init(
            jobs: [TransferJob],
            progressForJob: @escaping (UUID) -> Progress?,
            onCancel: @escaping (UUID) -> Void,
            onRetry: @escaping (UUID) -> Void,
            onCancelAll: @escaping () -> Void,
            onRetryFailed: @escaping () -> Void,
            onClearFinished: @escaping () -> Void
        ) {
            self.jobs = jobs
            self.progressForJob = progressForJob
            self.onCancel = onCancel
            self.onRetry = onRetry
            self.onCancelAll = onCancelAll
            self.onRetryFailed = onRetryFailed
            self.onClearFinished = onClearFinished
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            jobs.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard jobs.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("TransferQueueCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? TransferQueueCellView ?? TransferQueueCellView()
            cell.identifier = identifier
            cell.configure(
                job: jobs[row],
                progress: progressForJob(jobs[row].id),
                target: self
            )
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            52
        }

        @objc func cancelJob(_ sender: TransferJobButton) {
            guard let jobID = sender.jobID else { return }
            onCancel(jobID)
        }

        @objc func retryJob(_ sender: TransferJobButton) {
            guard let jobID = sender.jobID else { return }
            onRetry(jobID)
        }

        @objc func cancelAllJobs() {
            onCancelAll()
        }

        @objc func retryFailedJobs() {
            onRetryFailed()
        }

        @objc func clearFinishedJobs() {
            onClearFinished()
        }
    }

    @MainActor
    final class TransferQueueContainerView: NSView {
        private let coordinator: Coordinator
        private let tableView = NSTableView()
        private let cancelAllButton = NSButton(title: "모두 취소", target: nil, action: nil)
        private let retryFailedButton = NSButton(title: "실패·취소 재시도", target: nil, action: nil)
        private let clearButton = NSButton(title: "종료 항목 지우기", target: nil, action: nil)

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)

            let title = NSTextField(labelWithString: "전송 대기열")
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

            for button in [cancelAllButton, retryFailedButton, clearButton] {
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.target = coordinator
            }
            cancelAllButton.action = #selector(Coordinator.cancelAllJobs)
            retryFailedButton.action = #selector(Coordinator.retryFailedJobs)
            clearButton.action = #selector(Coordinator.clearFinishedJobs)

            let header = NSStackView(views: [title, NSView(), cancelAllButton, retryFailedButton, clearButton])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 8
            header.translatesAutoresizingMaskIntoConstraints = false

            tableView.headerView = nil
            tableView.rowHeight = 52
            tableView.intercellSpacing = NSSize(width: 0, height: 1)
            tableView.selectionHighlightStyle = .none
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.dataSource = coordinator
            tableView.delegate = coordinator
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Transfer"))
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)

            let scrollView = NSScrollView()
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false

            addSubview(header)
            addSubview(scrollView)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
            ])
        }

        required init?(coder: NSCoder) {
            nil
        }

        func reloadData() {
            tableView.reloadData()
            cancelAllButton.isEnabled = coordinator.jobs.contains { $0.canCancel }
            retryFailedButton.isEnabled = coordinator.jobs.contains { $0.canRetry }
            clearButton.isEnabled = coordinator.jobs.contains { !$0.canCancel }
        }
    }

    @MainActor
    final class TransferJobButton: NSButton {
        var jobID: UUID?
    }

    @MainActor
    final class TransferQueueCellView: NSTableCellView {
        private let directionImage = NSImageView()
        private let nameField = NSTextField(labelWithString: "")
        private let detailField = NSTextField(labelWithString: "")
        private let progressIndicator = NSProgressIndicator()
        private let actionButton = TransferJobButton()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            directionImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            directionImage.setContentHuggingPriority(.required, for: .horizontal)
            nameField.lineBreakMode = .byTruncatingMiddle
            nameField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            detailField.lineBreakMode = .byTruncatingTail
            detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detailField.textColor = .secondaryLabelColor

            progressIndicator.style = .bar
            progressIndicator.controlSize = .small
            progressIndicator.minValue = 0
            progressIndicator.maxValue = 1

            actionButton.bezelStyle = .rounded
            actionButton.controlSize = .small
            actionButton.setContentHuggingPriority(.required, for: .horizontal)

            let labels = NSStackView(views: [nameField, detailField, progressIndicator])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 2

            let row = NSStackView(views: [directionImage, labels, actionButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)

            NSLayoutConstraint.activate([
                directionImage.widthAnchor.constraint(equalToConstant: 20),
                progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
            ])
        }

        required init?(coder: NSCoder) {
            nil
        }

        func configure(job: TransferJob, progress: Progress?, target: Coordinator) {
            directionImage.image = NSImage(
                systemSymbolName: job.direction == .upload ? "arrow.up.circle" : "arrow.down.circle",
                accessibilityDescription: job.direction.rawValue
            )
            nameField.stringValue = job.name
            detailField.stringValue = detail(for: job)
            detailField.toolTip = job.errorMessage

            if job.state == .transferring, job.totalBytes == 0 {
                progressIndicator.observedProgress = nil
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
            } else if let progress, job.state == .transferring {
                progressIndicator.stopAnimation(nil)
                progressIndicator.isIndeterminate = false
                progressIndicator.observedProgress = progress
            } else {
                progressIndicator.observedProgress = nil
                progressIndicator.stopAnimation(nil)
                progressIndicator.isIndeterminate = false
                progressIndicator.doubleValue = job.fractionCompleted ?? (job.state == .completed ? 1 : 0)
            }

            actionButton.jobID = job.id
            actionButton.target = target
            if job.canCancel {
                actionButton.title = "취소"
                actionButton.action = #selector(Coordinator.cancelJob(_:))
                actionButton.isHidden = false
            } else if job.canRetry {
                actionButton.title = "재시도"
                actionButton.action = #selector(Coordinator.retryJob(_:))
                actionButton.isHidden = false
            } else {
                actionButton.isHidden = true
            }
        }

        private func detail(for job: TransferJob) -> String {
            var parts = [job.direction.rawValue, job.state.rawValue]
            if job.bytesTransferred > 0 || job.totalBytes > 0 {
                let transferred = ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: job.bytesTransferred),
                    countStyle: .file
                )
                let total = ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: job.totalBytes),
                    countStyle: .file
                )
                parts.append("\(transferred) / \(total)")
            }
            if job.bytesPerSecond > 0, job.state == .transferring {
                let rate = ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: job.bytesPerSecond),
                    countStyle: .file
                )
                parts.append("\(rate)/s")
            }
            if let errorMessage = job.errorMessage {
                parts.append(errorMessage)
            }
            return parts.joined(separator: " · ")
        }
    }
}
