#!/usr/bin/env bash
# Thin `ollama` stand-in.
#
# This container never runs its own Ollama. It talks to whichever daemon
# OLLAMA_URL names -- the bundled `ollama` service on the default stack, or the
# host's daemon under the host-ollama profile -- so the model store (GBs) and
# any GPU stay in one place instead of being duplicated per container.
#
# WHY THIS FILE EXISTS AT ALL: install-linux.sh guards the MODEL PULL on
# `command -v ollama`, but not the INSTALL. With no `ollama` on PATH it runs
# `curl https://ollama.com/install.sh | sh` and tries to bring up a second
# daemon inside the container. Having this on PATH sends the installer down its
# "already installed" branch, where every remaining step is plain HTTP.
#
# Only the subcommands Marveen actually invokes are implemented.
set -euo pipefail

API="${OLLAMA_URL:-http://localhost:11434}"

curl -sf --max-time 5 "${API}/api/version" >/dev/null 2>&1 || {
  echo "ollama (container shim): no daemon answering at ${API}" >&2
  echo "  default stack: is the 'ollama' service healthy? docker compose ps" >&2
  echo "  host-ollama:   is the host daemon up?          systemctl status ollama" >&2
  exit 1
}

case "${1:-}" in
  --version|-v|version)
    ver=$(curl -sf "${API}/api/version" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))')
    echo "ollama version is ${ver} (via container shim -> ${API})"
    ;;
  list|ls)
    curl -sf "${API}/api/tags" | python3 -c '
import sys, json
print("NAME\tSIZE")
for m in json.load(sys.stdin).get("models", []):
    print("%s\t%.0f MB" % (m.get("name","?"), m.get("size",0)/1e6))
'
    ;;
  pull)
    model="${2:?usage: ollama pull <model>}"
    echo "Pulling ${model} via ${API} ..."
    status=$(curl -sf --max-time 900 -X POST "${API}/api/pull" \
      -H 'Content-Type: application/json' \
      -d "{\"model\": \"${model}\", \"stream\": false}" |
      python3 -c 'import sys,json;print(json.load(sys.stdin).get("status","?"))')
    [ "$status" = "success" ] || { echo "pull failed: ${status}" >&2; exit 1; }
    echo "success"
    ;;
  *)
    echo "ollama (container shim): '${1:-}' is not implemented here." >&2
    echo "  This container uses the daemon at ${API}." >&2
    exit 1
    ;;
esac
