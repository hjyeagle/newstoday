#!/usr/bin/env bash
# Refresh the GitHub Pages backup mirror of https://newstoday.co.kr/
#
# 1. Refuse to run unless the live homepage is the Cafe24 WordPress site.
# 2. wget --mirror the public site (robots honored, polite wait), including
#    wp-content assets. Skip wp-admin, wp-login, xmlrpc, feeds, and
#    query-string duplicates. Sitemap URLs are extra start points so published
#    pages that are not linked from the homepage are still backed up.
# 3. Rewrite newstoday.co.kr links (http/https, www) to relative links that
#    work under /newstoday/, then add noindex + canonical, robots.txt, and
#    .nojekyll.
#
# Env:
#   MIRROR_WAIT   seconds between requests (default 1; wget also random-waits)
#   MIRROR_DEST   output directory (default: repository root)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT="${MIRROR_WAIT:-1}"
DEST="${MIRROR_DEST:-$ROOT}"
UA="newstoday-backup-mirror/1.0 (+https://github.com/hjyeagle/newstoday; polite backup)"

# Cafe24's daily transfer cap was nearly used up on 2026-11-04.
# Do not open new connections to the host during that UTC day.
if [[ "$(date -u +%Y-%m-%d)" == "2026-11-04" ]]; then
  echo "Refusing to contact https://newstoday.co.kr/ on 2026-11-04 UTC." >&2
  echo "The Cafe24 daily traffic cap was nearly exhausted. Run this again after the cap resets." >&2
  exit 3
fi

echo "Verifying https://newstoday.co.kr/ serves WordPress..."
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
curl -fsSL -A "$UA" --max-time 45 -o "$body" "https://newstoday.co.kr/"
python3 - "$body" << 'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text("utf-8", "replace")
has_wp = ("wp-content" in text) and (
    "WordPress" in text or "wp-includes" in text or "/wp-json/" in text
)
old_github = ('name="naver-site-verification"' in text or "bookTitles" in text) and (
    "wp-content" not in text
)
if old_github or not has_wp:
    sys.stderr.write(
        "Refusing to mirror: https://newstoday.co.kr/ is not the Cafe24 WordPress site "
        "(it still looks like the old GitHub Pages site, or the check failed).\n"
    )
    raise SystemExit(2)
print("Live homepage is WordPress.")
PY

if [[ -n "${MIRROR_WORKDIR:-}" ]]; then
  WORKDIR="${MIRROR_WORKDIR}"
  mkdir -p "$WORKDIR"
  # Keep a resumed download tree if post-processing fails.
  trap 'rm -f "$body"' EXIT
else
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"; rm -f "$body"' EXIT
fi
FETCH="$WORKDIR/fetch"
mkdir -p "$FETCH"
URLS="$WORKDIR/urls.txt"

python3 - "$URLS" "$UA" << 'PY'
import re
import sys
import urllib.request
from urllib.parse import urlsplit

out_path, ua = sys.argv[1], sys.argv[2]
skip = re.compile(
    r"(?i)(/wp-admin(?:/|$)|/wp-login\.php|/xmlrpc\.php|/wp-json(?:/|$)"
    r"|/feed(?:/|$)|/comments/feed(?:/|$)|/oembed(?:/|$)|/trackback(?:/|$)"
    r"|/embed(?:/|$)|[?&](?:replytocom|s|p|format|utm_[^=]*|fbclid|share|like)="
    r")"
)

def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": ua})
    with urllib.request.urlopen(req, timeout=45) as resp:
        return resp.read().decode("utf-8", "replace")

locs = re.findall(r"<loc>(.*?)</loc>", fetch("https://newstoday.co.kr/wp-sitemap.xml"))
urls = ["https://newstoday.co.kr/"]
for loc in locs:
    if not loc.startswith("https://newstoday.co.kr/"):
        continue
    xml = fetch(loc)
    for page in re.findall(r"<loc>(.*?)</loc>", xml):
        page = page.strip()
        parts = urlsplit(page)
        if parts.netloc.lower().removeprefix("www.") != "newstoday.co.kr":
            continue
        if skip.search(page):
            continue
        urls.append(page.split("#", 1)[0])

