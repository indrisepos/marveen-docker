# Working on this repo

Unofficial container packaging for [Marveen](https://github.com/Szotasz/marveen).
This repo is *not* Marveen; `./marveen/` is a pristine upstream checkout that
nothing here writes into, so `git pull` and upstream's `update.sh` keep working.

## The one rule

**Do not reimplement the installer.** The whole design rests on one fact: the
prerequisite step of `install-linux.sh` is a plain `command -v` loop. Satisfy
every tool in the image and its entire sudo/apt block becomes a no-op, so the
*real* wizard runs unprivileged in the container and does all its own
configuration. If something is missing at install time, add it to the image —
do not patch upstream's scripts here.

## Layout

```
marveen/         upstream checkout + all runtime state (gitignored)
  .env           bot token, Claude OAuth token   -- never commit, never print
  store/         fleet DB, .dashboard-token, *.log
data/home/       container $HOME: ~/.claude credentials, plugins, pipx
data/tmp/        agent scratch
```

## Things already learned the hard way

Re-deriving these costs hours. They are all load-bearing:

- **Login shells lie about exit status** unless `~/.bash_logout` is removed.
  Debian's runs `clear_console`, which fails with no TTY and *replaces* the
  script's status (`bash -lc 'exit 3'` returned 1). tmux starts login shells for
  every agent, so this corrupts far more than a CI check.
- **`ENV PATH` does not reach login shells.** Debian's `/etc/profile` resets
  PATH; `/etc/profile.d/10-marveen-path.sh` puts it back. Without it the agents
  lose Go and `~/.local/bin` (whisper) with no error anywhere.
- **No `sudo` in the image, deliberately.** Its mere presence makes
  `ensure-managed-channels-enabled.sh` prompt three times for a password that
  does not exist. Passwordless sudo is worse under the host-ollama profile.
- **The `ollama` shim must stay on PATH.** The installer guards the model *pull*
  on `command -v ollama` but not the *install* — without the shim it downloads a
  second daemon into the container.
- **`ALLOWED_CHAT_ID=0` is not a bug.** `src/owner-chat.ts` resolves the owner
  chat from `access.json` when it is `0`. Never hand-edit it: `memories.chat_id`
  is written *and filtered* with that value, with no migration, so changing it
  orphans every memory recorded so far.
- **Pairing happens on the dashboard**, not in the wizard. The wizard's step is
  gated on `systemctl`, which is absent here.

## Verifying a change

CI covers what a build cannot. Locally, the checks that matter:

```bash
docker build -t marveen:ci .
docker run --rm --entrypoint bash marveen:ci -lc 'exit 3'; echo $?   # must be 3
docker run --rm --entrypoint bash marveen:ci -lc 'command -v go whisper claude bun'
docker compose -f docker-compose.yml config -q
docker compose -f docker-compose.host-ollama.yml config -q
```

Restarting the live stack is safe and quick; state is all in bind mounts.

## Upstream

Three fixes from this work went to `Szotasz/marveen`, all against `develop`,
all **merged**: [#1141](https://github.com/Szotasz/marveen/pull/1141) (pairing
without systemd), [#1142](https://github.com/Szotasz/marveen/pull/1142)
(channels gate) and [#1143](https://github.com/Szotasz/marveen/pull/1143)
(`OLLAMA_URL`).

The maintainer reviews by **re-running the tests against the pre-fix script
himself**, and by mutating the fix to check the test actually fails. A test that
asserts only the script's report passes that mutation and gets sent back: on
#1142 the `preserves other managed keys` test stayed green with the merge
replaced by `d = {}`. Assert the *effect* (the file it wrote), not the summary
line.

Upstream wants PRs against `develop`, on a descriptively named branch, with the
template filled in. Its installer tests slice the **real** shipped script and
drive it with stubs — match that style, and anchor the slice so the test also
runs against the pre-fix script, or it proves nothing.

`install-macos.sh:1063` still hardcodes `http://localhost:11434` in its
start-if-not-running check — the same bug #1143 fixed on Linux. The maintainer
has carded it as theirs and asked us **not** to send a PR for it.

Workflow runs on a first-time contributor's PR sit until a maintainer approves
them; nothing surfaces that, so a silent PR is not necessarily a stalled one.
