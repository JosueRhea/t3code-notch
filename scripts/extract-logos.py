"""Copies T3 Code's provider logos into Resources/Logos/*.svg (dark-mode colors).

Usage: python3 scripts/extract-logos.py /path/to/t3code
Sources: apps/web/src/components/Icons.tsx (Claude, OpenAI) and
packages/provider-*/src/client.ts (Cursor, Grok, Pi, OpenCode, Muse).
"""
import pathlib, re, sys

t3 = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "../t3code")
out = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "Logos"
out.mkdir(parents=True, exist_ok=True)

def write(name, view_box, paths):
    body = "".join(
        f'<path fill="{fill}"{f" fill-rule={chr(34)}{rule}{chr(34)}" if rule else ""} d="{d}"/>'
        for d, fill, rule in paths)
    (out / f"{name}.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}">{body}</svg>')
    print("wrote", name)

icons = (t3 / "apps/web/src/components/Icons.tsx").read_text()
def icon_block(name):
    return icons[icons.index(f"export const {name}"):][:20000].split("export const", 2)[1]
claude = icon_block("ClaudeAI")
write("claudeAgent", re.search(r'viewBox="([^"]+)"', claude).group(1),
      [(re.search(r'<path d="([^"]+)"', claude).group(1), "#d97757", None)])
openai = icon_block("OpenAI")
write("codex", re.search(r'viewBox="([^"]+)"', openai).group(1),
      [(re.search(r'd="([^"]+)"', openai).group(1), "#FFFFFF", "evenodd")])

for driver in ["cursor", "grok", "pi", "opencode", "muse"]:
    src = (t3 / f"packages/provider-{driver}/src/client.ts").read_text()
    view_box = re.search(r'viewBox: "([^"]+)"', src).group(1)
    default = re.search(r'fill: \{ light: "[^"]+", dark: "([^"]+)" \}', src).group(1)
    paths = []
    for m in re.finditer(r'\{\s*d:\s*"([^"]+)"(.*?)\}(?=\s*,|\s*\])', src, re.S):
        d, rest = m.group(1), m.group(2)
        fill = re.search(r'dark: "([^"]+)"', rest)
        rule = re.search(r'fillRule: "([^"]+)"', rest)
        paths.append((d, fill.group(1) if fill else default, rule.group(1) if rule else None))
    write(driver, view_box, paths)