seen = set()
ordered = []
for url in urls:
    if url not in seen:
        seen.add(url)
        ordered.append(url)
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(ordered) + "\n")
print(f"Seed URLs: {len(ordered)}")
PY

if [[ -n "${MIRROR_URL_LIMIT:-}" ]]; then
  head -n "${MIRROR_URL_LIMIT}" "$URLS" > "$URLS.limited"
  mv "$URLS.limited" "$URLS"
  echo "URL list limited to ${MIRROR_URL_LIMIT} seeds."
fi

WGET_EXTRA=()
if [[ -n "${MIRROR_WGET_EXTRA:-}" ]]; then
  # Optional extra wget flags. Defaults are empty so a normal run is a full mirror.
  read -r -a WGET_EXTRA <<< "${MIRROR_WGET_EXTRA}"
fi

echo "Mirroring with wget (wait=${WAIT}s, robots on)..."
set +e
wget \
  --mirror \
  --page-requisites \
  --convert-links \
  --adjust-extension \
  --no-parent \
  --execute robots=on \
  --wait="$WAIT" \
  --random-wait \
  --timeout=40 \
  --tries=3 \
  --waitretry=10 \
  --retry-on-http-error=429,500,502,503,504 \
  --user-agent="$UA" \
  --domains=newstoday.co.kr,www.newstoday.co.kr \
  --span-hosts \
  --restrict-file-names=unix \
  --regex-type=pcre \
  --reject-regex='(?i)(/wp-admin(?:/|$)|/wp-login\.php|/xmlrpc\.php|/wp-json(?:/|$)|/feed(?:/|$)|/comments/feed(?:/|$)|/oembed(?:/|$)|/trackback(?:/|$)|/embed(?:/|$)|[?&](?:replytocom|s|p|format|utm_[^=]*|fbclid|share|like)=)' \
  --reject=xmlrpc.php,wp-login.php \
  --exclude-directories=wp-admin,wp-json \
  --no-host-directories \
  --directory-prefix="$FETCH" \
  --input-file="$URLS" \
  "${WGET_EXTRA[@]}"
wcode=$?
set -e
if [[ ! -f "$FETCH/index.html" ]]; then
  echo "Mirror failed: homepage was not saved (wget exit ${wcode})." >&2
  exit 1
fi
if [[ "$wcode" -ne 0 ]]; then
  echo "wget finished with exit ${wcode}; continuing with saved files."
fi

python3 - "$FETCH" "$DEST" "$WAIT" "$UA" << 'PY'
import html
import os
import posixpath
import random
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

fetch = Path(sys.argv[1])
dest = Path(sys.argv[2])
wait = float(sys.argv[3])
ua = sys.argv[4]

ASSET_EXT = {
    ".css", ".js", ".mjs", ".map", ".jpg", ".jpeg", ".png", ".gif", ".webp",
    ".svg", ".avif", ".ico", ".bmp", ".woff", ".woff2", ".ttf", ".otf", ".eot",
    ".mp4", ".webm", ".pdf",
}
ASSET_HTML_SUFFIXES = tuple(ext + ".html" for ext in sorted(ASSET_EXT, key=len, reverse=True))
TEXT_EXT = {".html", ".css", ".js", ".mjs", ".svg", ".xml", ".txt", ".map", ".json"}
PRESERVE = {".git", ".github", "scripts", "docs", "README.md"}

ABS_RE = re.compile(
    r"(?i)https?://(?:www\.)?newstoday\.co\.kr[^\s\"'<>\\)|]*"
    r"|https?:\\/\\/(?:www\.)?newstoday\.co\.kr(?:\\/|[^\s\"'<>\\)|])*"
    r"|(?<![:\w/])//(?:www\.)?newstoday\.co\.kr[^\s\"'<>\\)|]*"
)
ATTR_RE = re.compile(
    r"(?P<pre>\b(?:href|src|action|poster|data-src|data-lazy-src|data-orig-file)\s*=\s*)"
    r"(?P<q>[\"'])(?P<url>.*?)(?P=q)",
    re.I | re.S,
)
SRCSET_RE = re.compile(
    r"(?P<pre>\bsrcset\s*=\s*)(?P<q>[\"'])(?P<val>.*?)(?P=q)",
    re.I | re.S,
)
CSSURL_RE = re.compile(r"url\(\s*(?P<q>[\"']?)(?P<url>.*?)(?P=q)\s*\)", re.I | re.S)
CANON_RE = re.compile(
    r"<link\b[^>]*\brel\s*=\s*[\"']canonical[\"'][^>]*>",
    re.I,
)
HEAD_RE = re.compile(r"<head\b[^>]*>", re.I)
CHARSET_RE = re.compile(r"<meta\b[^>]*charset[^>]*>", re.I)


