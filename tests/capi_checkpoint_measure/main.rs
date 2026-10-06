/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

mod common;
mod in_flight_string;
mod retained_cost;
mod size_query;

#[global_allocator]
static ALLOC: common::Counting = common::Counting;
