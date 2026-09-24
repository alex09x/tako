/*
 * prod_vt_checkpoint.h -- the TakoCore checkpoint C ABI.
 *
 * Declares the checkpoint half of the surface CodeHaus's `prod_takovt.h`
 * binds, so a consumer has one authoritative header to include rather than a
 * hand-copied set of prototypes that can drift from the library.
 *
 * Two surfaces live here.
 *
 *   The ORIGINAL surface returns `int`: 1 for success, 0 for failure. It is
 *   unchanged and will stay exported -- existing callers keep working. Its one
 *   improvement is that a failing call now leaves its out-parameters in a
 *   defined state (NULL pointer, zero length, zeroed fields) instead of
 *   whatever the caller last left in them.
 *
 *   The VERSION 2 surface (`*2` suffix) returns `int` too, but as a status:
 *   PROD_VT_OK (0) for success and a negative PROD_VT_ERR_* for each distinct
 *   refusal. Use it when the reason matters -- an unreadable container version
 *   is renegotiable, a CRC mismatch is not -- or when you want to size a
 *   buffer instead of letting the library malloc one.
 *
 * Negotiate before binding the *2 symbols:
 *
 *     if (prod_vt_checkpoint_abi_version() != 2) { .. fall back .. }
 *
 * Threading: a ProdVt handle is not internally synchronised. All the functions
 * that take one must be called with the same external synchronisation the rest
 * of the prod_vt surface requires. The free functions (`*_inspect2`,
 * `*_verify2`, `*_status_message`, `*_abi_version`, `*_version`, `*_supports`)
 * touch no shared state and may be called from any thread.
 */

#ifndef PROD_VT_CHECKPOINT_H
#define PROD_VT_CHECKPOINT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque terminal handle, from prod_vt_new(). */
typedef struct ProdVt ProdVt;

/* ------------------------------------------------------------------ */
/* Status codes                                                        */
/* ------------------------------------------------------------------ */

/* Success. The only non-negative status; every failure is negative, so
 * `if (status < 0)` is a complete failure test and stays correct if a future
 * ABI version adds codes. */
#define PROD_VT_OK                           0
/* A required pointer argument was NULL, or a required length was 0. */
#define PROD_VT_ERR_NULL_ARGUMENT           (-1)
/* The caller's buffer is too small; *out_len holds the size required. */
#define PROD_VT_ERR_BUFFER_TOO_SMALL        (-2)
/* The buffer ended in the middle of a field. */
#define PROD_VT_ERR_UNEXPECTED_EOF          (-3)
/* The buffer does not start with the checkpoint magic ("TKCK"). */
#define PROD_VT_ERR_INVALID_MAGIC           (-4)
/* The container version is outside what this build reads. Renegotiate. */
#define PROD_VT_ERR_UNSUPPORTED_VERSION     (-5)
/* The payload CRC32 does not match the header. The bytes are damaged. */
#define PROD_VT_ERR_CHECKSUM_MISMATCH       (-6)
/* The declared payload length disagrees with the bytes supplied. */
#define PROD_VT_ERR_INVALID_PAYLOAD_LENGTH  (-7)
/* A field decoded to something structurally impossible. */
#define PROD_VT_ERR_INVALID_DATA            (-8)
/* Declared geometry is outside the supported range. */
#define PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS (-9)
/* Decoding the container would allocate past the import budget. */
#define PROD_VT_ERR_ALLOCATION_LIMIT       (-10)
/* The container exceeds the wire cap, on export or on import. */
#define PROD_VT_ERR_TOO_LARGE              (-11)

/* Header and geometry of a checkpoint. */
typedef struct ProdVtCheckpointInfo {
    uint32_t version;
    uint32_t flags;
    uint32_t cols;
    uint32_t rows;
    uint32_t payload_len;
} ProdVtCheckpointInfo;

/* ------------------------------------------------------------------ */
/* Version 2: status-bearing, caller-owned buffers                     */
/* ------------------------------------------------------------------ */

/* The version of this surface the library exports. Currently 2. */
uint32_t prod_vt_checkpoint_abi_version(void);

/* A static, NUL-terminated description of a status code. Never NULL, never
 * owned by the caller, valid for the lifetime of the library. An unrecognised
 * code describes itself as unknown, so it is always safe to log. */
const char *prod_vt_checkpoint_status_message(int status);

/*
 * Export a checkpoint into a caller-owned buffer.
 *
 * max_bytes is the caller's own cap, composed with the 64 MiB wire cap; 0
 * means the wire cap alone. It bounds the WHOLE container, the 20-byte header
 * included -- the same number import measures against, so a blob one side
 * calls legal is never one the other side refuses.
 *
 * *out_len is written on every path:
 *   PROD_VT_OK                    bytes written into buf
 *   PROD_VT_ERR_BUFFER_TOO_SMALL  bytes buf needs; nothing was written to buf
 *   anything else                 0
 *
 * out_len must not be NULL. buf may be NULL if and only if cap is 0, which is
 * one way to ask for the size:
 *
 *     size_t need = 0;
 *     if (prod_vt_checkpoint_export2(vt, 0, NULL, 0, &need)
 *             != PROD_VT_ERR_BUFFER_TOO_SMALL) { .. handle .. }
 *     uint8_t *buf = malloc(need);
 *     size_t got = 0;
 *     int st = prod_vt_checkpoint_export2(vt, 0, buf, need, &got);
 *
 * Sizing never materializes the checkpoint: the size is measured by a counting
 * encoder, so the NULL/0 call costs kilobytes regardless of how large the
 * state is. prod_vt_checkpoint_measure2 is the same measurement under a name
 * that says so.
 *
 * The terminal is never mutated, on any path.
 */
