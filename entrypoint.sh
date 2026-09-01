#!/usr/bin/env bash
# Marveen container entrypoint.
#
# On a normal host install, install-linux.sh generates five systemd --user
# units. There is no systemd here, so this script reproduces the two
# long-running ones plus the two timed/oneshot ones, keeping their restart
# semantics -- those differ per unit on purpose and upstream documents why:
#
#   <id>-dashboard      node dist/index.js        Restart=on-failure  RestartSec=5
#   <id>-channels       scripts/channels.sh       Restart=always      RestartSec=10
#   <id>-morning.timer  scripts/morning-briefing.sh   daily at 07:27
#   <id>-host-watchdog  scripts/host-restart-watchdog.sh   oneshot at boot
#
# channels.sh in particular exits ZERO on purpose from its watchdog branches to
# be restarted; an on-failure policy there leaves the channel silently dead
# (upstream hit this on a live install). Hence the asymmetry below.

set -uo pipefail

APP=/opt/marveen
cd "$APP" || { echo "[entrypoint] $APP is not mounted" >&2; exit 1; }

log() { echo "[entrypoint] $*"; }

# The dashboard holds MCP/SSE connections and shells out to tmux constantly;
# the default 1024 soft limit is exhausted once several agents are live
# (LimitNOFILE=16384 in the upstream unit).
ulimit -n 16384 2>/dev/null || log "note: could not raise NOFILE limit"

need_setup() {
  [ ! -s "$APP/.env" ] || [ ! -d "$APP/node_modules" ] || [ ! -f "$APP/dist/index.js" ]
}

# Is a messaging channel actually configured?
#
# The dashboard is fully usable without one, and a staged setup (dashboard
# first, Telegram later) is a normal way to start. Without this check the
# channels supervisor would run anyway: channels.sh self-throttles to a 60-300s
# retry, so it never spins hot, but it fills channels.log with failures that
# look like a broken install rather than a deliberately empty one.
channel_configured() {
  local provider token
  provider=$(sed -n 's/^CHANNEL_PROVIDER=//p' "$APP/.env" 2>/dev/null | head -1)
  provider=${provider:-telegram}
  case "$provider" in
    telegram) token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$APP/.env" 2>/dev/null | head -1) ;;
    slack)    token=$(sed -n 's/^SLACK_BOT_TOKEN=//p'    "$APP/.env" 2>/dev/null | head -1) ;;
    discord)  token=$(sed -n 's/^DISCORD_BOT_TOKEN=//p'  "$APP/.env" 2>/dev/null | head -1) ;;
    *)        token="" ;;
  esac
  [ -n "${token//\"/}" ]
}

case "${1:-run}" in

  setup)
    log "running the upstream installer (install-linux.sh)"
    log "every prerequisite is already baked into the image, so its sudo/apt"
    log "block is skipped; the systemd step will report no systemd -- expected."
    exec ./install-linux.sh "${@:2}"
    ;;

  shell)
    exec bash
    ;;

  update)
    exec ./update.sh "${@:2}"
    ;;

  run)
    if need_setup; then
      log "ERROR: this install is not configured yet."
      log "Run the interactive setup first:"
      log "    docker compose run --rm marveen setup"
      exit 1
    fi

    mkdir -p "$APP/store"

    # Both upstream units run this as ExecStartPre: it rebuilds better-sqlite3
    # when its native binding does not match the running Node ABI. Without it a
    # Node/npm change turns into a restart crash-loop.
    log "verifying native modules"
    ./scripts/ensure-native-modules.sh || log "warning: ensure-native-modules.sh reported a problem"

    declare -a PIDS=()

    shutdown() {
      log "shutting down"
      for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
      # Mirrors KillMode=process: stop the supervised entry points, leave the
      # shared tmux server and the agent sessions to exit on their own.
      wait
      exit 0
    }
    trap shutdown TERM INT

    # Restart=on-failure, RestartSec=5
    supervise_dashboard() {
      while true; do
        node "$APP/dist/index.js" >>"$APP/store/dashboard.log" 2>>"$APP/store/dashboard.error.log"
        rc=$?
        [ $rc -eq 0 ] && { log "dashboard exited cleanly (rc=0); not restarting"; return 0; }
        log "dashboard died (rc=$rc), restarting in 5s"
        sleep 5
      done
    }

    # Restart=always, RestartSec=10 -- see the header note on zero exits.
    supervise_channels() {
      while true; do
        "$APP/scripts/channels.sh" >>"$APP/store/channels.log" 2>>"$APP/store/channels.error.log"
        log "channels exited (rc=$?), restarting in 10s"
        sleep 10
      done
    }

    # Stand-in for <id>-morning.timer (OnCalendar=*-*-* 07:27:00).
    supervise_morning() {
      while true; do
        now=$(date +%s)
        target=$(date -d "today 07:27" +%s)
        [ "$now" -ge "$target" ] && target=$(date -d "tomorrow 07:27" +%s)
        sleep $(( target - now ))
        log "running morning briefing"
        "$APP/scripts/morning-briefing.sh" >>"$APP/store/morning.log" 2>&1 \
          || log "morning briefing failed"
      done
    }

    # Oneshot at boot on the host; container start is the same moment.
    if [ -x "$APP/scripts/host-restart-watchdog.sh" ]; then
      MARVEEN_STORE="$APP/store" \
      TELEGRAM_ENV="$HOME/.claude/channels/telegram/.env" \
        "$APP/scripts/host-restart-watchdog.sh" >>"$APP/store/watchdog.log" 2>&1 \
        || log "host-restart-watchdog reported a problem (non-fatal)"
    fi

    export TERM=xterm-256color
    export USER=node

    supervise_dashboard & PIDS+=($!)
    supervise_morning   & PIDS+=($!)

    if channel_configured; then
      supervise_channels & PIDS+=($!)
      log "dashboard + channels up; logs in $APP/store/*.log"
    else
      log "no channel token in .env -- starting the dashboard only."
      log "add one later with: docker compose run --rm marveen setup"
      log "then: docker compose restart"
    fi
    log "dashboard: http://localhost:${WEB_PORT:-3420}"
    wait
    ;;

  *)
    exec "$@"
    ;;
esac
