#!/usr/bin/env bash
# /usr/local/sbin/svx_history_rotate.sh
# Udržuje jen posledních N záznamů v RAM a archivuje starší historii z disku do 7z.
set -euo pipefail

HIST_FULL="/var/log/svxlink/history.csv"
HIST_RAM="/dev/shm/svx/history.csv"
ARCH_DIR="/var/log/svxlink/archive"
LOCK="/var/log/svxlink/history.lock"
MAX=28
ARCH_MIN_LINES=200   # archivovat až když je na disku aspoň tolik řádků

mkdir -p "$(dirname "$HIST_FULL")" "$ARCH_DIR" "$(dirname "$HIST_RAM")"

# lock (advisory)
exec 9>"$LOCK"
flock -n 9 || exit 0

[ -f "$HIST_FULL" ] || exit 0
LINES=$(wc -l < "$HIST_FULL" || echo 0)
if [ "$LINES" -le "$MAX" ]; then
  # jen zrcadli posledních MAX do RAM
  tail -n "$MAX" "$HIST_FULL" > "$HIST_RAM".tmp || true
  mv -f "$HIST_RAM".tmp "$HIST_RAM"
  chmod 0664 "$HIST_RAM" || true
  exit 0
fi

# zrcadli posledních MAX do RAM i do nového FULL
tail -n "$MAX" "$HIST_FULL" > "$HIST_RAM".tmp
mv -f "$HIST_RAM".tmp "$HIST_RAM"
chmod 0664 "$HIST_RAM" || true

if [ "$LINES" -lt "$ARCH_MIN_LINES" ]; then
  # Ještě nearchivujeme, jen udrž RAM a případně FULL lze zkrátit
  tmpfull="$(mktemp)"
  tail -n "$MAX" "$HIST_FULL" > "$tmpfull"
  mv -f "$tmpfull" "$HIST_FULL"
  chmod 0664 "$HIST_FULL" || true
  chown svxlink:www-data "$HIST_FULL" "$HIST_RAM" 2>/dev/null || true
  exit 0
fi

# ARCHIVACE: odděl starší část (bez posledních MAX) a zkomprimuj
ts="$(date +%Y%m%d-%H%M%S)"
workdir="$(mktemp -d)"
head -n "-$MAX" "$HIST_FULL" > "$workdir/to_archive.jsonl" || true

# vytvoř nový FULL jen s posledními MAX
tail -n "$MAX" "$HIST_FULL" > "$workdir/last.jsonl"
mv -f "$workdir/last.jsonl" "$HIST_FULL"
chmod 0664 "$HIST_FULL" || true

# zkomprimuj starší část
mkdir -p "$ARCH_DIR"
archive="$ARCH_DIR/history-$ts.7z"
if command -v 7z >/dev/null 2>&1; then
  7z a -t7z -mx=5 "$archive" "$workdir/to_archive.jsonl" >/dev/null
else
  gzip -c "$workdir/to_archive.jsonl" > "$archive.gz"
fi

# úklid
rm -f "$workdir/to_archive.jsonl"
rmdir "$workdir" 2>/dev/null || true
chown svxlink:www-data "$HIST_FULL" "$HIST_RAM" 2>/dev/null || true
chown -R svxlink:www-data "$ARCH_DIR" 2>/dev/null || true
