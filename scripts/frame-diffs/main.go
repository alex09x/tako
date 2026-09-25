// Command frame-diffs writes tests/fixtures/frame_diffs: the bytes a real
// differential TUI renderer sends to turn one frame into the next, and the
// frame it meant to leave on screen.
//
// A full-screen program's renderer keeps a buffer of cells and, for each new
// frame, sends only what changed, choosing the cheapest sequence for each
// change: erase or repeat characters, insert or delete them, scroll a region,
// move by tab stops. tests/frame_diffs.rs feeds those bytes to the engine and
// checks that the screen is the frame the renderer intended. The frames come
// from random edits of the kinds real programs make, so every optimisation
// the renderer has gets exercised on the engine.
//
// A case is kept only when a second, independent emulator shows every frame
// exactly as the renderer intended. Where the two disagree the renderer's
// own model of the screen is wrong -- after writing the last column, its
// next clear to the bottom of the screen lands a row below where it believes
// the cursor is -- and such a frame says nothing about the engine.
//
// The renderer and the reference emulator are MIT-licensed Go libraries (see
// NOTICE.md); this program is the only thing that uses them, and only to
// produce the fixtures.
//
//	cd scripts/frame-diffs && go run . -out ../../tests/fixtures/frame_diffs
package main

import (
	"bytes"
	"encoding/hex"
	"flag"
	"fmt"
	"image/color"
	"math/rand"
	"os"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/colorprofile"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/vt"
)

// A profile is a terminal the renderer believes it is drawing on. The first
// is what the engine advertises; the second lets the renderer use every
// sequence it knows, hard tabs and backspace included.
type profile struct {
	name      string
	term      string
	hardTabs  bool
	backspace bool
}

var profiles = []profile{
	{name: "xterm", term: "xterm-256color"},
	{name: "all-sequences", term: "xterm-ghostty", hardTabs: true, backspace: true},
}

// Colours are small integers: -1 default, 0-255 indexed, 256+ an entry of rgbs.
// No rgb equals an indexed colour's palette value: the renderer compares
// colours by value, so it would rightly not send the change.
var rgbs = []color.RGBA{{255, 16, 32, 255}, {0, 200, 120, 255}, {30, 30, 46, 255}, {250, 179, 135, 255}}
var palette = []int{-1, -1, -1, 1, 2, 3, 4, 5, 6, 9, 12, 208, 236, 256, 257, 258, 259}

type cell struct {
	r     rune
	w     int // 1, 2 for a wide character, 0 for the column a wide one covers
	fg    int
	bg    int
	attrs uint8
}

type frame [][]cell

var words = []string{"ls", "cargo", "src", "ok", "main", "diff", "FAIL", "build", "tako", "a", "xy", "λ", "ñandú"}
var wide = []rune("世界漢字表示中文")
var runs = []rune("─═=-.#█ ")

func blank(bg int) cell { return cell{r: ' ', w: 1, fg: -1, bg: bg} }

func pick(rng *rand.Rand, xs []int) int { return xs[rng.Intn(len(xs))] }

func randomRow(rng *rand.Rand, cols int) []cell {
	row := make([]cell, 0, cols)
	for len(row) < cols {
		fg, bg := pick(rng, palette), -1
		if rng.Intn(4) == 0 {
			bg = pick(rng, palette)
		}
		var attrs uint8
		switch rng.Intn(8) {
		case 0:
			attrs = uv.AttrBold
		case 1:
			attrs = uv.AttrItalic
		case 2:
			attrs = uv.AttrReverse
		}
		switch rng.Intn(6) {
		case 0, 1:
			for _, r := range words[rng.Intn(len(words))] {
				row = append(row, cell{r: r, w: 1, fg: fg, bg: bg, attrs: attrs})
			}
		case 2:
			n := 1 + rng.Intn(6)
			for i := 0; i < n; i++ {
				row = append(row, blank(bg))
			}
		case 3:
			row = append(row, cell{r: wide[rng.Intn(len(wide))], w: 2, fg: fg, bg: bg}, cell{w: 0, fg: fg, bg: bg})
		case 4:
			r := runs[rng.Intn(len(runs))]
			n := 2 + rng.Intn(10)
			for i := 0; i < n; i++ {
				row = append(row, cell{r: r, w: 1, fg: fg, bg: bg})
			}
		default:
			row = append(row, blank(-1))
		}
	}
	return normalize(row[:cols])
}

