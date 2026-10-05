import SwiftUI
import TakoKit

struct TerminalCommandPaletteView: View {
    /// The surface that this command palette represents.
    let surfaceView: Tako.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var takoConfig: Tako.Config

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: takoConfig.backgroundColor,
                            options: commandOptions
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the command palette disappears we need to send focus back to the
            // surface view we were overlaid on top of. There's probably a better way
            // to handle the first responder state here but I don't know it.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// All commands available in the command palette.
    private var commandOptions: [CommandOption] {
        var options: [CommandOption] = []

        // Sort them. We replace ":" with a character that sorts before space
        // so that "Foo:" sorts before "Foo Bar:". Use sortKey as a tie-breaker
        // for stable ordering when titles are equal.
        options.append(contentsOf: (jumpOptions + terminalOptions + commandActionOptions + projectActionOptions).sorted { a, b in
            let aNormalized = a.title.replacingOccurrences(of: ":", with: "\t")
            let bNormalized = b.title.replacingOccurrences(of: ":", with: "\t")
            let comparison = aNormalized.localizedCaseInsensitiveCompare(bNormalized)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            // Tie-breaker: use sortKey if both have one
            if let aSortKey = a.sortKey, let bSortKey = b.sortKey {
                return aSortKey < bSortKey
            }
            return false
        })
        return options
    }

    @State private var commandActionsPage: Int = 1
    private static let commandsPerPage: Int = 50

    /// Actions on recorded commands (copy command, copy output, re-run, etc.).
    /// Paginates history in batches of 50 to avoid materializing tens of thousands of rows on the main thread.
    private var commandActionOptions: [CommandOption] {
        let commands = surfaceView.recordedCommands()
        guard !commands.isEmpty else { return [] }

        let newestId = surfaceView.activeStickyCommandHeader?.commandId ?? commands.last?.id

        let totalCommands = commands.count
        let visibleCount = min(totalCommands, commandActionsPage * Self.commandsPerPage)
        let visibleCommands = Array(commands.suffix(visibleCount).reversed())

        var options: [CommandOption] = []
        for cmd in visibleCommands {
            let isCurrent = (cmd.id == newestId)
            let rawInput = cmd.input?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasInput = !(rawInput?.isEmpty ?? true)
            let trimmedCmd = hasInput ? rawInput! : "Command #\(cmd.id)"
            let badgeText = isCurrent ? "Active Command" : "Command"
            let outputAvailable = surfaceView.commandOutput(for: cmd.id, epoch: cmd.epoch) != nil

            if hasInput {
                let copyTitle = cmd.inputTruncated ? "Command: Copy Command (Truncated)" : "Command: Copy Command"
                options.append(CommandOption(
                    title: copyTitle,
                    subtitle: trimmedCmd,
                    leadingIcon: "doc.on.doc",
                    badge: badgeText,
                    sortKey: AnySortKey(cmd.id * 10 + 1)
                ) {
                    surfaceView.copyCommand(id: cmd.id, epoch: cmd.epoch)
                })
            }

            if outputAvailable {
                options.append(CommandOption(
                    title: "Command: Copy Output",
                    subtitle: trimmedCmd,
                    leadingIcon: "doc.text",
                    badge: badgeText,
                    sortKey: AnySortKey(cmd.id * 10 + 2)
                ) {
                    surfaceView.copyOutput(id: cmd.id, epoch: cmd.epoch)
                })
            }

            if hasInput && outputAvailable {
                let copyMdTitle = cmd.inputTruncated ? "Command: Copy Both as Markdown (Truncated Input)" : "Command: Copy Both as Markdown"
                options.append(CommandOption(
                    title: copyMdTitle,
                    subtitle: trimmedCmd,
                    leadingIcon: "text.quote",
                    badge: badgeText,
                    sortKey: AnySortKey(cmd.id * 10 + 3)
                ) {
                    surfaceView.copyBothAsMarkdown(id: cmd.id, epoch: cmd.epoch)
                })
            }

            if hasInput && !cmd.inputTruncated && surfaceView.isAtShellPrompt {
                options.append(CommandOption(
                    title: "Command: Re-run in This Pane",
                    subtitle: trimmedCmd,
                    leadingIcon: "arrow.clockwise",
                    badge: badgeText,
                    sortKey: AnySortKey(cmd.id * 10 + 4)
                ) {
                    surfaceView.rerunCommand(id: cmd.id, epoch: cmd.epoch)
                })
            }

            if outputAvailable {
                options.append(CommandOption(
                    title: "Command: Send Output to Another Pane",
                    subtitle: trimmedCmd,
                    leadingIcon: "rectangle.split.2x1",
                    badge: badgeText,
                    sortKey: AnySortKey(cmd.id * 10 + 5)
                ) {
                    surfaceView.sendOutputToAnotherPane(id: cmd.id, epoch: cmd.epoch)
                })

                options.append(CommandOption(
                    title: "Command: Save Output to File",
                    subtitle: trimmedCmd,
                    leadingIcon: "square.and.arrow.down",
                    badge: badgeText,
                    sortKey: AnySortKey(cmd.id * 10 + 6)
                ) {
                    surfaceView.saveOutputToFile(id: cmd.id, epoch: cmd.epoch)
                })
            }

            if let cwd = cmd.cwd {
                let dirDisplay = cwd.hasPrefix("file://") ? (URL(string: cwd)?.path ?? cwd) : cwd
                let subtitle = "\(trimmedCmd) (\(dirDisplay))"
                options.append(CommandOption(
                    title: "Command: Open Working Directory",
                    subtitle: subtitle,
                    leadingIcon: "folder",
                    badge: badgeText,
                    sortKey: AnySortKey(cmd.id * 10 + 7)
                ) {
                    surfaceView.openWorkingDirectory(id: cmd.id, epoch: cmd.epoch)
                })
            }
        }

        if totalCommands > visibleCount {
            let remaining = totalCommands - visibleCount
            options.append(CommandOption(
                title: "Command: Show Older Commands (\(remaining) remaining)...",
                subtitle: "Load 50 more historical commands into palette",
                leadingIcon: "ellipsis.circle",
                badge: "History",
                sortKey: AnySortKey(UInt64.max),
                dismissesOnAction: false
            ) {
                commandActionsPage += 1
            })
        }

        return options
    }

