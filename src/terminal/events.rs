/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

/// A frame in the hierarchical context stack (OSC 3008, C5).
/// Represents where pane output comes from (host, container, SSH, elevated shell).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextFrame {
    pub kind: String,
    pub name: String,
    pub tint: Option<String>,
    pub is_elevated: bool,
}

/// Host-visible side effects the byte stream produced: things the embedding
/// application must react to (ring the bell, sync the clipboard, ...).
/// Drained via [`Terminal::take_events`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalEvent {
    Bell,
    TitleChanged(String),
    /// OSC 52 set: decoded clipboard text the host should store.
    ClipboardSet(String),
    /// OSC 52 query: the host should reply with its clipboard contents.
    ClipboardQuery,
    /// OSC 9 / OSC 777;notify desktop notification.
    Notification {
        title: String,
        body: String,
    },
    /// OSC 99 structured desktop notification.
    StructuredNotification {
        id: Option<String>,
        title: String,
        body: String,
        app_name: Option<String>,
        urgency: u8,
        actions: Vec<String>,
        report_activation: bool,
        focus: bool,
        report_close: bool,
        timeout_ms: Option<u64>,
        only_when_unfocused: bool,
    },
    /// OSC 99 close notification request.
    NotificationClose {
        id: String,
        report_close: bool,
    },
    /// OSC 7: working-directory URL report.
    PwdChanged(String),
    /// ConEmu OSC 9;4 progress report (state 0=remove,1=set,2=error,
    /// 3=indeterminate,4=pause); `value` is absent when not sent.
    Progress {
        state: u8,
        value: Option<u8>,
    },
    /// OSC 133;C -- the shell handed control to a command. A host can start
    /// timing here, and give the command its start time with `id` (absent
    /// on the alternate screen, where commands are not recorded).
    CommandStart {
        id: Option<u64>,
    },
    /// OSC 133;D -- the command finished. `exit_code` is present when the
    /// shell reported one (`OSC 133;D;<code>`).
    CommandEnd {
        exit_code: Option<i32>,
    },
    /// OSC 133;A / OSC 133;P prompt mark: shell is at a prompt, ready for input.
    PromptMark,
    /// In-band escape sequence status report (OSC 1337;SetStatus=... or OSC 9;5;...).
    StatusSet {
        status: String,
        text: Option<String>,
    },
    /// In-band escape sequence clearing explicit status (OSC 1337;ClearStatus or OSC 9;5;clear).
    StatusClear,
    /// OSC 3008 context frame pushed onto the stack (C5).
    ContextPush(ContextFrame),
    /// OSC 3008 top context frame popped from the stack (C5).
    ContextPop,
    /// OSC 3008 context stack cleared (C5).
    ContextClear,
}