int prod_vt_checkpoint_export2(ProdVt *vt,
                               uint64_t max_bytes,
                               uint8_t *buf,
                               size_t cap,
                               size_t *out_len);

/*
 * How many bytes prod_vt_checkpoint_export2 would write, without writing them.
 *
 * Same cap, same refusals, same number -- the sizing half of the two-call
 * idiom as its own entry point, so a caller that only wants the figure need
 * not spell it as an export that fails:
 *
 *     size_t need = 0;
 *     if (prod_vt_checkpoint_measure2(vt, 0, &need) != PROD_VT_OK) { .. }
 *
 * *out_len is the required byte count on PROD_VT_OK and 0 on every failure.
 * out_len must not be NULL. The terminal is never mutated.
 */
int prod_vt_checkpoint_measure2(ProdVt *vt, uint64_t max_bytes, size_t *out_len);

/*
 * export2 and measure2 in a chosen container version: write the newest one
 * the peer supports (prod_vt_checkpoint_supports on its side), so upgrading
 * one side never makes the other refuse its checkpoints. version 0 is
 * prod_vt_checkpoint_version(); a version this build cannot write fails with
 * PROD_VT_ERR_UNSUPPORTED_VERSION and *out_len 0. Version 2 leaves out what
 * version 3 adds (the host's base colours, which colours a program set, and
 * the default cursor style), so its import falls back to inferring them.
 */
int prod_vt_checkpoint_export3(ProdVt *vt,
                               uint32_t version,
                               uint64_t max_bytes,
                               uint8_t *buf,
                               size_t cap,
                               size_t *out_len);
int prod_vt_checkpoint_measure3(ProdVt *vt,
                                uint32_t version,
                                uint64_t max_bytes,
                                size_t *out_len);

/*
 * Restore the terminal from a checkpoint, reporting why if it refuses.
 * Fail-intact: on any negative status the terminal is byte-for-byte what it
 * was before the call.
 */
int prod_vt_checkpoint_import2(ProdVt *vt, const uint8_t *data, size_t len);

/*
 * Read a checkpoint's header and geometry without decoding it.
 * *out is fully written on success and zeroed on every failure.
 */
int prod_vt_checkpoint_inspect2(const uint8_t *data,
                                size_t len,
                                ProdVtCheckpointInfo *out);

/*
 * Whether a buffer is a checkpoint this build could import, and if not, why.
 * Header, version, declared length and CRC32 only -- the payload is not
 * decoded, so a container that passes here can still fail an import on a
 * structurally invalid field.
 */
int prod_vt_checkpoint_verify2(const uint8_t *data, size_t len);

/* ------------------------------------------------------------------ */
/* Version-independent queries                                         */
/* ------------------------------------------------------------------ */

/* The container version this build writes. */
uint32_t prod_vt_checkpoint_version(void);

/* Whether this build can import that container version. 1 yes, 0 no.
 * Explicit negotiation: decide from this rather than inferring an unreadable
 * version from a failed import that also means "corrupt". */
int prod_vt_checkpoint_supports(uint32_t version);

/* ------------------------------------------------------------------ */
/* The original boolean surface (1 success / 0 failure)                */
/* ------------------------------------------------------------------ */

/* Allocates the blob and hands it over; free it with prod_vt_buffer_free.
 * On failure *out is NULL and *out_len is 0. */
int prod_vt_checkpoint(ProdVt *vt, uint8_t **out, size_t *out_len);

/* Alias for prod_vt_checkpoint. */
int prod_vt_checkpoint_export(ProdVt *vt, uint8_t **out, size_t *out_len);

/* prod_vt_checkpoint with a caller-supplied cap; 0 means the wire cap alone. */
int prod_vt_checkpoint_export_limited(ProdVt *vt,
                                      uint64_t max_bytes,
                                      uint8_t **out,
                                      size_t *out_len);

/* Atomic restore. On failure the terminal state is unchanged. */
int prod_vt_restore(ProdVt *vt, const uint8_t *data, size_t len);

/* Alias for prod_vt_restore. */
int prod_vt_checkpoint_import(ProdVt *vt, const uint8_t *data, size_t len);

/* Header, version, declared length and CRC32 only. Conflates "corrupt" with
 * "a version I cannot read"; prod_vt_checkpoint_verify2 separates them. */
int prod_vt_checkpoint_verify(const uint8_t *data, size_t len);

/* Any out-parameter may be NULL. All non-NULL ones are zeroed on failure. */
int prod_vt_checkpoint_inspect(const uint8_t *data,
                               size_t len,
                               uint32_t *out_version,
                               uint32_t *out_cols,
                               uint32_t *out_rows,
                               uint32_t *out_payload_len);

/* Release a buffer handed out by the functions above. */
void prod_vt_buffer_free(uint8_t *data);

/* ------------------------------------------------------------------ */
/* Event management                                                   */
/* ------------------------------------------------------------------ */

/*
 * Discard queued host-visible events without consuming them.
 *
 * For hosts that drive the terminal exclusively through prod_vt_write() and
 * do not consume TerminalEvent notifications (bell, title changes, clipboard,
 * desktop notifications). Drops all queued events and releases their owned
 * payload allocations.
 *
 * Safe to call repeatedly or when no events are queued. Null-safe (no-op if
 * vt is NULL).
 *
 * Does not drain the response queue, reset terminal state, affect title,
 * clipboard, parser, grid, modes, or scrollback, modify epochs, or interfere
 * with checkpoints.
 */
void prod_vt_discard_events(ProdVt *vt);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* PROD_VT_CHECKPOINT_H */
