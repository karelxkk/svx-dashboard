#!/usr/bin/env bash
set -euo pipefail
HIST_FULL="${SVX_HISTORY_DISK:-/var/log/svxlink/history.csv}"
ARCH_DIR="${SVX_HISTORY_ARCHIVE:-/var/log/svxlink/archive}"
LOCK_DIR="${SVX_LOCKDIR:-/run/lock/svxlink}"
HISTORY_LIMIT="${SVX_HISTORY_LIMIT:-28}"
CSV_HEADER="${CSV_HEADER:-ts;node;dur;tg}"
umask 002; mkdir -p "$(dirname "$HIST_FULL")" "$ARCH_DIR" "$LOCK_DIR"
exec 9>"$LOCK_DIR/rotate.lock"; flock -n 9 || exit 0
[[ -s "$HIST_FULL" ]] || exit 0
total=$(wc -l < "$HIST_FULL"); data_lines=$(( total>0 ? total-1 : 0 ))
(( data_lines > HISTORY_LIMIT )) || exit 0
ts="$(date -u +%Y%m%d-%H%M%S)"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
tail -n +2 "$HIST_FULL" >"$work/full.data"
to_archive=$(( data_lines - HISTORY_LIMIT ))
head -n "$to_archive" "$work/full.data" >"$work/to_archive.data"
tail -n "$HISTORY_LIMIT" "$work/full.data" >"$work/keep.data"
{ printf '%s\n' "$CSV_HEADER"; cat "$work/to_archive.data"; } >"$work/to_archive.csv"
{ printf '%s\n' "$CSV_HEADER"; cat "$work/keep.data"; } >"$work/keep.csv"
if command -v 7z >/dev/null 2>&1; then 7z a -t7z -mx=5 "$ARCH_DIR/history-$ts.7z" "$work/to_archive.csv" >/dev/null
else gzip -c "$work/to_archive.csv" > "$ARCH_DIR/history-$ts.csv.gz"; fi
mv -f "$work/keep.csv" "$HIST_FULL"; chown svxlink:www-data "$HIST_FULL" 2>/dev/null || true; chmod 0644 "$HIST_FULL" 2>/dev/null || true
