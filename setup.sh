#!/usr/bin/env bash
# Bootstrap a Marveen deployment: clone upstream, build the image, make sure the
# embedding model exists, then hand over to Marveen's own installer.
#
# Idempotent: safe to re-run. It never overwrites an existing .env or checkout.
set -euo pipefail

cd "$(dirname "$0")"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; ORANGE=$'\033[0;33m'; NC=$'\033[0m'
ok()   { echo "  ${GREEN}✓${NC} $*"; }
warn() { echo "  ${ORANGE}!${NC} $*"; }
die()  { echo "  ${RED}✗${NC} $*" >&2; exit 1; }

PROFILE=bundled
COMPOSE_FILE=docker-compose.yml
for arg in "$@"; do
  case "$arg" in
    --host-ollama) PROFILE=host; COMPOSE_FILE=docker-compose.host-ollama.yml ;;
    --bundled)     PROFILE=bundled; COMPOSE_FILE=docker-compose.yml ;;
    -h|--help)
      cat <<USAGE
Usage: ./setup.sh [--bundled|--host-ollama]

  --bundled      Self-contained stack with its own Ollama container (default).
                 Bridge networking, no access to the host network namespace.

  --host-ollama  Reuse an Ollama already running on the host, sharing its
                 models and GPU. Requires network_mode: host -- this container
                 then has NO network isolation. See the header of
                 docker-compose.host-ollama.yml.
USAGE
      exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

echo "${BOLD}Marveen -- Docker deployment${NC}"
echo "${DIM}unofficial community packaging of github.com/Szotasz/marveen${NC}"
echo "profile: ${BOLD}${PROFILE}${NC} (${COMPOSE_FILE})"
echo ""

# ── 1. Prerequisites ────────────────────────────────────────────────────────
echo "${BOLD}[1/6] Prerequisites${NC}"
command -v docker >/dev/null 2>&1 || die "docker not found."
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) not found."
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running, are you in the 'docker' group?)"
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
ok "compose $(docker compose version --short)"
command -v git >/dev/null 2>&1 || die "git not found."

# ── 2. Local config ─────────────────────────────────────────────────────────
echo ""
echo "${BOLD}[2/6] Local config (.env)${NC}"
if [ -f .env ]; then
  ok ".env already exists -- left untouched"
else
  cp .env.example .env
  # Match the invoking user, or the container writes files the host cannot edit.
  sed -i "s/^HOST_UID=.*/HOST_UID=$(id -u)/" .env
  sed -i "s/^HOST_GID=.*/HOST_GID=$(id -g)/" .env
  host_tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)"
  [ -n "$host_tz" ] && sed -i "s#^TZ=.*#TZ=${host_tz}#" .env
  ok ".env created (uid $(id -u), gid $(id -g)${host_tz:+, tz ${host_tz}})"
fi
# shellcheck disable=SC1091
set -a; . ./.env; set +a

# ── 3. Upstream checkout ────────────────────────────────────────────────────
echo ""
echo "${BOLD}[3/6] Marveen checkout${NC}"
mkdir -p data/home data/tmp
if [ -d marveen/.git ]; then
  ok "./marveen already present ($(git -C marveen describe --tags --always 2>/dev/null || echo unknown))"
  echo "  ${DIM}to update later: docker compose -f ${COMPOSE_FILE} run --rm marveen update${NC}"
else
  echo "  cloning ${MARVEEN_REPO} @ ${MARVEEN_REF} ..."
  git clone -q --branch "${MARVEEN_REF}" "${MARVEEN_REPO}" marveen
  ok "cloned ($(git -C marveen log --oneline -1))"
fi

# ── 4. Image ────────────────────────────────────────────────────────────────
echo ""
echo "${BOLD}[4/6] Image${NC}"
docker compose -f "${COMPOSE_FILE}" build
ok "image built"

