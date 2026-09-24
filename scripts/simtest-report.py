#!/usr/bin/env python3
"""Turn the last simtest run into one page you can look at.

The run leaves a screenshot and a buffer dump per scenario, which is the
evidence -- but nineteen directories of PNGs is not something anyone reads.
This assembles them into a single self-contained HTML file: what each
scenario claims, what the engine ended up holding, and what was on the
screen when it did.

    ./scripts/simtest-report.py            # writes target/simtest/report.html
"""
import base64
import html
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

OUT = "target/simtest"
REPORT = os.path.join(OUT, "report.html")
THUMB_WIDTH = 460

# The families the scenarios fall into. This is not decoration: which
# question a scenario answers is the thing a reader is scanning for, and the
# four groups are four different questions.
FAMILIES = [
    ("Behaviour", "What the terminal does with what the far end sends.",
     lambda n: not n.startswith(("auth-", "hostkey-", "keys-"))),
    ("Getting in", "Every way the app can authenticate, and one way it must not.",
     lambda n: n.startswith("auth-")),
    ("Host keys", "A server offering one key type, met for the first time.",
     lambda n: n.startswith("hostkey-")),
    ("The keyboard", "What a thumb produces, read back as bytes by the server.",
     lambda n: n.startswith("keys-")),
]


def thumbnail(path):
    """A screenshot small enough to embed, still legible at reading size."""
    if not os.path.exists(path):
        return None
    small = path.replace(".png", f"-{THUMB_WIDTH}.png")
    subprocess.run(["magick", path, "-resize", f"{THUMB_WIDTH}x", small], check=True)
    with open(small, "rb") as f:
        return base64.b64encode(f.read()).decode()


def buffer_of(path):
    """The dump with its trailing empty rows removed.

    A terminal screen is mostly blank most of the time, and twenty empty
    lines under six real ones is not evidence of anything.
    """
    if not os.path.exists(path):
        return "", ""
    with open(path) as f:
        text = f.read()
    header, _, body = text.partition("── buffer ──\n")
    status = header.strip()
    return status, "\n".join(body.rstrip().splitlines())


def main():
    results_path = os.path.join(OUT, "results.json")
    if not os.path.exists(results_path):
        sys.exit("no results.json — run ./scripts/simtest.py first")
    with open(results_path) as f:
        results = json.load(f)

    by_name = {r["name"]: r for r in results}
    passed = sum(1 for r in results if r["ok"])

    cards = []
    for title, blurb, belongs in FAMILIES:
        members = [r for r in results if belongs(r["name"])]
        if not members:
            continue
        cards.append(f'<section class="family">'
                     f'<header class="family-head">'
                     f'<h2>{html.escape(title)}</h2>'
                     f'<p>{html.escape(blurb)}</p>'
                     f'</header><div class="cards">')
        for r in members:
            name = r["name"]
            status, buf = buffer_of(os.path.join(OUT, name, "dump.txt"))
            shot = thumbnail(os.path.join(OUT, name, "screen.png"))
            verdict = "pass" if r["ok"] else "fail"
            image = (f'<img src="data:image/png;base64,{shot}" alt="the app '
                     f'during the {html.escape(name)} scenario" loading="lazy">'
                     if shot else '<div class="noshot">no screenshot</div>')
            cards.append(f'''
              <article class="card">
                <div class="card-text">
                  <div class="card-head">
                    <span class="pill {verdict}">{verdict}</span>
                    <h3>{html.escape(name)}</h3>
                  </div>
                  <p class="claim">{html.escape(r.get("why", ""))}</p>
                  <p class="status">{html.escape(status)}</p>
                  <pre class="buffer">{html.escape(buf)}</pre>
                </div>
                <figure class="card-shot">{image}</figure>
              </article>''')
        cards.append("</div></section>")

    page = TEMPLATE.format(
        passed=passed,
        total=len(results),
        families=len([f for f in FAMILIES if any(f[2](r["name"]) for r in results)]),
        body="\n".join(cards),
    )
    with open(REPORT, "w") as f:
        f.write(page)
    size = os.path.getsize(REPORT) / 1_000_000
    print(f"wrote {REPORT} ({size:.1f} MB, {passed}/{len(results)} passing)")


