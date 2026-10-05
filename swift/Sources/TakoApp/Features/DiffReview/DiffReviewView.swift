/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// In-terminal read-only diff review pane container view (D3).
///
/// Features a file list with status badges, line-by-line unified diff inspection,
/// local comment collection, and a Send button to batch-deliver feedback to a target pane.
/// Invariant: Tako never commits, pushes, or edits files from this view.
struct DiffReviewView: View {
    let session: DiffReviewSession
    let surfaceView: Tako.SurfaceView
    var theme: TerminalTheme?

    @ObservedObject private var store = DiffReviewStore.shared
    @State private var commentInputLine: Int? = nil
    @State private var commentInputText: String = ""
    @State private var feedbackSentNotice: String? = nil

    init(session: DiffReviewSession, surfaceView: Tako.SurfaceView, theme: TerminalTheme? = nil) {
        self.session = session
        self.surfaceView = surfaceView
        self.theme = theme ?? (NSApp.delegate as? AppDelegate)?.tako.config.theme
    }

    private var currentSession: DiffReviewSession {
        store.session(for: session.paneId) ?? session
    }

    private var selectedFilePath: String? {
        currentSession.selectedFile ?? currentSession.files.first?.path
    }

    private var selectedFileDetail: DiffFileDetail? {
        guard let path = selectedFilePath else { return nil }
        return GitDiffHelper.getFileDiff(
            worktreePath: currentSession.worktreePath,
            baseBranch: currentSession.baseBranch,
            file: path
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .background(Color.white.opacity(0.15))

            if let notice = feedbackSentNotice {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(notice)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Dismiss") {
                        feedbackSentNotice = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.15))
            }

            // Split: Left File List, Right Diff Viewer
            HSplitView {
                // File List Sidebar
                fileListSidebar
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)