// normalize keeps wide characters whole: one that lost its second column,
// or a second column that lost its character, becomes a blank.
func normalize(row []cell) []cell {
	for x := range row {
		switch {
		case row[x].w == 2 && (x+1 >= len(row) || row[x+1].w != 0):
			row[x] = blank(row[x].bg)
		case row[x].w == 0 && (x == 0 || row[x-1].w != 2):
			row[x] = blank(row[x].bg)
		}
	}
	return row
}

func clone(f frame) frame {
	out := make(frame, len(f))
	for y := range f {
		out[y] = append([]cell(nil), f[y]...)
	}
	return out
}

// edit makes one change of a kind real programs make and returns the frame.
func edit(rng *rand.Rand, f frame) frame {
	rows, cols := len(f), len(f[0])
	y, x := rng.Intn(rows), rng.Intn(cols)
	n := 1 + rng.Intn(3)
	switch rng.Intn(12) {
	case 0: // insert lines, pushing the rest down
		for i := 0; i < n; i++ {
			f = append(f[:y], append(frame{randomRow(rng, cols)}, f[y:]...)...)[:rows]
		}
	case 1: // delete lines, pulling the rest up
		for i := 0; i < n; i++ {
			f = append(append(f[:y], f[y+1:]...), randomRow(rng, cols))
		}
	case 2: // scroll up, as output does
		for i := 0; i < n; i++ {
			f = append(f[1:], randomRow(rng, cols))
		}
	case 3: // scroll down
		for i := 0; i < n; i++ {
			f = append(frame{randomRow(rng, cols)}, f[:rows-1]...)
		}
	case 4, 5: // rewrite a span
		src := randomRow(rng, cols)
		end := x + 1 + rng.Intn(cols-x)
		copy(f[y][x:end], src[x:end])
	case 6: // clear to the end of the line, sometimes with a background
		bg := -1
		if rng.Intn(2) == 0 {
			bg = pick(rng, palette)
		}
		for i := x; i < cols; i++ {
			f[y][i] = blank(bg)
		}
	case 7: // clear a line
		for i := range f[y] {
			f[y][i] = blank(-1)
		}
	case 8: // a run of one character
		r := runs[rng.Intn(len(runs))]
		fg := pick(rng, palette)
		for i := x; i < cols && i < x+3+rng.Intn(12); i++ {
			f[y][i] = cell{r: r, w: 1, fg: fg, bg: -1}
		}
	case 9: // insert characters, pushing the rest of the line right
		ins := randomRow(rng, n)
		f[y] = append(f[y][:x], append(ins, f[y][x:]...)...)[:cols]
	case 10: // delete characters, pulling the rest of the line left
		end := x + n
		if end > cols {
			end = cols
		}
		f[y] = append(f[y][:x], f[y][end:]...)
		for len(f[y]) < cols {
			f[y] = append(f[y], blank(-1))
		}
	default: // one cell
		f[y][x] = cell{r: rune('A' + rng.Intn(26)), w: 1, fg: pick(rng, palette), bg: -1}
	}
	for i := range f {
		f[i] = normalize(f[i])
	}
	return f
}

func uvColor(c int) color.Color {
	switch {
	case c < 0:
		return nil
	case c < 16:
		return ansi.BasicColor(c)
	case c < 256:
		return ansi.IndexedColor(c)
	default:
		return rgbs[c-256]
	}
}

func token(c int) string {
	switch {
	case c < 0:
		return "-"
	case c < 256:
		return fmt.Sprintf("i%d", c)
	default:
		rgb := rgbs[c-256]
		return fmt.Sprintf("r%02x%02x%02x", rgb.R, rgb.G, rgb.B)
	}
}

func attrToken(a uint8) string {
	s := ""
	if a&uv.AttrBold != 0 {
		s += "b"
	}
	if a&uv.AttrItalic != 0 {
		s += "i"
	}
	if a&uv.AttrReverse != 0 {
		s += "r"
	}
	if s == "" {
		return "-"
	}
	return s
}

func draw(buf *uv.RenderBuffer, f frame) {
	for y, row := range f {
		for x, c := range row {
			if c.w == 0 {
				continue
			}
			buf.SetCell(x, y, &uv.Cell{
				Content: string(c.r),
				Width:   c.w,
				Style:   uv.Style{Fg: uvColor(c.fg), Bg: uvColor(c.bg), Attrs: c.attrs},
			})
		}
	}
}

