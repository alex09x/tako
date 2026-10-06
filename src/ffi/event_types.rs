/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::terminal::TerminalEvent;

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiContextFrame {
    pub kind: String,
    pub name: String,
    pub tint: Option<String>,
    pub is_elevated: bool,
}

impl From<crate::terminal::ContextFrame> for FfiContextFrame {
    fn from(f: crate::terminal::ContextFrame) -> Self {
        Self {
            kind: f.kind,
            name: f.name,
            tint: f.tint,
            is_elevated: f.is_elevated,
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, PartialEq, Eq)]
pub enum FfiEvent {
    Bell,
    TitleChanged {
        title: String,
    },
    ClipboardSet {
        text: String,
    },
    ClipboardQuery,
    Notification {
        title: String,
        body: String,
    },
    PwdChanged {
        url: String,
    },
    Progress {
        state: u8,
        value: Option<u8>,
    },
    CommandStart {
        id: Option<u64>,
    },
    CommandEnd {
        exit_code: Option<i32>,
    },
    PromptMark,
    StatusSet {
        status: String,
        text: Option<String>,
    },
    StatusClear,
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
    NotificationClose {
        id: String,
        report_close: bool,
    },
    ContextPush {
        frame: FfiContextFrame,
    },
    ContextPop,
    ContextClear,
}

impl From<TerminalEvent> for FfiEvent {
    fn from(e: TerminalEvent) -> Self {
        match e {
            TerminalEvent::Bell => FfiEvent::Bell,
            TerminalEvent::TitleChanged(title) => FfiEvent::TitleChanged { title },
            TerminalEvent::ClipboardSet(text) => FfiEvent::ClipboardSet { text },
            TerminalEvent::ClipboardQuery => FfiEvent::ClipboardQuery,
            TerminalEvent::Notification { title, body } => FfiEvent::Notification { title, body },
            TerminalEvent::PwdChanged(url) => FfiEvent::PwdChanged { url },
            TerminalEvent::Progress { state, value } => FfiEvent::Progress { state, value },
            TerminalEvent::CommandStart { id } => FfiEvent::CommandStart { id },
            TerminalEvent::CommandEnd { exit_code } => FfiEvent::CommandEnd { exit_code },
            TerminalEvent::PromptMark => FfiEvent::PromptMark,
            TerminalEvent::StatusSet { status, text } => FfiEvent::StatusSet { status, text },
            TerminalEvent::StatusClear => FfiEvent::StatusClear,
            TerminalEvent::StructuredNotification {
                id,
                title,
                body,
                app_name,
                urgency,
                actions,
                report_activation,
                focus,
                report_close,
                timeout_ms,
                only_when_unfocused,
            } => FfiEvent::StructuredNotification {
                id,
                title,
                body,
                app_name,
                urgency,
                actions,
                report_activation,
                focus,
                report_close,
                timeout_ms,
                only_when_unfocused,
            },
            TerminalEvent::NotificationClose { id, report_close } => {
                FfiEvent::NotificationClose { id, report_close }
            }
            TerminalEvent::ContextPush(frame) => FfiEvent::ContextPush {
                frame: frame.into(),
            },
            TerminalEvent::ContextPop => FfiEvent::ContextPop,
            TerminalEvent::ContextClear => FfiEvent::ContextClear,
        }
    }
}
