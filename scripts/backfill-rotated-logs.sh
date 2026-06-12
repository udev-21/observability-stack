#!/usr/bin/env bash
#
# backfill-rotated-logs.sh — import already-rotated nginx access logs into VictoriaLogs.
#
# Streams newline-delimited JSON (json_analytics) from rotated files (.gz or plain) into
# VictoriaLogs /insert/jsonline at their REAL timestamps. It deliberately bypasses Vector and
# the metrics pipeline — historical logs cannot become meaningful metrics (they'd be stamped at
# import time as one spike), so this is a logs-only backfill.
#
# Re-run safe: a state file records a content fingerprint of every imported file, so the same
# file is never imported twice (VictoriaLogs does NOT dedupe, so this guard matters).
#
set -euo pipefail

VL_URL="${VL_URL:-http://localhost:9428}"
TIME_FIELD="${TIME_FIELD:-time_iso8601}"
MSG_FIELD="${MSG_FIELD:-request}"
STREAM_FIELDS="${STREAM_FIELDS:-server_name}"
STATE_FILE="${STATE_FILE:-$HOME/.observability-backfill-state}"
DRY_RUN=0
FORCE=0
FILES=()

usage() {
  cat <<'EOF'
Import already-rotated nginx access logs into VictoriaLogs (logs only, not metrics).

Usage:
  scripts/backfill-rotated-logs.sh [options] FILE...

Examples:
  scripts/backfill-rotated-logs.sh /var/log/nginx/access.log.*.gz /var/log/nginx/access.log.1
  scripts/backfill-rotated-logs.sh --dry-run logs/access.log.*

Options:
  --dry-run     show what would be imported; do nothing
  --force       import even if the file's fingerprint is already in the state file
  -h, --help    show this help

Environment (defaults shown):
  VL_URL=http://localhost:9428
  TIME_FIELD=time_iso8601   MSG_FIELD=request   STREAM_FIELDS=server_name
  STATE_FILE=$HOME/.observability-backfill-state

Notes:
  * Pass ONLY rotated files — never the active access.log (Vector already ingests it; the
    script refuses an exact 'access.log' basename unless --force is given).
  * .gz and plain files are both handled.
  * VictoriaLogs stores by _time, so chronological order is not required (oldest-first is tidy).
  * RETENTION: VictoriaLogs SILENTLY DROPS entries older than its -retentionPeriod
    (VL_RETENTION, default 30d) — the import returns HTTP 200 but nothing is stored. To backfill
    older logs, raise VL_RETENTION and recreate the victorialogs service FIRST, then import.
    The "first ts=" shown per file lets you sanity-check against your retention window.
EOF
}

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[backfill] $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1 (see --help)" ;;
    *)         FILES+=("$1") ;;
  esac
  shift
done

[ "${#FILES[@]}" -gt 0 ] || { usage; die "no files given"; }
command -v curl >/dev/null      || die "curl not found"
command -v sha256sum >/dev/null || die "sha256sum not found"

URL="${VL_URL%/}/insert/jsonline?_time_field=${TIME_FIELD}&_msg_field=${MSG_FIELD}&_stream_fields=${STREAM_FIELDS}"
touch "$STATE_FILE"

decompress() { case "$1" in *.gz) gzip -dc -- "$1" ;; *) cat -- "$1" ;; esac; }

# Cheap, rename-safe content fingerprint: file size + sha256 of the first 64 KiB (decompressed).
fingerprint() {
  local f="$1" sz hh
  sz=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
  hh=$({ decompress "$f" 2>/dev/null || true; } | head -c 65536 | sha256sum | cut -d' ' -f1)
  printf '%s:%s' "$sz" "$hh"
}

imported=0; skipped=0; failed=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { log "skip (not a file): $f"; continue; }

  if [ "$(basename -- "$f")" = "access.log" ] && [ "$FORCE" -ne 1 ]; then
    log "WARNING: '$f' is the ACTIVE log (already ingested by Vector) — skipping. Use --force to override."
    skipped=$((skipped + 1)); continue
  fi

  fp=$(fingerprint "$f")
  if [ "$FORCE" -ne 1 ] && grep -qxF "$fp" "$STATE_FILE"; then
    log "skip (already imported): $f"; skipped=$((skipped + 1)); continue
  fi

  # Peek the first entry's timestamp so the user can sanity-check it against VL retention.
  first_ts=$({ decompress "$f" 2>/dev/null || true; } | head -n1 \
              | grep -oE '"time_iso8601" *: *"[^"]*"' | head -n1 | cut -d'"' -f4 || true)

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would import: $f  (first ts=${first_ts:-?}, fp=$fp)"; imported=$((imported + 1)); continue
  fi

  log "importing: $f  (first ts=${first_ts:-?}) ..."
  code=$(decompress "$f" | curl -sS -o /dev/null -w '%{http_code}' \
           -X POST "$URL" -H 'Content-Type: application/x-ndjson' --data-binary @- || echo 000)
  case "$code" in
    200|204)
      printf '%s\n' "$fp" >> "$STATE_FILE"
      log "  ok (HTTP $code): $f"; imported=$((imported + 1)) ;;
    *)
      log "  FAILED (HTTP $code): $f — not recorded; re-run to retry"; failed=$((failed + 1)) ;;
  esac
done

log "done. imported=$imported skipped=$skipped failed=$failed  (state: $STATE_FILE)"
[ "$failed" -eq 0 ]