def looks_like_html(data: bytes) -> bool:
    sample = data.lstrip()[:300].lower()
    return sample.startswith((b"<!doctype html", b"<html", b"<head", b"<?xml"))


def normalize_path(path: str) -> str:
    path = unquote(path or "")
    path = path.replace("\\", "/")
    path = path.split("#", 1)[0]
    # wget --restrict-file-names encodes "?" as "%3F" and --adjust-extension
    # then appends .css/.js after the query. Drop the query so both the file
    # and the link use the stable asset name (main.min.css, not main.min.css?ver=…).
    path = path.split("?", 1)[0]
    path = re.sub(r"/+", "/", path).lstrip("/")
    if path in ("", "."):
        return ""
    parts = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if parts:
                parts.pop()
            continue
        parts.append(part)
    return "/".join(parts)


def is_skipped_path(path: str) -> bool:
    p = normalize_path(path).lower()
    if not p:
        return False
    if p.startswith((
        "wp-admin/", "wp-admin", "wp-json/", "wp-json", "wp-login.php", "xmlrpc.php",
    )):
        return True
    segments = p.split("/")
    if segments[-1] in {"feed", "embed", "trackback", "oembed", "xmlrpc.php", "wp-login.php"}:
        return True
    if "wp-login.php" in segments or "xmlrpc.php" in segments:
        return True
    return False


def is_asset_path(path: str) -> bool:
    ext = posixpath.splitext(normalize_path(path).lower())[1]
    return ext in ASSET_EXT


def delete_skipped(root: Path) -> None:
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        base = Path(dirpath).name.lower()
        rel = Path(dirpath).relative_to(root).as_posix()
        for fn in filenames:
            low = fn.lower()
            full = Path(dirpath) / fn
            if low in {"xmlrpc.php", "wp-login.php", "robots.txt"} or low.startswith("wp-login"):
                full.unlink(missing_ok=True)
            elif low.endswith(".listing"):
                full.unlink(missing_ok=True)
        if base in {"wp-admin", "wp-json", "feed", "oembed", "trackback", "embed"} and rel not in {".", ""}:
            shutil.rmtree(dirpath, ignore_errors=True)


def normalize_names(root: Path) -> None:
    files = [p for p in root.rglob("*") if p.is_file()]
    for path in files:
        if not path.exists():
            continue
        name = unquote(path.name)
        if "?" not in name and "@ver=" not in name:
            continue
        base = name.split("?", 1)[0]
        if "@ver=" in base:
            base = base.split("@ver=", 1)[0]
        if not base or base in {".", ".."}:
            path.unlink(missing_ok=True)
            continue
        # Query-string copies of HTML are duplicates of the extensionless page.
        if base.endswith(".html") or base.endswith(".php"):
            path.unlink(missing_ok=True)
            continue
        dest_path = path.with_name(base)
        if dest_path.exists():
            path.unlink(missing_ok=True)
        else:
            path.rename(dest_path)

    files = [p for p in root.rglob("*") if p.is_file()]
    for path in files:
        lower = path.name.lower()
        for suffix in ASSET_HTML_SUFFIXES:
            if lower.endswith(suffix):
                sample = path.read_bytes()[:400]
                if looks_like_html(sample):
                    break
                dest_path = path.with_name(path.name[: -len(".html")])
                if dest_path.exists():
                    path.unlink(missing_ok=True)
                else:
                    path.rename(dest_path)
                break


