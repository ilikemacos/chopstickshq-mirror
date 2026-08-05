#!/usr/bin/env python3
"""
Mirror the rNitro product site under ./rnitro/ for chopstickshq.com/rnitro/
"""
from __future__ import annotations

import re
import shutil
from pathlib import Path

HQ = Path(__file__).resolve().parent
SITE = HQ.parent / "rnitro-site"
OUT = HQ / "rnitro"
ASSET_ORIGIN = "https://chopstickshq.com/rnitro"
BASE = "/rnitro"

COPY_FILES = [
    "404.html",
    "archives.html",
    "privacy.html",
    "faq.html",
    "terms.html",
    "windows.html",
    "linux.html",
    "cli.html",
    "index.html",
    "version.json",
    "changelog.json",
    "roadmap.json",
    "reviews.json",
    "terms-and-conditions.txt",
    "favicon.ico",
    "favicon.png",
    "favicon-192.png",
    "apple-touch-icon.png",
    "VarelaRound.ttf",
    "GeistMono.ttf",
    "robots.txt",
    "sitemap.xml",
    "googleadfac0eaf77a74e6.html",
]


def rewrite_text(text: str, *, is_html: bool) -> str:
    text = re.sub(r'(href|src|action)="/(?!/)', rf'\1="{BASE}/', text)
    text = text.replace("url('/", f"url('{BASE}/")
    text = text.replace('url("/', f'url("{BASE}/')
    text = text.replace("location.href = '/", f"location.href = '{BASE}/")
    text = text.replace('location.href = "/', f'location.href = "{BASE}/')
    text = text.replace("location.replace('/", f"location.replace('{BASE}/")
    text = text.replace('location.replace("/', f'location.replace("{BASE}/')
    text = text.replace("location.assign('/", f"location.assign('{BASE}/")
    text = text.replace(
        "const CHAT_API_URL = '/.netlify/functions/chat';",
        f"const CHAT_API_URL = '{ASSET_ORIGIN}/.netlify/functions/chat';",
    )
    text = text.replace("'/.netlify/functions/chat'", f"'{ASSET_ORIGIN}/.netlify/functions/chat'")
    text = text.replace('"/.netlify/functions/chat"', f'"{ASSET_ORIGIN}/.netlify/functions/chat"')

    if is_html and "__RNITRO_BASE__" not in text:
        inject = f"""<script>
window.__RNITRO_BASE__ = {BASE!r};
window.__RNITRO_ASSET_ORIGIN__ = {ASSET_ORIGIN!r};
</script>
"""
        text = text.replace("<head>", "<head>\n" + inject, 1)

    if is_html:
        text = text.replace("https://chopstickshq.com/macbar/", "https://chopstickshq.com/rnitro/")
        text = text.replace("https://chopstickshq.com/macbar", "https://chopstickshq.com/rnitro")
        text = text.replace(
            '<link rel="canonical" href="https://getrnitro.netlify.app/">',
            '<link rel="canonical" href="https://chopstickshq.com/rnitro/">',
        )
        text = text.replace(
            '<meta property="og:url" content="https://getrnitro.netlify.app/">',
            '<meta property="og:url" content="https://chopstickshq.com/rnitro/">',
        )

    if "function assetUrl(file)" in text and "Already absolute" not in text:
        text = text.replace(
            "function assetUrl(file) {\n    const base = downloadBase();\n    return base + encodeURI(file).replace(/%2F/g, '/');\n  }",
            "function assetUrl(file) {\n"
            "    if (/^https?:\\/\\//i.test(String(file || ''))) return String(file);\n"
            "    const base = downloadBase();\n"
            "    return base + encodeURI(file).replace(/%2F/g, '/');\n"
            "  }",
            1,
        )
    return text


