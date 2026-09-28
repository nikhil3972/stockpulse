#!/usr/bin/env bash
# Stop StockPulse. Pass --reset to also delete the database (demo data is re-seeded on next start).
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" = "--reset" ]; then
  docker compose down -v
else
  docker compose down
fi
