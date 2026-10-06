/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::render_types::DeltaState;
use crate::terminal::Terminal;
use std::sync::{Mutex, MutexGuard, PoisonError};

pub(crate) struct Engine {
    pub(crate) terminal: Terminal,
    pub(crate) epoch: u64,
}

impl std::ops::Deref for Engine {
    type Target = Terminal;

    fn deref(&self) -> &Terminal {
        &self.terminal
    }
}

impl std::ops::DerefMut for Engine {
    fn deref_mut(&mut self) -> &mut Terminal {
        &mut self.terminal
    }
}

pub(crate) fn lock_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[derive(uniffi::Object)]
pub struct TakoCore {
    pub(crate) inner: Mutex<Engine>,
    pub(crate) delta: Mutex<DeltaState>,
}
