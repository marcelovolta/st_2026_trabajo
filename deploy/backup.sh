#!/usr/bin/env bash
# ---- Daily backup of the collector's SQLite database --------------------------
# Run as the `spacewx` user, once a day, via /etc/cron.d/spacewx-backup (see
# COLLECTOR.md). Takes a consistent snapshot (safe even while the collector is
# writing), compresses it, and prunes anything older than $RETENTION_DAYS.
#
# This protects against database corruption or a mistake on the server. It does
# NOT protect against losing the server itself: copy backups off-box
# periodically (e.g. `scp` this folder to your Mac, or point it at object
# storage) once you decide where they should live.
set -euo pipefail

DB="${SPACEWX_DB_PATH:-/var/lib/spacewx/spacewx.sqlite}"
DEST_DIR="${SPACEWX_BACKUP_DIR:-/var/lib/spacewx/backups}"
RETENTION_DAYS="${SPACEWX_BACKUP_RETENTION_DAYS:-14}"

mkdir -p "$DEST_DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$DEST_DIR/spacewx-$stamp.sqlite"

# sqlite3's .backup command takes a consistent snapshot through SQLite's own
# locking, unlike `cp`, which could copy a half-written page.
sqlite3 "$DB" ".backup '$out'"
gzip "$out"

# Delete backups older than the retention window.
find "$DEST_DIR" -name 'spacewx-*.sqlite.gz' -mtime "+${RETENTION_DAYS}" -delete

echo "$(date -u +%FT%TZ) backup ok: $out.gz ($(du -h "$out.gz" | cut -f1))"
