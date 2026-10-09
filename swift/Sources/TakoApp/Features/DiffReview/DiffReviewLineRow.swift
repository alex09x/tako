/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// A single line row in the diff viewer, including inline comment badges and composer.
struct DiffReviewLineRow: View {
    let line: DiffLine
    let file: String
    let paneId: UUID
    let comments: [DiffReviewComment]
    @Binding var commentInputLine: Int?
    @Binding var commentInputText: String
    let onSubmitComment: (String, Int) -> Void
    let onRemoveComment: (UUID) -> Void

    var body: some View {
        let lineNum = line.newLineNum ?? line.oldLineNum ?? 0
        let commentsOnLine = comments.filter { $0.file == file && $0.line == lineNum && lineNum > 0 }

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
                    .accessibilityIdentifier("AddCommentButton_Line\(lineNum)")
                    .accessibilityLabel("Add comment line \(lineNum)")
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
                        onRemoveComment(comment.id)
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("RemoveCommentButton")
                    .accessibilityLabel("Remove comment")
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
                        .accessibilityIdentifier("CommentTextField_Line\(lineNum)")
                        .onSubmit {
                            onSubmitComment(file, lineNum)
                        }

                    Button("Add") {
                        onSubmitComment(file, lineNum)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .disabled(commentInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("SubmitCommentButton_Line\(lineNum)")
                    .accessibilityAction {
                        onSubmitComment(file, lineNum)
                    }

                    Button("Cancel") {
                        commentInputLine = nil
                        commentInputText = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("CancelCommentButton_Line\(lineNum)")
                }
                .padding(.leading, 74)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
            }
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