# ── 5. Embedding model ──────────────────────────────────────────────────────
# nomic-embed-text backs the semantic half of Marveen's hybrid memory search.
# Marveen's installer pulls it too, but ONLY via a hardcoded localhost:11434 --
# which is right under --host-ollama and wrong under --bundled. Doing it here
# makes both profiles end up with the model where the runtime will look.
echo ""
echo "${BOLD}[5/6] Embedding model (nomic-embed-text, ~274 MB)${NC}"
if [ "$PROFILE" = "bundled" ]; then
  docker compose -f "${COMPOSE_FILE}" up -d ollama
  echo "  waiting for the ollama service ..."
  for _ in $(seq 1 60); do
    docker compose -f "${COMPOSE_FILE}" exec -T ollama ollama list >/dev/null 2>&1 && break
    sleep 2
  done
  docker compose -f "${COMPOSE_FILE}" exec -T ollama ollama list >/dev/null 2>&1 \
    || die "the ollama service did not come up. Check: docker compose -f ${COMPOSE_FILE} logs ollama"
  if docker compose -f "${COMPOSE_FILE}" exec -T ollama ollama list | grep -q nomic-embed-text; then
    ok "nomic-embed-text already present"
  else
    docker compose -f "${COMPOSE_FILE}" exec -T ollama ollama pull nomic-embed-text
    ok "nomic-embed-text pulled"
  fi
else
  if ! curl -sf --max-time 5 http://localhost:11434/api/version >/dev/null 2>&1; then
    warn "no Ollama answering on the host at :11434 -- semantic memory search will be skipped."
    echo "  ${DIM}install it (https://ollama.com), then: ollama pull nomic-embed-text${NC}"
  elif curl -sf http://localhost:11434/api/tags | grep -q nomic-embed-text; then
    ok "nomic-embed-text already present on the host daemon"
  else
    echo "  pulling into the host daemon ..."
    ollama pull nomic-embed-text || warn "pull failed -- run it yourself: ollama pull nomic-embed-text"
  fi
fi

# ── 6. Marveen's own installer ──────────────────────────────────────────────
cat <<NEXT

${BOLD}[6/6] Marveen's installer${NC}

  The interactive wizard runs next. Have these ready:

    1. A Claude Code token. On a machine with a browser: ${BOLD}claude setup-token${NC}
       (needs a Claude subscription; otherwise pick the API-key option and
       bring an sk-ant-... key from console.anthropic.com)
    2. A Telegram bot token from @BotFather (/newbot). No chat ID needed --
       pairing happens afterwards, in the dashboard.

  ${BOLD}Two warnings from the wizard are EXPECTED here${NC}, and neither is a problem:

    "channelsEnabled ... kihagyva"   the image already carries
                                     /etc/claude-code/managed-settings.json
    "systemd --user nem elerheto"    there is no systemd in a container; the
                                     entrypoint supervises the services instead

NEXT
read -rp "  Start the wizard now? [Y/n] " go
case "${go:-y}" in
  [nN]*) echo "  ${DIM}Later: docker compose -f ${COMPOSE_FILE} run --rm marveen setup${NC}"; exit 0 ;;
esac

docker compose -f "${COMPOSE_FILE}" run --rm marveen setup

cat <<DONE

${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

  ${BOLD}Start it:${NC}  docker compose -f ${COMPOSE_FILE} up -d
  ${BOLD}Logs:${NC}      docker compose -f ${COMPOSE_FILE} logs -f

  ${BOLD}Dashboard${NC} (the token is generated on first start):
    echo "http://localhost:${WEB_PORT:-3420}/?token=\$(cat marveen/store/.dashboard-token)"

  ${BOLD}Last step -- pair Telegram:${NC}
    1. message your bot anything
    2. approve the pending pairing on the dashboard's Channel page

  The wizard's own pairing step is skipped in a container; the dashboard does
  the same job. Until you pair, the bot answers you but sends nothing on its
  own (daily digest, alerts).

DONE
