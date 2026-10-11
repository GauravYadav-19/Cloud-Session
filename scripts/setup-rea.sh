#!/usr/bin/env bash
# Installs the external analysis engines that the REA MCP server (rea-agents)
# drives. Idempotent: each step is skipped when its pinned version is present.
# Paths here must match the env block of the "rea" server in .mcp.json.
set -uo pipefail

REA_VENV=/opt/rea-venv
GHIDRA_LINK=/opt/ghidra

log() { echo "[setup-rea] $*" >&2; }

# Python tools: pwntools (ELF layout), unblob (firmware), mitmdump (captures).
if ! "$REA_VENV/bin/python" -c 'import pwn; assert pwn.version == "4.15.0"' 2>/dev/null \
  || ! "$REA_VENV/bin/unblob" --version 2>/dev/null | grep -q '^26\.6\.4' \
  || ! "$REA_VENV/bin/mitmdump" --version 2>/dev/null | grep -q '12\.2\.3'; then
  log "installing Python tools into $REA_VENV"
  python3 -m venv "$REA_VENV"
  "$REA_VENV/bin/pip" install -q \
    'pwntools==4.15.0' 'pyelftools==0.33' 'unicorn==2.1.2' \
    'unblob==26.6.4' 'mitmproxy==12.2.3' || log "WARN: pip install failed"
fi

# apt tools: Apktool, adb, prlimit, and the extractors firmware carving shells out to.
missing=()
for bin in apktool adb prlimit 7z lz4 zstd unsquashfs cabextract; do
  command -v "$bin" >/dev/null || missing+=("$bin")
done
if ((${#missing[@]})); then
  log "installing apt packages (missing: ${missing[*]})"
  export DEBIAN_FRONTEND=noninteractive
  { apt-get update -q && apt-get install -y -q apktool adb util-linux p7zip-full lz4 zstd \
      squashfs-tools cabextract; } >/dev/null 2>&1 || log "WARN: apt install failed"
fi

# Binwalk 3.1.0 is a Rust crate; the Ubuntu package is the old 2.x line.
if ! binwalk --version 2>/dev/null | grep -q '^binwalk 3\.1\.0'; then
  log "building binwalk 3.1.0 with cargo (about a minute)"
  cargo install -q binwalk --version 3.1.0 --locked || log "WARN: binwalk build failed"
fi
ln -sf "$HOME/.cargo/bin/binwalk" /usr/local/bin/binwalk 2>/dev/null || true

# Wakaru (JavaScript source recovery).
if ! wakaru --version 2>/dev/null | grep -q '1\.14\.0'; then
  log "installing wakaru 1.14.0"
  npm install -g -q @wakaru/cli@1.14.0 >/dev/null 2>&1 || log "WARN: wakaru install failed"
fi
ln -sf "$(command -v wakaru 2>/dev/null || echo /opt/node22/bin/wakaru)" /usr/local/bin/wakaru 2>/dev/null || true

# Ghidra 12.1.x (native decompilation). Published only on GitHub releases, so
# this needs github.com and objects.githubusercontent.com in the network policy.
if [ ! -x "$GHIDRA_LINK/support/analyzeHeadless" ]; then
  url=$(curl -fsS --max-time 20 \
      https://api.github.com/repos/NationalSecurityAgency/ghidra/releases?per_page=30 2>/dev/null \
    | python3 -c 'import json,sys
for r in json.load(sys.stdin):
    if r["tag_name"].startswith("Ghidra_12.1"):
        for a in r["assets"]:
            if a["name"].endswith(".zip"):
                print(a["browser_download_url"]); sys.exit()' 2>/dev/null)
  if [ -n "$url" ]; then
    log "downloading $url"
    tmp=$(mktemp -d)
    if curl -fsSL --max-time 900 -o "$tmp/ghidra.zip" "$url" && unzip -q "$tmp/ghidra.zip" -d /opt; then
      dir=$(ls -d /opt/ghidra_12.1* | sort | tail -1)
      ln -sfn "$dir" "$GHIDRA_LINK"
      log "Ghidra installed at $dir"
    else
      log "WARN: Ghidra download failed"
    fi
    rm -rf "$tmp"
  else
    log "WARN: Ghidra unavailable (GitHub blocked by network policy?); native decompilation disabled"
  fi
fi

exit 0
