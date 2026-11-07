/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

/*
 * prod_vt_program_status.h -- Additive C ABI for OSC 7501 Program Status
 * (revision 0.4) and consume-once classified PTY replies.
 *
 * Status functions return PROD_VT_OK (0) on success, PROD_VT_ERR_NULL_ARGUMENT
 * (-1) on a NULL handle or out-pointer, and PROD_VT_ERR_REPLY_OVERFLOW (-12)
 * when prod_vt_drain_classified_replies() reports dropped replies beyond the
 * bounded FIFO cap (while still populating *batch_out with the preserved FIFO
 * prefix and overflow_dropped_count).
 *
 * Pull-on-feed order for canonical server hosts:
 *   1. prod_vt_write(vt, bytes, len);
 *   2. Drain typed 7501 updates BEFORE prod_vt_discard_events():
 *        do { prod_vt_program_status_drain(vt, 64, &batch); ... } while (batch->has_more);
 *      If batch->overflow_coalesced != 0, batch->has_resync_snapshot != 0 and
 *      batch->resync_snapshot holds the latest authoritative snapshot, with
 *      batch->overflow_from_revision marking the first dropped update revision.
 *   3. prod_vt_discard_events(vt);  // drops bell/title/clipboard events
 *   4. prod_vt_drain_classified_replies(vt, 64, &replies);
 *      Both prod_vt_drain_classified_replies() and legacy
 *      prod_vt_drain_responses() pop consume-once from the same underlying
 *      FIFO ResponseQueue: choose one path per turn, and even mixed calls will
 *      never emit the same reply twice.
 */

#ifndef PROD_VT_PROGRAM_STATUS_H
#define PROD_VT_PROGRAM_STATUS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef PROD_VT_HANDLE_DEFINED
#define PROD_VT_HANDLE_DEFINED
typedef struct ProdVt ProdVt;
#endif

#define PROD_VT_PROGRAM_STATUS_ABI_VERSION 1u

#ifndef PROD_VT_OK
#define PROD_VT_OK 0
#define PROD_VT_ERR_NULL_ARGUMENT (-1)
#endif
#define PROD_VT_ERR_REPLY_OVERFLOW (-12)

/* ProgramStatusState */
#define PROD_VT_STATUS_STATE_NONE    0u
#define PROD_VT_STATUS_STATE_IDLE    1u
#define PROD_VT_STATUS_STATE_WORKING 2u
#define PROD_VT_STATUS_STATE_DONE    3u
#define PROD_VT_STATUS_STATE_BLOCKED 4u
#define PROD_VT_STATUS_STATE_ERROR   5u

/* ProgramStatusBlockedKind */
#define PROD_VT_STATUS_KIND_NONE       0u
#define PROD_VT_STATUS_KIND_PERMISSION 1u
#define PROD_VT_STATUS_KIND_QUESTION   2u
#define PROD_VT_STATUS_KIND_AUTH       3u

/* ProgramStatusRemovalReason */
#define PROD_VT_STATUS_REASON_NONE           0u
#define PROD_VT_STATUS_REASON_EXPLICIT_CLEAR 1u
#define PROD_VT_STATUS_REASON_PROMPT_RETURN  2u
#define PROD_VT_STATUS_REASON_PROCESS_EXIT   3u
#define PROD_VT_STATUS_REASON_INTERRUPTED    4u
#define PROD_VT_STATUS_REASON_ACKNOWLEDGED   5u
#define PROD_VT_STATUS_REASON_HARD_RESET     6u
#define PROD_VT_STATUS_REASON_EVICTED        7u

/* ProgramStatusMutation discriminant */
#define PROD_VT_STATUS_MUTATION_UPSERTED 1u
#define PROD_VT_STATUS_MUTATION_REMOVED  2u
#define PROD_VT_STATUS_MUTATION_RESET    3u

/* TerminalReplyClass */
#define PROD_VT_REPLY_CLASS_STANDARD_DEVICE           1u
#define PROD_VT_REPLY_CLASS_PROGRAM_STATUS_CAPABILITY 2u

