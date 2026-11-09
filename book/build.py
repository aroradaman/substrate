#!/usr/bin/env python3
"""Validate and assemble the local Substrate manuscript; never runs cluster tools."""

import argparse
import base64
import collections
import hashlib
import html
import json
import functools
import re
import subprocess
import sys
import unicodedata
from pathlib import Path
from urllib.parse import unquote, urlsplit

try:
    import markdown
except ImportError:
    raise SystemExit("Install Python-Markdown in your preferred Python environment.")

BOOK = Path(__file__).resolve().parent
REPO = BOOK.parent
BASELINE = "b34fbee742906494b5eb4f1f36987176bf8770a4"
# Code links point at the upstream repository at a pinned ref, so readers never
# see paths into a local clone. The companion and the reconnaissance notes are
# pinned to the commit their evidence came from.
REPO_URL = "https://github.com/agent-substrate/substrate"
TAG = "v1.0.0"
UPSTREAM_LINK = re.compile(rf"^{re.escape(REPO_URL)}/(blob|tree)/([^/]+)/([^#]+)(#.*)?$")
TITLE = "Substrate Internals: Sandboxing, Scheduling, and Multiplexing AI Agents on Kubernetes"
CHAPTERS = [
    ("01-architecture.md", 6000),
    ("02-api-planes.md", 6600),
    ("03-placement-consistency.md", 7500),
    ("04-kubernetes-reconciliation.md", 6600),
    ("05-node-supervision.md", 7200),
    ("06-gvisor.md", 7200),
    ("07-microvm.md", 7500),
    ("08-snapshots-storage.md", 7500),
    ("09-networking.md", 7500),
    ("10-security-identity.md", 7500),
    ("11-operations.md", 7200),
    ("12-extension-contracts.md", 6300),
]
APPENDICES = ["appendix-a-kernel-audit.md", "appendix-b-source-inventory.md", "appendix-c-glossary.md"]
FENCE = re.compile(r"^```([^\n]*)\n(.*?)^```[ \t]*$", re.M | re.S)
LINK = re.compile(r"(?<!!)\[([^\]\n]+)\]\(([^\s)]+)\)")


def slug(value, separator="-"):
    value = unicodedata.normalize("NFKD", value)
    value = re.sub(r"[^\w\s-]", "", value.lower())
    return re.sub(r"[-\s]+", separator, value).strip(separator)


def first_title(text):
    match = re.search(r"^# ([^\n]+)", text, re.M)
    return match.group(1) if match else "Untitled"


def prose(text):
    text = FENCE.sub("", text)
    text = LINK.sub(lambda m: m.group(1), text)
    text = re.sub(r"https?://\S+", "", text)
    return text


def local_destination(source, target):
    parsed = urlsplit(target)
    if parsed.scheme or target.startswith("#") or not parsed.path:
        return None
    return (source.parent / unquote(parsed.path.strip("<>"))).resolve()


@functools.lru_cache(maxsize=None)
def upstream_problem(url):
    """Return why an upstream code link is wrong, or None if it names an object at its ref."""
    match = UPSTREAM_LINK.match(url)
    if not match:
        return "not a blob or tree URL under the upstream repository"
    kind, ref, path, _ = match.groups()
    result = subprocess.run(["git", "-C", str(REPO), "cat-file", "-t", f"{ref}:{path}"], capture_output=True, text=True)
    if result.returncode != 0:
        return f"{path} does not exist at {ref}"
    actual = result.stdout.strip()
    if (kind == "blob") != (actual == "blob"):
        return f"{path} is a {actual} at {ref}, not a {kind}"
    return None


def collect(partial, lifecycle=False):
    wanted = ([BOOK / "actor-lifecycle.md"] if lifecycle else
              [BOOK / "front-matter.md"] + [BOOK / "chapters" / n for n, _ in CHAPTERS] + [BOOK / n for n in APPENDICES])
    missing = [str(p.relative_to(BOOK)) for p in wanted if not p.exists()]
    if missing and not partial:
        raise SystemExit("Missing manuscript files: " + ", ".join(missing))
    return [(p, p.read_text()) for p in wanted if p.exists()], missing