func describe(w *strings.Builder, f frame) {
	for _, row := range f {
		var text strings.Builder
		var fg, bg, at []string
		for _, c := range row {
			if c.w == 0 {
				continue
			}
			text.WriteRune(c.r)
			fg = append(fg, token(c.fg))
			bg = append(bg, token(c.bg))
			at = append(at, attrToken(c.attrs))
		}
		fmt.Fprintf(w, "row %s\nfg %s\nbg %s\nat %s\n", hex.EncodeToString([]byte(text.String())),
			strings.Join(fg, " "), strings.Join(bg, " "), strings.Join(at, " "))
	}
}

// confirmed reports whether the reference emulator, fed the same bytes,
// shows each frame's text exactly as the renderer intended.
func confirmed(cols, rows int, sent [][]byte, frames []frame) bool {
	em := vt.NewEmulator(cols, rows)
	for i, b := range sent {
		if _, err := em.Write(b); err != nil {
			return false
		}
		for y, row := range frames[i] {
			var want, got strings.Builder
			for x, c := range row {
				if c.w != 0 {
					want.WriteRune(c.r)
				}
				cell := em.CellAt(x, y)
				switch {
				case cell == nil:
					got.WriteByte(' ')
				case cell.Width == 0:
				case cell.Content == "":
					got.WriteByte(' ')
				default:
					got.WriteString(cell.Content)
				}
			}
			if got.String() != want.String() {
				return false
			}
		}
	}
	return true
}

func main() {
	out := flag.String("out", "../../tests/fixtures/frame_diffs", "directory to write the fixtures to")
	cases := flag.Int("cases", 60, "cases per profile")
	frames := flag.Int("frames", 6, "frames per case")
	flag.Parse()
	if err := os.MkdirAll(*out, 0o755); err != nil {
		panic(err)
	}
	for pi, p := range profiles {
		rng := rand.New(rand.NewSource(int64(1000 + pi)))
		var w strings.Builder
		fmt.Fprintf(&w, "# Generated by scripts/frame-diffs for TERM=%s; do not edit.\n", p.term)
		dropped := 0
		for n := 0; n < *cases; n++ {
			cols, rows := 10+rng.Intn(39), 4+rng.Intn(11)
			var sent bytes.Buffer
			r := uv.NewTerminalRenderer(&sent, []string{"TERM=" + p.term, "COLORTERM=truecolor"})
			r.SetColorProfile(colorprofile.TrueColor)
			r.SetScrollOptim(true)
			r.SetBackspace(p.backspace)
			if p.hardTabs {
				r.SetTabStops(cols)
			} else {
				r.SetTabStops(-1)
			}
			r.SetFullscreen(true)
			r.SaveCursor()
			r.Erase()

			buf := uv.NewRenderBuffer(cols, rows)
			f := make(frame, rows)
			for y := range f {
				f[y] = randomRow(rng, cols)
			}
			var sentFrames [][]byte
			var drawn []frame
			for i := 0; i < *frames; i++ {
				if i > 0 {
					next := clone(f)
					for e := 1 + rng.Intn(3); e > 0; e-- {
						next = edit(rng, next)
					}
					f = next
				}
				draw(buf, f)
				r.Render(buf)
				if err := r.Flush(); err != nil {
					panic(err)
				}
				sentFrames = append(sentFrames, bytes.Clone(sent.Bytes()))
				drawn = append(drawn, clone(f))
				sent.Reset()
			}
			if !confirmed(cols, rows, sentFrames, drawn) {
				dropped++
				continue
			}
			fmt.Fprintf(&w, "case %d %dx%d\n", n, cols, rows)
			for i := range sentFrames {
				fmt.Fprintf(&w, "frame\nsent %s\n", hex.EncodeToString(sentFrames[i]))
				describe(&w, drawn[i])
			}
			w.WriteString("end\n")
		}
		path := filepath.Join(*out, p.name+".txt")
		if err := os.WriteFile(path, []byte(w.String()), 0o644); err != nil {
			panic(err)
		}
		fmt.Printf("wrote %s (%d cases dropped: the renderer and the reference emulator disagree)\n", path, dropped)
	}
}