def fold_html_aliases(root: Path) -> None:
    pages = []
    for path in root.rglob("*.html"):
        rel = path.relative_to(root).as_posix()
        if rel.startswith(("wp-content/", "wp-includes/")):
            continue
        if rel == "index.html" or rel.endswith("/index.html"):
            continue
        sample = path.read_bytes()[:500].lower()
        if b"<html" not in sample and b"<!doctype html" not in sample:
            continue
        pages.append(path)
    for path in pages:
        rel = path.relative_to(root).as_posix()
        stem = rel[: -len(".html")]
        target = root / stem / "index.html"
        if target.exists():
            path.unlink(missing_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            path.rename(target)


def existing_candidates(path: str):
    norm = normalize_path(path)
    cands = []
    if norm == "":
        cands.append("index.html")
    else:
        cands.append(norm)
        lower = norm.lower()
        for suffix in ASSET_HTML_SUFFIXES:
            if lower.endswith(suffix):
                cands.append(norm[: -len(".html")])
        if norm.endswith("/"):
            cands.append(norm + "index.html")
        else:
            cands.append(norm + "/index.html")
            if norm.endswith(".html") and not norm.endswith("/index.html"):
                cands.append(norm[: -len(".html")] + "/index.html")
            else:
                cands.append(norm + ".html")
    seen = set()
    for cand in cands:
        cand = normalize_path(cand)
        if not cand or cand in seen:
            continue
        seen.add(cand)
        yield cand


def resolve_existing(path: str):
    for cand in existing_candidates(path):
        if (fetch / cand).is_file():
            return cand
    return None


def fallback_path(path: str) -> str:
    norm = normalize_path(path.split("?", 1)[0].split("#", 1)[0])
    if is_asset_path(norm):
        return norm
    if norm == "" or norm.endswith("/index.html"):
        return norm or "index.html"
    if norm.endswith(".html"):
        if norm.endswith("/index.html"):
            return norm
        return norm[: -len(".html")] + "/index.html"
    if norm.endswith("/"):
        return norm + "index.html"
    # Extensionless WordPress permalink.
    if posixpath.splitext(norm)[1] == "":
        return norm + "/index.html"
    return norm


def to_rel(from_file: str, target: str) -> str:
    src_dir = posixpath.dirname(from_file)
    rel = posixpath.relpath(target, src_dir or ".")
    return rel


def parse_site_url(raw: str):
    text = html.unescape(raw.strip()).replace("\\/", "/")
    if text.startswith("//"):
        text = "https:" + text
    if not text.lower().startswith(("http://", "https://")):
        return None
    frag = ""
    if "#" in text:
        text, frag = text.split("#", 1)
        frag = "#" + frag
    parts = urlsplit(text)
    host = parts.netloc.lower().removeprefix("www.")
    if host != "newstoday.co.kr":
        return None
    return parts.path or "/", parts.query, frag


def map_absolute(raw: str, from_file: str) -> str:
    parsed = parse_site_url(raw)
    if parsed is None:
        return raw
    path, _query, frag = parsed
    local = resolve_existing(path)
    if local is None:
        local = fallback_path(path)
    return to_rel(from_file, local) + frag


def repair_reference(url: str, from_file: str) -> str:
    raw = url.strip()
    if not raw or raw.startswith(("#", "mailto:", "tel:", "javascript:", "data:", "sms:")):
        return url
    if raw.startswith(("http://", "https://", "//", "http:\\", "https:\\")):
        return map_absolute(raw, from_file)
    text = html.unescape(raw)
    base, _, frag = text.partition("#")
    path_part, _, _query = base.partition("?")
    if path_part.startswith("/"):
        joined = normalize_path(path_part)
    else:
        src_dir = posixpath.dirname(from_file)
        joined = normalize_path(posixpath.join(src_dir, path_part))
    local = resolve_existing(joined if joined else "/")
    if local is None:
        # Leave already-relative links alone when we cannot see a better file.
        if raw.startswith(("http://", "https://", "//", "http:\\", "https:\\")):
            return map_absolute(raw, from_file)
        return url
    suffix = ("#" + frag) if frag else ""
    new = to_rel(from_file, local) + suffix
    decoded = unquote(path_part)
    if "?" in decoded or "%3f" in path_part.lower() or _query:
        return new
    if any(decoded.lower().endswith(suffix_html) for suffix_html in ASSET_HTML_SUFFIXES):
        return new
    new_path = new.split("#", 1)[0]
    if posixpath.normpath(path_part) == posixpath.normpath(new_path):
        return url
    return new


def rewrite_text(text: str, from_file: str) -> str:
    def abs_sub(match: re.Match) -> str:
        return map_absolute(match.group(0), from_file)

    text = ABS_RE.sub(abs_sub, text)

    def attr_sub(match: re.Match) -> str:
        new = repair_reference(match.group("url"), from_file)
        return match.group("pre") + match.group("q") + new + match.group("q")

    text = ATTR_RE.sub(attr_sub, text)

    def srcset_sub(match: re.Match) -> str:
        bits = []
        for part in match.group("val").split(","):
            item = part.strip()
            if not item:
                continue
            pieces = item.split()
            pieces[0] = repair_reference(pieces[0], from_file)
            bits.append(" ".join(pieces))
        return match.group("pre") + match.group("q") + ", ".join(bits) + match.group("q")

    text = SRCSET_RE.sub(srcset_sub, text)

    def css_sub(match: re.Match) -> str:
        url = match.group("url").strip()
        if not url or url.startswith("data:"):
            return match.group(0)
        new = repair_reference(url, from_file)
        quote = match.group("q") or ""
        return f"url({quote}{new}{quote})"

    return CSSURL_RE.sub(css_sub, text)


def canonical_for(rel: str) -> str:
    rel = rel.replace("\\", "/")
    if rel == "index.html":
        suffix = ""
    elif rel.endswith("/index.html"):
        suffix = rel[: -len("index.html")]
    elif rel.endswith(".html"):
        suffix = rel[: -len(".html")]
        if not suffix.endswith("/"):
            suffix += "/"
    else:
        suffix = rel
    return "https://newstoday.co.kr/" + suffix


def inject_meta(text: str, rel: str) -> str:
    text = CANON_RE.sub("", text)
    text = re.sub(
        r"<meta\b[^>]*\bname\s*=\s*[\"']robots[\"'][^>]*\bcontent\s*=\s*[\"']noindex,nofollow[\"'][^>]*>\s*",
        "",
        text,
        flags=re.I,
    )
    # Also the reversed attribute order.
    text = re.sub(
        r"<meta\b[^>]*\bcontent\s*=\s*[\"']noindex,nofollow[\"'][^>]*\bname\s*=\s*[\"']robots[\"'][^>]*>\s*",
        "",
        text,
        flags=re.I,
    )
    snippet = (
        '\n<meta name="robots" content="noindex,nofollow">'
        f'\n<link rel="canonical" href="{canonical_for(rel)}">'
    )
    charset = CHARSET_RE.search(text)
    if charset:
        insert_at = charset.end()
        return text[:insert_at] + snippet + text[insert_at:]
    head = HEAD_RE.search(text)
    if not head:
        return text
    insert_at = head.end()
    return text[:insert_at] + snippet + text[insert_at:]


def iter_text_files():
    for path in fetch.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() in TEXT_EXT or path.name.lower() in {"index.html"}:
            yield path


def collect_asset_paths() -> set[str]:
    found = set()

    def consider(path: str) -> None:
        norm = normalize_path(path)
        if not norm or is_skipped_path(norm) or not is_asset_path(norm):
            return
        if resolve_existing(norm):
            return
        found.add(norm)

    for path in iter_text_files():
        try:
            text = path.read_text("utf-8", "replace")
        except OSError:
            continue
        rel = path.relative_to(fetch).as_posix()
        for match in ABS_RE.finditer(text):
            parsed = parse_site_url(match.group(0))
            if not parsed:
                continue
            consider(parsed[0])
        for match in CSSURL_RE.finditer(text):
            url = html.unescape(match.group("url").strip()).replace("\\/", "/")
            if not url or url.startswith("data:"):
                continue
            if url.startswith(("http://", "https://", "//")):
                parsed = parse_site_url(url)
                if parsed:
                    consider(parsed[0])
                continue
            src_dir = posixpath.dirname(rel)
            consider(posixpath.normpath(posixpath.join(src_dir, url.split("?", 1)[0].split("#", 1)[0])))
        for match in ATTR_RE.finditer(text):
            url = html.unescape(match.group("url").strip())
            if url.startswith(("http://", "https://", "//")):
                parsed = parse_site_url(url)
                if parsed:
                    consider(parsed[0])
    return found


def remote_for(path: str) -> str:
    parts = [quote(unquote(part), safe="") for part in normalize_path(path).split("/") if part != ""]
    return "https://newstoday.co.kr/" + "/".join(parts)


def download_assets() -> tuple[int, list[str]]:
    pending = collect_asset_paths()
    saved = 0
    failed = []
    seen = set()
    while pending:
        batch = pending
        pending = set()
        for rel in sorted(batch):
            if rel in seen:
                continue
            seen.add(rel)
            target = fetch / rel
            if target.is_file() and target.stat().st_size > 0:
                continue
            url = remote_for(rel)
            data = None
            last_err = ""
            for attempt in range(3):
                try:
                    req = urllib.request.Request(url, headers={"User-Agent": ua})
                    with urllib.request.urlopen(req, timeout=45) as resp:
                        data = resp.read()
                    break
                except Exception as exc:  # noqa: BLE001 - keep mirroring if one asset fails
                    last_err = f"{type(exc).__name__}: {exc}"
                    time.sleep(wait)
            time.sleep(wait * random.uniform(0.5, 1.5))
            if data is None:
                failed.append(f"{url} ({last_err})")
                continue
            if is_asset_path(rel) and looks_like_html(data) and posixpath.splitext(rel)[1].lower() not in {".svg", ".xml"}:
                failed.append(f"{url} (HTML response for a static asset)")
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            saved += 1
            if saved % 25 == 0:
                print(f"  saved {saved} extra assets...")
            if target.suffix.lower() in {".css", ".js", ".mjs", ".svg"}:
                text = data.decode("utf-8", "replace")
                extra = set()
                for match in ABS_RE.finditer(text):
                    parsed = parse_site_url(match.group(0))
                    if parsed:
                        extra.add(normalize_path(parsed[0]))
                for match in CSSURL_RE.finditer(text):
                    url_ref = html.unescape(match.group("url").strip()).replace("\\/", "/")
                    if not url_ref or url_ref.startswith("data:"):
                        continue
                    if url_ref.startswith(("http://", "https://", "//")):
                        parsed = parse_site_url(url_ref)
                        if parsed:
                            extra.add(normalize_path(parsed[0]))
                        continue
                    joined = normalize_path(posixpath.join(posixpath.dirname(rel), url_ref.split("?", 1)[0]))
                    extra.add(joined)
                for item in extra:
                    if item and is_asset_path(item) and not is_skipped_path(item) and not (fetch / item).is_file():
                        if item not in seen:
                            pending.add(item)
    return saved, failed


def rewrite_tree() -> int:
    changed = 0
    files = list(iter_text_files())
    for path in files:
        rel = path.relative_to(fetch).as_posix()
        text = path.read_text("utf-8", "replace")
        updated = rewrite_text(text, rel)
        if path.suffix.lower() == ".html" and ("<head" in updated.lower() or "<html" in updated.lower()):
            updated = inject_meta(updated, rel)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            changed += 1
    return changed


def write_mirror_files() -> None:
    (fetch / "robots.txt").write_text("User-agent: *\nDisallow: /\n", encoding="utf-8")
    (fetch / ".nojekyll").write_bytes(b"")
    readme = """# 뉴스투데이 백업 미러

이 저장소의 GitHub Pages
([https://hjyeagle.github.io/newstoday/](https://hjyeagle.github.io/newstoday/))는
운영 중인 WordPress 사이트 [https://newstoday.co.kr/](https://newstoday.co.kr/) 의
백업·테스트용 정적 미러입니다. 검색엔진이 이 복사본을 수집하지 않도록
모든 HTML에 `noindex,nofollow`를 넣었고, `robots.txt`는 `Disallow: /` 입니다.

정식 사이트 주소는 항상 [https://newstoday.co.kr/](https://newstoday.co.kr/) 입니다.
각 HTML 문서의 `canonical`은 같은 경로의 정식 주소를 가리킵니다.

## 다시 받기

저장소 루트에서 실행합니다.

```bash
bash scripts/mirror-wp.sh
```

GitHub에서는 Actions의 **Mirror WordPress** 워크플로를
`workflow_dispatch`(Run workflow)로 실행합니다. 예약 실행은 없습니다.
스크립트가 사이트를 다시 받은 뒤 워크플로가 변경분을 커밋합니다.

검색, 댓글 등록, 문의·뉴스레터 폼 전송, 로그인, 관리자 화면처럼
서버가 처리하는 기능은 정적 미러에서 동작하지 않습니다.

Cafe24 일일 전송량은 약 4GB입니다. 한도에 가까우면 이 스크립트를 실행하지 마세요.
2026-11-04(UTC)에는 한도가 거의 소진되어 받기를 중단했고, 그날은 스크립트가
접속을 거부합니다. 이 커밋의 파일은 그때까지 받은 **일부**입니다.
맛집(`restaurant`) 글 상당수와 카테고리 한 곳은 빠졌습니다.
"""
    return readme


def sync_into(src: Path, target: Path, readme: str) -> None:
    target.mkdir(parents=True, exist_ok=True)
    if src.resolve() != target.resolve():
        for child in list(target.iterdir()):
            if child.name in PRESERVE:
                continue
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink()
        for path in src.rglob("*"):
            rel = path.relative_to(src)
            out = target / rel
            if path.is_dir():
                out.mkdir(parents=True, exist_ok=True)
            elif path.is_file():
                out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, out)
    cname = target / "CNAME"
    if cname.exists():
        cname.unlink()
    (target / "README.md").write_text(readme, encoding="utf-8")
    (target / "robots.txt").write_text("User-agent: *\nDisallow: /\n", encoding="utf-8")
    (target / ".nojekyll").write_bytes(b"")