/* Borrowed UTF-8 view owned by the enclosing snapshot or drain batch.
 * When present != 0, ptr points to len UTF-8 bytes followed by a trailing NUL. */
typedef struct ProdVtUtf8View {
    const char *ptr;
    size_t len;
    uint8_t present;
    uint8_t reserved[7];
} ProdVtUtf8View;

typedef struct ProdVtProgramStatusRecord {
    uint64_t revision;
    uint8_t state;
    uint8_t kind;
    uint8_t has_progress;
    uint8_t progress;
    uint32_t reserved;
    ProdVtUtf8View id;
    ProdVtUtf8View app;
    ProdVtUtf8View resolved_app;
    ProdVtUtf8View title;
    ProdVtUtf8View msg;
} ProdVtProgramStatusRecord;

typedef struct ProdVtProgramStatusMutation {
    uint8_t mutation_type;
    uint8_t reason;
    uint16_t reserved;
    uint32_t removed_count;
    ProdVtUtf8View id;
    ProdVtProgramStatusRecord record;
} ProdVtProgramStatusMutation;

typedef struct ProdVtProgramStatusUpdate {
    uint64_t revision;
    int has_effective;
    uint32_t reserved;
    ProdVtProgramStatusRecord effective;
    const ProdVtProgramStatusMutation *mutations;
    size_t mutations_len;
} ProdVtProgramStatusUpdate;

typedef struct ProdVtProgramStatusSnapshot {
    uint32_t abi_version;
    int osc7501_active;
    uint64_t revision;
    int has_effective;
    uint32_t reserved;
    ProdVtProgramStatusRecord effective;
    const ProdVtProgramStatusRecord *records;
    size_t records_len;
} ProdVtProgramStatusSnapshot;

typedef struct ProdVtProgramStatusDrainBatch {
    uint32_t abi_version;
    int has_more;
    int overflow_coalesced;
    int has_resync_snapshot;
    uint64_t snapshot_revision;
    uint64_t overflow_from_revision;
    const ProdVtProgramStatusUpdate *updates;
    size_t updates_len;
    ProdVtProgramStatusSnapshot resync_snapshot;
} ProdVtProgramStatusDrainBatch;

typedef struct ProdVtClassifiedReply {
    uint64_t seq;
    uint8_t reply_class;
    uint8_t reserved[7];
    const uint8_t *data;
    size_t len;
} ProdVtClassifiedReply;

typedef struct ProdVtReplyBatch {
    uint32_t abi_version;
    int has_more;
    uint32_t overflow_dropped_count;
    uint32_t reserved;
    const ProdVtClassifiedReply *replies;
    size_t replies_len;
} ProdVtReplyBatch;

uint32_t prod_vt_program_status_abi_version(void);

int prod_vt_set_program_status_probe_reply_enabled(ProdVt *vt, int enabled);
int prod_vt_is_program_status_probe_reply_enabled(const ProdVt *vt, int *enabled_out);

int prod_vt_program_status_snapshot(
    const ProdVt *vt,
    ProdVtProgramStatusSnapshot **snapshot_out
);
void prod_vt_program_status_snapshot_free(ProdVtProgramStatusSnapshot *snapshot);

int prod_vt_program_status_drain(
    ProdVt *vt,
    size_t max_updates,
    ProdVtProgramStatusDrainBatch **batch_out
);
void prod_vt_program_status_drain_free(ProdVtProgramStatusDrainBatch *batch);

int prod_vt_program_status_process_exited(ProdVt *vt);
int prod_vt_program_status_interrupted(ProdVt *vt);
int prod_vt_program_status_acknowledged(ProdVt *vt);

int prod_vt_drain_classified_replies(
    ProdVt *vt,
    size_t max_replies,
    ProdVtReplyBatch **batch_out
);
void prod_vt_reply_batch_free(ProdVtReplyBatch *batch);

#ifdef __cplusplus
}
#endif

#endif /* PROD_VT_PROGRAM_STATUS_H */
