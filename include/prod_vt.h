/*
 * prod_vt.h -- the TakoCore terminal C ABI: create a terminal, feed it bytes,
 * read what it shows and what it wants written back.
 *
 * Link against the static library built by `cargo build --release`
 * (target/release/libtako_core.a). Checkpoints (saving and restoring the
 * whole terminal state) are declared separately in prod_vt_checkpoint.h.
 *
 * Conventions:
 *   - Functions returning `int` return 1 on success and 0 on failure, unless
 *     documented otherwise.
 *   - A NULL handle is accepted everywhere and fails (or does nothing).
 *   - Buffers returned through `uint8_t **out` are allocated by the library
 *     and must be released with prod_vt_buffer_free(). They are not
 *     NUL-terminated; use the length.
 *   - A handle is not internally synchronised: call the functions that take
 *     one from one thread at a time.
 *   - A panic inside the engine never crosses this boundary; the call fails
 *     instead.
 */

#ifndef PROD_VT_H
#define PROD_VT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef PROD_VT_HANDLE_DEFINED
#define PROD_VT_HANDLE_DEFINED
/* Opaque terminal handle, from prod_vt_new(). */
typedef struct ProdVt ProdVt;
#endif

typedef struct ProdVtCursor {
    uint16_t x;     /* column, 0-based */
    uint16_t y;     /* row, 0-based */
    int visible;
} ProdVtCursor;

typedef struct ProdVtScrollbar {
    uint64_t total;  /* history rows + screen rows */
    uint64_t offset; /* rows above the top of the viewport */
    uint64_t len;    /* screen rows */
} ProdVtScrollbar;

/* A terminal of `cols` x `rows` keeping up to `max_scrollback` lines of
 * history. NULL on failure. Release with prod_vt_free(). */
ProdVt *prod_vt_new(uint16_t cols, uint16_t rows, size_t max_scrollback);
void prod_vt_free(ProdVt *vt);

/* Feed output from the program (what it wrote to its pty). */
void prod_vt_write(ProdVt *vt, const uint8_t *data, size_t len);

/* Replies the terminal owes the program (device attributes, cursor reports,
 * ...): write these to the program's input. Call after every prod_vt_write. */
int prod_vt_drain_responses(ProdVt *vt, uint8_t **out, size_t *out_len);

/* Drop queued notifications (bell, title, clipboard, ...) a host does not
 * consume, so they do not accumulate. */
void prod_vt_discard_events(ProdVt *vt);

/* New size; the cell size in pixels is for pixel-based reports (0 if unknown).
 * Fails for a zero dimension. */
int prod_vt_resize(ProdVt *vt, uint16_t cols, uint16_t rows,
                   uint32_t cell_width_px, uint32_t cell_height_px);

/* Scroll the viewport: positive goes back into history. */
void prod_vt_scroll_delta(ProdVt *vt, ptrdiff_t delta);
void prod_vt_scroll_bottom(ProdVt *vt);

/* Whether DEC private mode `mode` is on (1000-1007 mouse, 7 autowrap,
 * 6 origin, 1 cursor keys, 2004 bracketed paste, 1004 focus, 25 cursor).
 * Fails for a mode not listed. */
int prod_vt_mode(ProdVt *vt, uint16_t mode, int *enabled);
int prod_vt_active_screen(ProdVt *vt, int *alternate);
int prod_vt_viewport_active(ProdVt *vt, int *active);
int prod_vt_cursor_state(ProdVt *vt, ProdVtCursor *cursor);
int prod_vt_scrollbar_state(ProdVt *vt, ProdVtScrollbar *scrollbar);

/* The screen as plain UTF-8 text, rows separated by '\n'. */
int prod_vt_viewport_text(ProdVt *vt, uint8_t **out, size_t *out_len);
/* The screen with SGR styling, rows separated by "\r\n". */
int prod_vt_viewport_ansi(ProdVt *vt, uint8_t **out, size_t *out_len);
/* History as text, then the styled screen. */
int prod_vt_snapshot_ansi(ProdVt *vt, uint8_t **out, size_t *out_len);
/* Like prod_vt_snapshot_ansi, without trailing blank rows and ending with
 * the cursor's position. For restoring the whole state, use a checkpoint. */
int prod_vt_snapshot_ansi_v2(ProdVt *vt, uint8_t **out, size_t *out_len);
int prod_vt_title(ProdVt *vt, uint8_t **out, size_t *out_len);

/* Bytes a mouse wheel step sends to the program when it tracks the mouse;
 * fails when it does not. */
int prod_vt_encode_wheel(ProdVt *vt, int up, uint16_t column, uint16_t row,
                         uint8_t **out, size_t *out_len);

void prod_vt_buffer_free(uint8_t *data);

#ifdef __cplusplus
}
#endif

#endif /* PROD_VT_H */
