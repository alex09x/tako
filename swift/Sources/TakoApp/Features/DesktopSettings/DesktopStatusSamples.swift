/*
 * tako — Desktop settings activity samples drawn by the real status layers
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// The reference's indicator samples (pdSample): six tiles, each drawn by
/// the same Core Animation status layer the sidebar uses, so the samples obey
/// status-show, status-animate, Reduce Motion and the occlusion pause.
/// Accessibility: `DesktopStatusSample-<key>`.
struct DesktopStatusSamples: View {
    @ObservedObject private var animState = LivingAnimationState.shared
    let palette: DesktopPalette

    private struct Sample: Identifiable {
        let id: String
        let state: Tako.SurfaceState
        let title: String
        let note: String
        var focus = false
    }

    private let samples: [Sample] = [
        .init(id: "focus", state: .idle, title: "Focused", note: "A thin neutral border, independent of status", focus: true),
        .init(id: "working", state: .working, title: "Working", note: "Moving border"),
        .init(id: "waiting", state: .waiting, title: "Waiting for Input", note: "Breathing border"),
        .init(id: "done", state: .done, title: "Done", note: "A single flash"),
        .init(id: "failed", state: .failed, title: "Error", note: "Bottom border · exit N"),
        .init(id: "idle", state: .idle, title: "Idle", note: ""),
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(samples) { tile($0) }
        }
        .padding(.bottom, 4)
    }

    private func tile(_ sample: Sample) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: 14, height: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(sample.title).font(.system(size: DesktopMetrics.bodyFontSize, weight: .medium))
                    .foregroundStyle(Color(palette.text))
                if !sample.note.isEmpty {
                    Text(sample.note).font(.system(size: 11)).foregroundStyle(Color(palette.muted))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(palette.panel)))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Color(sample.focus ? palette.secondary.withAlphaComponent(0.45) : palette.border)))
        .overlay {
            SidebarStatusLayerView(state: sample.state, ringCenter: CGPoint(x: 12 + 7, y: 10 + 2 + 7), cornerRadius: 9,
                                   reduceMotion: animState.reduceMotion, paused: animState.isTimelinePaused, pulses: 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("DesktopStatusSample-\(sample.id)")
    }
}