def validate(documents, missing):
    errors, warnings, rows = [], [], []
    paragraphs = collections.defaultdict(list)
    diagram_count = 0
    source_link_count = 0
    upstream_count = 0
    for path, text in documents:
        name = str(path.relative_to(BOOK))
        if len(re.findall(r"^```", text, re.M)) % 2:
            errors.append(f"{name}: unbalanced fenced code")
        for label, target in LINK.findall(text):
            if target.startswith(REPO_URL + "/"):
                upstream_count += 1
                problem = upstream_problem(target)
                if problem:
                    errors.append(f"{name}: {target}: {problem}")
                continue
            dst = local_destination(path, target)
            if dst is None:
                continue
            source_link_count += 1
            if not dst.exists():
                errors.append(f"{name}: missing link target {target}")
            elif dst.is_relative_to(REPO) and not dst.is_relative_to(BOOK):
                errors.append(f"{name}: {target} links repository code by path; use the upstream URL")
        for paragraph in re.split(r"\n\s*\n", prose(text)):
            normalized = re.sub(r"\s+", " ", paragraph).strip()
            if len(normalized.split()) >= 65 and not normalized.startswith(("|", "#", "-")):
                paragraphs[normalized].append(name)
        diagrams = sum(1 for m in FENCE.finditer(text) if m.group(1).strip() == "mermaid")
        diagram_count += diagrams
        if path.parent.name != "chapters":
            continue
        number = int(path.name.split("-", 1)[0])
        target = dict(CHAPTERS)[path.name]
        numbered = re.findall(r"^## (\d+)\.(\d+)\b", text, re.M)
        expected = [(str(number), str(i)) for i in range(1, 7)]
        if numbered != expected:
            errors.append(f"{name}: numbered sections {numbered}, expected {expected}")
        if not re.search(rf"^## {number}\.6 .*Roadmap|^## {number}\.6 .*roadmap", text, re.M):
            errors.append(f"{name}: N.6 must identify roadmap content")
        if not re.search(r"^## Source map\s*$", text, re.M):
            errors.append(f"{name}: missing source map")
        if diagrams < 2:
            errors.append(f"{name}: requires at least two Mermaid diagrams")
        raw_words = len(text.split())
        prose_words = len(prose(text).split())
        if raw_words < target * 0.9:
            warnings.append(f"{name}: {raw_words} raw words, below 90% of {target} target")
        rows.append({"chapter": number, "file": name, "title": first_title(text), "target_words": target,
                     "raw_words": raw_words, "prose_words": prose_words, "mermaid_diagrams": diagrams})
    duplicates = [{"files": names, "excerpt": p[:180]} for p, names in paragraphs.items() if len(names) > 1]
    if duplicates:
        warnings.append(f"{len(duplicates)} repeated long paragraphs require editorial review")
    return {"baseline_commit": BASELINE, "complete_chapter_set": not missing, "missing_files": missing,
            "source_sha256": {str(p.relative_to(BOOK)): hashlib.sha256(t.encode()).hexdigest() for p, t in documents},
            "chapters": rows, "body_raw_words": sum(r["raw_words"] for r in rows),
            "body_prose_words": sum(r["prose_words"] for r in rows),
            "total_prose_words": sum(len(prose(t).split()) for _, t in documents),
            "mermaid_diagrams": diagram_count, "checked_local_links": source_link_count,
            "upstream_source_links": upstream_count,
            "errors": errors, "warnings": warnings, "duplicate_paragraphs": duplicates,
            "validation_scope": "Static manuscript checks only. This checker does not execute cluster tests; separately recorded live experiments are identified by the manuscript and evidence index."}


def rewrite_links(source, text, titles):
    def replace(match):
        label, target = match.groups()
        dst = local_destination(source, target)
        if dst is None:
            return match.group(0)
        if dst in titles:
            return f"[{label}](#{urlsplit(target).fragment or slug(titles[dst])})"
        # Book artifacts such as experiment scripts exist only in the local clone,
        # so the rendered reader sees the label without a file path.
        if dst.is_relative_to(BOOK):
            return label
        return match.group(0)
    return LINK.sub(replace, text)


def figures_for(path, text, manifest, directory="figures", caption_prefix=None):
    number = 0
    def replace(match):
        nonlocal number
        if match.group(1).strip() != "mermaid":
            return match.group(0)
        number += 1
        identifier = f"{path.stem}-{number:02d}"
        code = match.group(2).strip() + "\n"
        input_path = BOOK / directory / f"{identifier}.mmd"
        output_path = input_path.with_suffix(".svg")
        input_path.write_text(code)
        manifest.append({"id": identifier, "chapter": path.name, "input": str(input_path.relative_to(BOOK)),
                         "output": str(output_path.relative_to(BOOK)), "sha256": hashlib.sha256(code.encode()).hexdigest()})
        caption = f"Figure {caption_prefix or path.name.split('-')[0]}.{number}"
        if output_path.exists():
            encoded = base64.b64encode(output_path.read_bytes()).decode()
            return f'\n<figure id="{identifier}"><img alt="{caption}" src="data:image/svg+xml;base64,{encoded}"><figcaption>{caption}</figcaption></figure>\n'
        return f'\n<figure id="{identifier}" class="unrendered"><pre>{html.escape(code)}</pre><figcaption>{caption}: rendering pending</figcaption></figure>\n'
    return FENCE.sub(replace, text)