# The page commits to the app's own dark palette rather than following the
# viewer's theme: every screenshot on it is a dark phone screen, and a light
# ground around them would read as a different product. Every colour is
# therefore painted explicitly, so it holds on either host background.
TEMPLATE = """<title>Nineteen Ways In</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {{
    --ink: #14100E;
    --surface: #1C1714;
    --raised: #241D19;
    --hairline: #332A24;
    --paper: #FAF7F2;
    --body: #C9BEB6;
    --dim: #8A7F78;
    --ember: #F4581C;
    --claw: #FF7A3D;
    --pass: #5BD68A;
    --fail: #FF5C5C;
    --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
    --sans: ui-sans-serif, -apple-system, "Segoe UI", system-ui, sans-serif;
  }}

  * {{ box-sizing: border-box; }}

  body {{
    margin: 0;
    background: var(--ink);
    color: var(--body);
    font-family: var(--sans);
    line-height: 1.55;
    -webkit-font-smoothing: antialiased;
  }}

  .wrap {{
    max-width: 1180px;
    margin: 0 auto;
    padding: clamp(32px, 6vw, 72px) clamp(20px, 4vw, 40px) 96px;
  }}

  header.top {{
    display: flex;
    flex-direction: column;
    gap: 18px;
    padding-bottom: 36px;
    border-bottom: 1px solid var(--hairline);
  }}

  .eyebrow {{
    font-family: var(--mono);
    font-size: 12px;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--ember);
  }}

  h1 {{
    margin: 0;
    font-size: clamp(30px, 5vw, 46px);
    line-height: 1.08;
    letter-spacing: -0.02em;
    color: var(--paper);
    text-wrap: balance;
    font-weight: 620;
  }}

  .lede {{
    margin: 0;
    max-width: 62ch;
    font-size: 17px;
    color: var(--body);
  }}

  .tally {{
    display: flex;
    flex-wrap: wrap;
    gap: 28px;
    margin-top: 6px;
    font-variant-numeric: tabular-nums;
  }}

  .tally div {{ display: flex; flex-direction: column; gap: 2px; }}

  .tally b {{
    font-family: var(--mono);
    font-size: 26px;
    font-weight: 600;
    color: var(--paper);
  }}

  .tally span {{
    font-family: var(--mono);
    font-size: 11px;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--dim);
  }}

  .family {{ margin-top: 64px; }}

  .family-head {{
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-bottom: 24px;
  }}

  .family-head h2 {{
    margin: 0;
    font-size: 13px;
    font-family: var(--mono);
    letter-spacing: 0.16em;
    text-transform: uppercase;
    color: var(--claw);
    font-weight: 600;
  }}

  .family-head p {{ margin: 0; color: var(--dim); font-size: 15px; }}

  .cards {{ display: flex; flex-direction: column; gap: 18px; }}

  .card {{
    display: grid;
    grid-template-columns: minmax(0, 1fr) 230px;
    gap: 28px;
    align-items: start;
    padding: 22px;
    background: var(--surface);
    border: 1px solid var(--hairline);
    border-radius: 14px;
  }}

  .card-text {{ display: flex; flex-direction: column; gap: 10px; min-width: 0; }}

  .card-head {{ display: flex; align-items: center; gap: 10px; }}

  .card-head h3 {{
    margin: 0;
    font-family: var(--mono);
    font-size: 15px;
    font-weight: 600;
    color: var(--paper);
  }}

  .pill {{
    font-family: var(--mono);
    font-size: 10px;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    padding: 3px 8px;
    border-radius: 999px;
    border: 1px solid currentColor;
  }}

  .pill.pass {{ color: var(--pass); }}
  .pill.fail {{ color: var(--fail); }}

  .claim {{ margin: 0; font-size: 15px; color: var(--body); max-width: 60ch; }}

  .status {{
    margin: 0;
    font-family: var(--mono);
    font-size: 12px;
    color: var(--dim);
    white-space: pre-line;
  }}

  .buffer {{
    margin: 0;
    padding: 14px 16px;
    background: var(--ink);
    border: 1px solid var(--hairline);
    border-radius: 10px;
    font-family: var(--mono);
    font-size: 12.5px;
    line-height: 1.5;
    color: var(--body);
    white-space: pre;
    overflow-x: auto;
    max-height: 320px;
    overflow-y: auto;
  }}

  .card-shot {{ margin: 0; }}

  .card-shot img {{
    display: block;
    width: 100%;
    height: auto;
    border-radius: 12px;
    border: 1px solid var(--hairline);
    background: var(--raised);
  }}

  .noshot {{
    font-family: var(--mono);
    font-size: 12px;
    color: var(--dim);
    padding: 20px;
    text-align: center;
    border: 1px dashed var(--hairline);
    border-radius: 12px;
  }}

  footer {{
    margin-top: 72px;
    padding-top: 24px;
    border-top: 1px solid var(--hairline);
    font-family: var(--mono);
    font-size: 12px;
    color: var(--dim);
  }}

  @media (max-width: 760px) {{
    .card {{ grid-template-columns: minmax(0, 1fr); }}
    .card-shot {{ max-width: 300px; }}
  }}
</style>

<div class="wrap">
  <header class="top">
    <div class="eyebrow">TakoCore · iPhone</div>
    <h1>{total} terminal scenarios, each one checked twice</h1>
    <p class="lede">
      Every scenario below ran the shipped iPhone build against an ssh server on
      this machine, then read the result two ways: the buffer the engine ended up
      holding, and a screenshot of what was actually drawn. Keys of three types, a
      password, three host key types, and the key row a phone keyboard does not have.
      The companion UI walkthrough also records multi-round MFA, rejection and cancel
      directly from the app's accessibility tree.
    </p>
    <div class="tally">
      <div><b>{passed}/{total}</b><span>scenarios passing</span></div>
      <div><b>{families}</b><span>question families</span></div>
      <div><b>2</b><span>checks per scenario</span></div>
    </div>
  </header>

  {body}

  <footer>
    Regenerate with ./scripts/simtest.py then ./scripts/simtest-report.py.
    Servers are bound to the loopback and torn down with the run.
  </footer>
</div>
"""


if __name__ == "__main__":
    main()