def _copy_release_binaries() -> None:
    import json

    vpath = SITE / "version.json"
    if not vpath.is_file():
        return
    try:
        data = json.loads(vpath.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"  skip binaries: bad version.json ({exc})")
        return

    names: set[str] = set()
    releases = data.get("releases") or {}
    for key in ("stable", "beta", "experimental", "intel_beta", "intel_stable", "cli", "linux", "windows"):
        rel = releases.get(key) or {}
        for field in ("zip", "pkg", "dmg", "sh", "tar", "exe", "ps1", "source_sh"):
            n = rel.get(field)
            if n:
                names.add(n)
    for row in data.get("archive") or []:
        for field in ("zip", "pkg", "dmg", "sh"):
            n = row.get(field)
            if n:
                names.add(n)
    for extra in (
        "install-rNitro.sh",
        "install-rNitro-experimental.sh",
        "install-rNitro-intel.sh",
        "install-rNitro-linux.sh",
        "install-rNitro-windows.ps1",
        "rNitro-macOS-Apps.zip",
        "rNitro-CLI.tar.gz",
        "rNitro-Older-MacOS-Support-Info.zip",
    ):
        names.add(extra)

    for name in sorted(names):
        src = SITE / name
        if not src.is_file():
            continue
        shutil.copy2(src, OUT / name)
        print(f"  + rnitro/{name} ({src.stat().st_size / (1024 * 1024):.1f} MB)")



def _inject_file_manifest(out_dir: Path) -> None:
    """Embed shipped filenames so the download UI knows what is on this mirror."""
    import json
    index = out_dir / "index.html"
    if not index.is_file():
        return
    names = sorted(p.name for p in out_dir.iterdir() if p.is_file() and not p.name.startswith("."))
    entries = ", ".join(json.dumps(n) for n in names)
    marker = "  const RNITRO_FILES = window.RNITRO_FILES || null;"
    inject = f"  const RNITRO_FILES = new Set([{entries}]);"
    text = index.read_text(encoding="utf-8")
    if marker in text:
        index.write_text(text.replace(marker, inject, 1), encoding="utf-8")
        print(f"  + injected RNITRO_FILES ({len(names)} names)")


def main() -> None:
    if not SITE.is_dir():
        raise SystemExit(f"Missing product site: {SITE}")
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    # Remove transitional macbar tree if present
    macbar = HQ / "macbar"
    if macbar.exists():
        shutil.rmtree(macbar)
        print("  removed macbar/")

    for name in COPY_FILES:
        src = SITE / name
        if not src.is_file():
            print(f"  skip missing {name}")
            continue
        dst = OUT / name
        if src.suffix.lower() in {".html", ".js", ".json", ".txt", ".xml", ".css"}:
            raw = src.read_text(encoding="utf-8", errors="replace")
            dst.write_text(rewrite_text(raw, is_html=src.suffix.lower() == ".html"), encoding="utf-8")
        else:
            shutil.copy2(src, dst)
        print(f"  + rnitro/{name}")

    _copy_release_binaries()

    shots = SITE / "screenshots"
    if shots.is_dir():
        dest = OUT / "screenshots"
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(shots, dest)
        print("  + rnitro/screenshots/")

    videos = SITE / "videos"
    if videos.is_dir():
        dest_v = OUT / "videos"
        if dest_v.exists():
            shutil.rmtree(dest_v)
        shutil.copytree(videos, dest_v)
        print("  + rnitro/videos/")

    (OUT / "_redirects").write_text(
        "/rnitro/cli  /rnitro/cli.html  301\n"
        "/rnitro/linux  /rnitro/linux.html  301\n"
        "/rnitro/windows  /rnitro/windows.html  301\n"
        "/rnitro/privacy  /rnitro/privacy.html  301\n"
        "/rnitro/terms  /rnitro/terms.html  301\n"
        "/rnitro/faq  /rnitro/faq.html  301\n"
        "/rnitro/archives  /rnitro/archives.html  301\n",
        encoding="utf-8",
    )
    _inject_file_manifest(OUT)
    print(f"Done → {OUT} ({ASSET_ORIGIN})")


if __name__ == "__main__":
    main()