CSS = """
:root { color-scheme: light; --ink:#182331; --muted:#556373; --accent:#176b73; --line:#d9e1e7; }
* { box-sizing:border-box; }
html { scroll-behavior:smooth; }
body { margin:0; color:var(--ink); background:#f2f5f7; font-family:Georgia,'Times New Roman',serif; font-size:18px; line-height:1.65; }
.cover { background:#142c38; color:#f2faf9; padding:5rem 3rem; border-bottom:8px solid #6cd0be; }
.cover .eyebrow { font-family:Arial,sans-serif; text-transform:uppercase; letter-spacing:.15em; font-size:.8rem; color:#a7dbd0; }
.cover h1 { margin:.7rem 0; font-size:3.6rem; line-height:1.08; max-width:900px; color:inherit; }
.cover p { max-width:850px; font-size:1.2rem; color:#d7e6e9; }
.layout { display:grid; grid-template-columns:280px minmax(0,1020px); gap:30px; max-width:1400px; margin:auto; padding:30px 20px; align-items:start; }
nav { position:sticky; top:18px; max-height:94vh; overflow:auto; padding:18px; font:13px/1.5 Arial,sans-serif; }
nav ul { list-style:none; padding-left:12px; }
nav > .toc > ul { padding-left:0; }
nav li { margin:7px 0; }
nav li ul ul { display:none; }
nav a { color:#38515c; text-decoration:none; }
nav a:hover { color:var(--accent); text-decoration:underline; }
main { background:white; padding:46px 58px; min-width:0; box-shadow:0 3px 18px #1533440a; }
h1,h2,h3,h4 { font-family:Arial,Helvetica,sans-serif; line-height:1.25; color:#173443; break-after:avoid; }
main h1 { font-size:2.15rem; margin:5rem 0 1.8rem; padding-top:1.8rem; border-top:3px solid var(--accent); }
main h1:first-child { margin-top:0; }
h2 { font-size:1.4rem; margin:2.4rem 0 1rem; }
h3 { font-size:1.12rem; margin:1.7rem 0 .7rem; }
p { margin:.85rem 0; orphans:3; widows:3; }
a { color:#176b73; text-underline-offset:2px; overflow-wrap:anywhere; }
code { font-family:'SFMono-Regular',Consolas,monospace; font-size:.84em; overflow-wrap:anywhere; }
pre { background:#f3f6f8; border:1px solid #dce4e8; border-radius:4px; padding:15px; font-size:13px; line-height:1.45; overflow:auto; white-space:pre-wrap; overflow-wrap:anywhere; }
pre code { font-size:inherit; }
table { width:100%; border-collapse:collapse; font:13px/1.45 Arial,sans-serif; margin:1.3rem 0; table-layout:auto; }
th,td { padding:9px 10px; text-align:left; border-bottom:1px solid var(--line); vertical-align:top; overflow-wrap:anywhere; }
th { background:#eaf1f3; color:#163946; }
tr:nth-child(even) td { background:#fafcfc; }
blockquote { margin:1rem 0; padding:.2rem 1rem; border-left:3px solid var(--accent); background:#f2f8f7; }
figure { margin:1.8rem 0; padding:14px; border:1px solid #dce5e9; break-inside:avoid; }
figure img { display:block; max-width:100%; max-height:650px; width:auto; height:auto; margin:auto; }
figcaption { font:12px/1.4 Arial,sans-serif; text-align:center; color:var(--muted); margin-top:9px; }
.print-toc { display:none; }
.meta { font:12px/1.5 Arial,sans-serif; color:#526674; }
@media (max-width:1000px) { .layout {display:block;} nav {position:relative;max-height:350px;} main {padding:25px;} .cover {padding:3rem 1.5rem;} .cover h1 {font-size:2.7rem;} }
@page { size:7in 10in; margin:.65in .62in .7in; }
@media print {
  body { background:white; font-size:11pt; line-height:1.43; }
  .cover { height:8.5in; padding:1.25in .2in 0; background:white; color:#173443; border:none; break-after:page; }
  .cover h1 {font-size:34pt;}
  .cover p {color:#34515d;font-size:17pt;}
  .cover .eyebrow {color:#376875;}
  .layout {display:block;padding:0;max-width:none;}
  nav {display:none;}
  main {padding:0;box-shadow:none;}
  main h1 {font-size:24pt;break-before:page;margin:0 0 24pt;padding-top:18pt;}
  main h1:first-child {break-before:auto;}
  h2 {font-size:15pt;margin:21pt 0 10pt;}
  h3 {font-size:11.7pt;margin:14pt 0 7pt;}
  h2[id^="source-map"] + ul {break-inside:avoid;}
  p {margin:7pt 0;}
  a {color:inherit;text-decoration:none;}
  pre {font-size:8pt;padding:8pt;border-radius:0;}
  table {font-size:8pt;line-height:1.3;}
  th,td {padding:5pt;}
  tr {break-inside:avoid;}
  thead {display:table-header-group;}
  figure {padding:6pt;margin:14pt 0;}
  figure img {max-height:6.6in;}
  figcaption {font-size:8pt;}
  .print-toc {display:block;break-after:page;}
  .print-toc ul {padding-left:17pt;}
  .print-toc ul ul ul {display:none;}
  .print-toc li {font:9pt/1.35 Arial,sans-serif;margin:3pt 0;}
}
"""


