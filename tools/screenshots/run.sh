#!/bin/bash
# Regenerates screenshots/ by driving a headless KOReader through every Folio screen.
#
# Needs: KOReader's Linux build (koreader-linux-x86_64-*.tar.xz from the KOReader
# releases page, extracted), and a Folio device token for a test account
# (pair once with the plugin, then copy "token" from settings/folio.lua).
#
#   KOREADER=~/koreader/lib/koreader FOLIO_TOKEN=... tools/screenshots/run.sh
#
# Runs with SDL's offscreen driver, so no display is needed. The demo state it
# seeds (reading progress, highlights) lives in a throwaway HOME.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${KOREADER:?set KOREADER to the extracted lib/koreader folder}"
: "${FOLIO_TOKEN:?set FOLIO_TOKEN to a Folio device token}"
# COLOR=false renders the black & white palette (grayscale e-ink).
OUT="$ROOT/screenshots/$([ "${COLOR:-true}" = true ] && echo color || echo bw)"
mkdir -p "$OUT"
HOME_DIR="$(mktemp -d)"
mkdir -p "$HOME_DIR/.config/koreader" "$HOME_DIR/books"
cat > "$HOME_DIR/.config/koreader/settings.reader.lua" <<LUA
return { home_dir = "$HOME_DIR/books", lastdir = "$HOME_DIR/books", quickstart_shown_version = 999999999999, color_rendering = ${COLOR:-true} }
LUA
ln -sfn "$ROOT/folio.koplugin" "$KOREADER/plugins/folio.koplugin"
ln -sfn "$ROOT/tools/screenshots/shot.koplugin" "$KOREADER/plugins/shot.koplugin"
trap 'rm -f "$KOREADER/plugins/shot.koplugin"; rm -rf "$HOME_DIR"' EXIT
cd "$KOREADER"
HOME="$HOME_DIR" KO_MULTIUSER=1 SDL_VIDEO_DRIVER=offscreen \
  EMULATE_READER_W="${WIDTH:-1072}" EMULATE_READER_H="${HEIGHT:-1448}" EMULATE_READER_DPI=300 \
  SHOT_OUT="$OUT" SHOT_TOKEN="$FOLIO_TOKEN" SHOT_SERVER="${FOLIO_SERVER:-https://myfolio.so}" \
  timeout 400 ./reader.lua | grep -E "SHOT|STEP ERROR" || true
