/*
 * The smallest TakoCore host over the C ABI: no window, no pty.
 *
 * Feeds a few escape sequences to a terminal, answers what the terminal
 * asks back, prints the screen, then saves the whole terminal to a
 * checkpoint and restores it into a second one.
 *
 *     ./build.sh && ./headless
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "prod_vt.h"
#include "prod_vt_checkpoint.h"

static void feed(ProdVt *vt, const char *text) {
    prod_vt_write(vt, (const uint8_t *)text, strlen(text));
    /* A real host writes these to the program's input. */
    uint8_t *reply = NULL;
    size_t len = 0;
    if (prod_vt_drain_responses(vt, &reply, &len) && len > 0) {
        printf("reply to the program: %zu bytes\n", len);
    }
    prod_vt_buffer_free(reply);
    /* This host does not use bell/title/clipboard notifications. */
    prod_vt_discard_events(vt);
}

static void print_screen(ProdVt *vt, const char *label) {
    uint8_t *text = NULL;
    size_t len = 0;
    if (!prod_vt_viewport_text(vt, &text, &len)) {
        fprintf(stderr, "could not read the screen\n");
        exit(1);
    }
    printf("--- %s ---\n%.*s\n", label, (int)len, (const char *)text);
    prod_vt_buffer_free(text);
}

int main(void) {
    ProdVt *vt = prod_vt_new(40, 6, 1000);
    if (!vt) return 1;

    feed(vt, "\x1b]2;headless demo\x07");          /* window title */
    feed(vt, "plain, \x1b[1mbold\x1b[0m, \x1b[31mred\x1b[0m\r\n");
    feed(vt, "\x1b[3;10Hplaced at row 3, column 10");
    feed(vt, "\x1b[6n");                            /* asks for the cursor */
    print_screen(vt, "screen");

    ProdVtCursor cursor;
    if (prod_vt_cursor_state(vt, &cursor)) {
        printf("cursor at row %u, column %u\n", cursor.y, cursor.x);
    }

    /* Save everything, restore it into a fresh terminal. */
    size_t need = 0;
    if (prod_vt_checkpoint_measure3(vt, 0, 0, &need) != PROD_VT_OK) return 1;
    uint8_t *blob = malloc(need);
    size_t got = 0;
    if (!blob || prod_vt_checkpoint_export3(vt, 0, 0, blob, need, &got) != PROD_VT_OK) return 1;
    printf("checkpoint: %zu bytes, version %u\n", got, prod_vt_checkpoint_version());

    ProdVt *copy = prod_vt_new(40, 6, 1000);
    int status = prod_vt_checkpoint_import2(copy, blob, got);
    free(blob);
    if (status != PROD_VT_OK) {
        fprintf(stderr, "restore failed: %s\n", prod_vt_checkpoint_status_message(status));
        return 1;
    }
    print_screen(copy, "restored");

    prod_vt_free(copy);
    prod_vt_free(vt);
    return 0;
}