def build(partial=False, lifecycle=False):
    documents, missing = collect(partial, lifecycle)
    report = validate(documents, missing)
    stem = "actor-lifecycle" if lifecycle else "substrate-internals"
    figure_dir = "lifecycle-figures" if lifecycle else "figures"
    validation_file = "lifecycle-validation.json" if lifecycle else "validation.json"
    render_file = "lifecycle-render-validation.json" if lifecycle else "render-validation.json"
    title = "An Actor's Complete Lifecycle: Deployment, gVisor, Snapshots, Suspend and Resume" if lifecycle else TITLE
    cover_title = "An Actor's<br>Complete Lifecycle" if lifecycle else "Substrate<br>Internals"
    subtitle = "Deployment, gVisor, Snapshots,<br>Suspend and Resume" if lifecycle else "Sandboxing, Scheduling, and Multiplexing<br>AI Agents on Kubernetes"
    if lifecycle:
        report["document_kind"] = "standalone lifecycle section"
        report["complete_chapter_set"] = None
        report["body_raw_words"] = sum(len(t.split()) for _, t in documents)
        report["body_prose_words"] = report["total_prose_words"]
        if report["mermaid_diagrams"] < 8:
            report["errors"].append("Lifecycle section requires at least eight diagrams")
    (BOOK / figure_dir).mkdir(exist_ok=True)
    titles = {p.resolve(): first_title(t) for p, t in documents}
    manuscript = "\n\n".join(rewrite_links(p, t, titles) for p, t in documents)
    if not lifecycle:
        (BOOK / "manuscript.md").write_text(manuscript)
    manifest = []
    render_source = "\n\n".join(figures_for(p, rewrite_links(p, t, titles), manifest, figure_dir, "L" if lifecycle else None) for p, t in documents)
    md = markdown.Markdown(extensions=["fenced_code", "tables", "toc", "sane_lists", "footnotes"],
                           extension_configs={"toc": {"slugify": slug, "toc_depth": "1-2"}})
    body = md.convert(render_source)
    page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title><meta name="author" content="Substrate Internals manuscript"><style>{CSS}</style></head>
<body><header class="cover"><div class="eyebrow">Source-grounded systems engineering</div><h1>{cover_title}</h1>
<p>{subtitle}</p>
<p class="meta">Implementation baseline v1.0.0, {BASELINE[:12]}<br>November 9, 2026</p></header>
<div class="layout"><nav aria-label="Table of contents">{md.toc}</nav><main>
<section class="print-toc"><h1>Contents</h1>{md.toc}</section>{body}</main></div></body></html>'''
    (BOOK / (stem + ".html")).write_text(page)
    (BOOK / figure_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    report["rendered_figures"] = sum((BOOK / f["output"]).exists() for f in manifest)
    render_report = BOOK / render_file
    if render_report.exists():
        report["render_validation"] = json.loads(render_report.read_text())
    (BOOK / validation_file).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ["complete_chapter_set", "body_raw_words", "body_prose_words", "total_prose_words", "mermaid_diagrams", "rendered_figures", "checked_local_links", "errors", "warnings"]}, indent=2))
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--partial", action="store_true", help="assemble currently available chapters during editing")
    parser.add_argument("--lifecycle", action="store_true", help="build the independent actor lifecycle section")
    args = parser.parse_args()
    sys.exit(build(args.partial, args.lifecycle))
