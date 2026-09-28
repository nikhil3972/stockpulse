#!/usr/bin/env bash
# StockPulse one-command start. Needs only Docker.
set -euo pipefail
cd "$(dirname "$0")"

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start Docker Desktop and try again." >&2
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example."
fi

if ! grep -qE '^GEMINI_API_KEY=.+' .env; then
  echo
  echo "No GEMINI_API_KEY in .env. StockPulse will run with rule-based suggestions (source: Rule fallback)."
  echo "To use AI, get a key at https://aistudio.google.com/apikey and put it in .env as GEMINI_API_KEY=..."
  echo
fi

docker compose up --build -d

echo "Waiting for the console..."
for _ in $(seq 1 90); do
  if curl -fs http://localhost:3000/api/admin/strategy >/dev/null 2>&1; then
    echo
    echo "StockPulse is running:  http://localhost:3000"
    echo "Logs:  docker compose logs -f backend      Stop:  ./stop.sh"
    exit 0
  fi
  sleep 2
done

echo "Timed out waiting for StockPulse. Check: docker compose logs backend" >&2
exit 1