def summarize() -> None:
    pages = 0
    total = 0
    leftover = []
    for path in fetch.rglob("*"):
        if not path.is_file():
            continue
        total += path.stat().st_size
        if path.suffix.lower() != ".html":
            continue
        sample = path.read_bytes()[:200].lower()
        if b"<html" in sample or b"<!doctype html" in sample:
            pages += 1
            if pages <= 4000:
                text = path.read_text("utf-8", "replace")
                # Canonical links are supposed to stay absolute.
                stripped = CANON_RE.sub("", text)
                hits = re.findall(r"https?://(?:www\.)?newstoday\.co\.kr", stripped, flags=re.I)
                hits += re.findall(r"https?:\\/\\/(?:www\.)?newstoday\.co\.kr", stripped, flags=re.I)
                if hits and len(leftover) < 8:
                    leftover.append(f"{path.relative_to(fetch).as_posix()} ({len(hits)})")
    print(f"HTML pages: {pages}")
    print(f"Total size bytes: {total}")
    if leftover:
        print("Absolute newstoday.co.kr links still outside canonical:")
        for line in leftover:
            print(" ", line)


print("Normalizing downloaded filenames...")
normalize_names(fetch)
delete_skipped(fetch)
# Drop query-string filenames that are still HTML duplicates or unusable.
for path in list(fetch.rglob("*")):
    if path.is_file() and "?" in path.name:
        path.unlink(missing_ok=True)
fold_html_aliases(fetch)
print("Downloading referenced wp-content/wp-includes assets wget did not save...")
saved, failed = download_assets()
print(f"Extra assets saved: {saved}")
if failed:
    print(f"Assets that could not be fetched: {len(failed)}")
    for line in failed[:40]:
        print(" ", line)
    if len(failed) > 40:
        print(f"  ... {len(failed) - 40} more")
print("Rewriting links and adding noindex/canonical...")
rewrite_tree()
readme = write_mirror_files()
sync_into(fetch, dest, readme)
summarize()
if failed:
    # Non-fatal: pages are still mirrored. Listed above.
    pass
PY

echo "Mirror written to ${DEST}"