    /// Custom commands from the command-palette-entry configuration.
    private var terminalOptions: [CommandOption] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        return appDelegate.tako.config.commandPaletteEntries
            .filter(\.isSupported)
            .map { c in
                let symbols = appDelegate.tako.config.keyboardShortcut(for: c.action)?.keyList
                return CommandOption(
                    title: c.title,
                    description: c.description,
                    symbols: symbols
                ) {
                    onAction(c.action)
                }
            }
    }

    /// Commands for jumping to other terminal surfaces.
    private var jumpOptions: [CommandOption] {
        TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }

            let color = (window as? TerminalWindow)?.tabColor
            let displayColor = color != TerminalTabColor.none ? color : nil

            return controller.surfaceTree.map { surface in
                let terminalTitle = surface.title.isEmpty ? window.title : surface.title
                let displayTitle: String
                if let override = controller.titleOverride, !override.isEmpty {
                    displayTitle = override
                } else if !terminalTitle.isEmpty {
                    displayTitle = terminalTitle
                } else {
                    displayTitle = "Untitled"
                }
                let pwd = surface.pwd?.abbreviatedPath
                let subtitle: String? = if let pwd, !displayTitle.contains(pwd) {
                    pwd
                } else {
                    nil
                }

                return CommandOption(
                    title: "Focus: \(displayTitle)",
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor?.displayColor.map { Color($0) },
                    sortKey: AnySortKey(ObjectIdentifier(surface))
                ) {
                    NotificationCenter.default.post(
                        name: Tako.Notification.takoPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }

    /// Project-local actions defined in the project's action file (C3).
    /// Only appears when the current pane is inside a project containing an action file.
    private var projectActionOptions: [CommandOption] {
        guard let discovered = ProjectActionDiscovery.find(for: surfaceView) else {
            return []
        }
        let projectName = discovered.file.name ?? (discovered.projectRoot as NSString).lastPathComponent
        return discovered.file.actions.map { action in
            let cmdStr = action.effectiveCommand.joined(separator: " ")
            let subtitle = cmdStr.isEmpty ? action.description : cmdStr
            return CommandOption(
                title: "\(projectName): \(action.title)",
                subtitle: subtitle,
                description: action.description,
                leadingIcon: "play.circle.fill",
                leadingColor: .orange,
                badge: "Project Action",
                action: {
                    ProjectActionManager.shared.trigger(action, project: discovered, from: surfaceView)
                }
            )
        }
    }
}

/// This is done to ensure that the given view is in the responder chain.
private struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
