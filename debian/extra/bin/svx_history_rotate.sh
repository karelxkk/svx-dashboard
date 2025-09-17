#!/usr/bin/env bash
set -euo pipefail
HIST_RUN="${SVX_HISTORY:-/run/svxlink/history.csv}"
HIST_FULL="${SVX_HISTORY_DISK:-/var/log/svxlink/history.csv}"
ARCH_DIR="${SVX_HISTORY_ARCHIVE:-/var/log/svxlink/archive}"
LOCK_DIR="${SVX_LOCKDIR:-/run/lock/svxlink}"
SENT_LOCK="$LOCK_DIR/history.lock"; ROT_LOCK="$LOCK_DIR/rotate.lock"
HISTORY_LIMIT="${HISTORY_LIMIT:-${SVX_HISTORY_LIMIT:-28}}"
CSV_HEADER="${CSV_HEADER:-ts;node;dur;tg}"
ROTATOR_WAIT_MS="${ROTATOR_WAIT_MS:-500}"
umask 002; mkdir -p "$(dirname "$HIST_FULL")" "$ARCH_DIR" "$(dirname "$HIST_RUN")" "$LOCK_DIR"
exec 9>"$ROT_LOCK"; flock -n 9 || exit 0
now_ms(){ date +%s%3N; }; deadline=$(( $(now_ms) + ROTATOR_WAIT_MS ))
while [[ -e "$SENT_LOCK" && $(now_ms) -lt $deadline ]]; do sleep 0.02; done
[[ -e "$SENT_LOCK" ]] && exit 0
HEADER="$CSV_HEADER"
if [[ -f "$HIST_RUN" ]]; then
  mapfile -t data < <(tail -n +2 "$HIST_RUN" 2>/dev/null || true)
  printf '%s\n' "$HEADER" > "$HIST_RUN.tmp"
  ((${#data[@]})) && printf '%s\n' "${data[@]: -HISTORY_LIMIT}" >> "$HIST_RUN.tmp"
  mv -f "$HIST_RUN.tmp" "$HIST_RUN"
else printf '%s\n' "$HEADER" > "$HIST_RUN"; fi
if [[ -s "$HIST_FULL" ]]; then total=$(wc -l < "$HIST_FULL"); data_lines=$(( total>0 ? total-1 : 0 )); else data_lines=0; fi
if (( data_lines > HISTORY_LIMIT )); then
  ts="$(date -u +%Y%m%d-%H%M%S)"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  tail -n +2 "$HIST_FULL" >"$work/full.data"
  to_archive=$(( data_lines - HISTORY_LIMIT ))
  head -n "$to_archive" "$work/full.data" >"$work/to_archive.data"
  tail -n "$HISTORY_LIMIT" "$work/full.data" >"$work/keep.data"
  { printf '%s\n' "$HEADER"; cat "$work/to_archive.data"; } >"$work/to_archive.csv"
  { printf '%s\n' "$HEADER"; cat "$work/keep.data"; } >"$work/keep.csv"
  mkdir -p "$ARCH_DIR"
  if command -v 7z >/dev/null 2>&1; then 7z a -t7z -mx=5 "$ARCH_DIR/history-$ts.7z" "$work/to_archive.csv" >/dev/null
  else gzip -c "$work/to_archive.csv" > "$ARCH_DIR/history-$ts.csv.gz"; fi
  mv -f "$work/keep.csv" "$HIST_FULL"; sync -f "$(dirname "$HIST_FULL")" 2>/dev/null || true
fi
chown svxlink:www-data "$HIST_FULL" "$HIST_RUN" 2>/dev/null || true
chown -R svxlink:www-data "$ARCH_DIR" "$LOCK_DIR" 2>/dev/null || true
chmod 0644 "$HIST_FULL" "$HIST_RUN" 2>/dev/null || true