                // Unified Diff Viewer
                diffContentView
                    .frame(minWidth: 350, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: NSColor(cgColor: theme?.background ?? CGColor(gray: 0.1, alpha: 1.0)) ?? .windowBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 6)
        .onExitCommand {
            dismiss()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Type badge
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .bold))
                Text("DIFF REVIEW")
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.2))
            .foregroundColor(.blue)
            .cornerRadius(4)

            // Task / Branch info
            Text(currentSession.taskName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            Text("(\(currentSession.baseBranch) ... HEAD)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            // Files count and stats
            let totalAdds = currentSession.files.reduce(0) { $0 + $1.additions }
            let totalDels = currentSession.files.reduce(0) { $0 + $1.deletions }
            Text("\(currentSession.files.count) file(s)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if totalAdds > 0 || totalDels > 0 {
                HStack(spacing: 4) {
                    Text("+\(totalAdds)").foregroundColor(.green)
                    Text("-\(totalDels)").foregroundColor(.red)
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }

            Spacer()

            // Comments badge
            let commentCount = currentSession.comments.count
            if commentCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10))
                    Text("\(commentCount)")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.25))
                .foregroundColor(.orange)
                .cornerRadius(10)
            }

            // Send Feedback Button
            Button(action: {
                sendFeedback()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 10))
                    Text("Send Feedback (\(commentCount))")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(commentCount > 0 ? Color.accentColor : Color.gray.opacity(0.3))
                .foregroundColor(.white)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .disabled(commentCount == 0)
            .help("Send batched comments to agent pane")

            // Close button
            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Review (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.25))
    }

    // MARK: - File List Sidebar

    private var fileListSidebar: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(currentSession.files) { file in
                    let isSelected = file.path == selectedFilePath
                    let commentsForFile = currentSession.comments.filter { $0.file == file.path }

                    Button(action: {
                        store.selectFile(paneId: currentSession.paneId, file: file.path)
                    }) {
                        HStack(spacing: 6) {
                            // Status badge
                            Text(file.status.badgeLetter)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(color(for: file.status))
                                .frame(width: 14)

                            // Path
                            Text(file.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(isSelected ? .white : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            // Comments count on this file
                            if !commentsForFile.isEmpty {
                                Text("\(commentsForFile.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .background(Color.orange.opacity(0.3))
                                    .foregroundColor(.orange)
                                    .cornerRadius(6)
                            }

                            // Stats
                            if file.additions > 0 || file.deletions > 0 {
                                HStack(spacing: 2) {
                                    if file.additions > 0 {
                                        Text("+\(file.additions)").foregroundColor(.green)
                                    }
                                    if file.deletions > 0 {
                                        Text("-\(file.deletions)").foregroundColor(.red)
                                    }
                                }
                                .font(.system(size: 9, design: .monospaced))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isSelected ? Color.accentColor.opacity(0.4) : Color.clear)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .background(Color.black.opacity(0.15))
    }

    // MARK: - Diff Content View

    private var diffContentView: some View {
        Group {
            if let detail = selectedFileDetail {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(detail.hunks) { hunk in
                            // Hunk header
                            Text(hunk.header)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.cyan.opacity(0.1))

                            ForEach(hunk.lines) { line in
                                diffLineRow(line: line, file: detail.entry.path)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select a file to inspect diff")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .background(Color.black.opacity(0.25))
    }

    // MARK: - Diff Line Row

    @ViewBuilder
    private func diffLineRow(line: DiffLine, file: String) -> some View {
        let lineNum = line.newLineNum ?? line.oldLineNum ?? 0
        let commentsOnLine = currentSession.comments.filter { $0.file == file && $0.line == lineNum && lineNum > 0 }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                // Line numbers
                HStack(spacing: 4) {
                    Text(line.oldLineNum.map(String.init) ?? "")
                        .frame(width: 32, alignment: .trailing)
                    Text(line.newLineNum.map(String.init) ?? "")
                        .frame(width: 32, alignment: .trailing)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 4)

                // Prefix sign
                let prefix: String = switch line.type {
                case .addition: "+"
                case .deletion: "-"
                case .context: " "
                case .hunkHeader: "@"
                }

                Text(prefix)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(lineColor(for: line.type))
                    .frame(width: 14)

                // Content
                Text(line.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(lineColor(for: line.type))
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Add comment button on hover / click
                if lineNum > 0 {
                    Button(action: {
                        if commentInputLine == lineNum {
                            commentInputLine = nil
                        } else {
                            commentInputLine = lineNum
                            commentInputText = ""
                        }
                    }) {
                        Image(systemName: "plus.bubble")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            }
            .padding(.vertical, 1)
            .background(lineBgColor(for: line.type))

            // Inline Comments List on this line
            ForEach(commentsOnLine) { comment in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                    Text(comment.text)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                    Spacer()
                    Button(action: {
                        store.removeComment(paneId: currentSession.paneId, commentId: comment.id)
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(4)
                .padding(.leading, 74)
                .padding(.trailing, 8)
                .padding(.vertical, 2)
            }

            // Inline Comment Composer Box
            if commentInputLine == lineNum && lineNum > 0 {
                HStack(spacing: 6) {
                    TextField("Add review comment for line \(lineNum)...", text: $commentInputText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit {
                            submitComment(file: file, line: lineNum)
                        }

                    Button("Add") {
                        submitComment(file: file, line: lineNum)
                    }
                    .font(.system(size: 10, weight: .semibold))

                    Button("Cancel") {
                        commentInputLine = nil
                        commentInputText = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                .padding(.leading, 74)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Actions

    private func submitComment(file: String, line: Int) {
        guard !commentInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try? store.addComment(paneId: currentSession.paneId, file: file, line: line, text: commentInputText)
        commentInputLine = nil
        commentInputText = ""
    }

    private func sendFeedback() {
        let allSurfaces = TerminalController.all.flatMap(\.surfaceTree)
        let targetSurface = allSurfaces.first(where: { $0.id == currentSession.targetPaneId }) ?? surfaceView
        do {
            let (_, targetId) = try store.sendFeedback(
                paneId: currentSession.paneId,
                targetSurface: targetSurface
            )
            feedbackSentNotice = "Sent feedback to pane \(targetId)"
        } catch {
            feedbackSentNotice = "Failed to send: \(error.localizedDescription)"
        }
    }

    private func dismiss() {
        store.closeReview(paneId: currentSession.paneId)
        DispatchQueue.main.async {
            self.surfaceView.window?.makeFirstResponder(self.surfaceView)
        }
    }

    // MARK: - Color Helpers

    private func color(for status: DiffFileStatus) -> Color {
        switch status {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .purple
        }
    }

    private func lineColor(for type: DiffLineType) -> Color {
        switch type {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .primary
        case .hunkHeader: return .cyan
        }
    }

    private func lineBgColor(for type: DiffLineType) -> Color {
        switch type {
        case .addition: return Color.green.opacity(0.12)
        case .deletion: return Color.red.opacity(0.12)
        case .context, .hunkHeader: return Color.clear
        }
    }
}
