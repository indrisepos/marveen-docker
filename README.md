# marveen-docker

Run [Marveen](https://github.com/Szotasz/marveen) in a container.

**Unofficial.** This repository only *packages* Marveen; it is not Marveen, and
it is not affiliated with or endorsed by its maintainers. Marveen itself is MIT
© Szotasz. Report packaging problems here, Marveen problems upstream.

> [!WARNING]
> Marveen runs Claude Code autonomously and on a schedule, with
> `--dangerously-skip-permissions`, including while you sleep. That is the
> product, not a misconfiguration. The container bounds what it can reach on
> your filesystem; it does **not** bound what it spends. The token you give it
> is used unattended.

---

## Why a container

Upstream's supported path is `install-linux.sh`: it `sudo apt`-installs system
packages, writes to your `~/.bashrc`, and generates systemd `--user` units.
That works, and if it suits you, use it.

A container is worth it when:

- **Your Node is too new.** `package.json` declares `"node": ">=20 <24"`, and
  current distros ship Node 24. In a container this is free.
- **You would rather not have an autonomous agent share your user account.**
- **You want the install reproducible** on another machine.

The image does not reimplement the installer. It pre-satisfies every tool the
installer's `command -v` prerequisite loop checks, which makes its entire
sudo/apt block a no-op, and then runs the *real* wizard unprivileged inside the
container.

## Quick start

```bash
git clone https://github.com/indrisepos/marveen-docker.git
cd marveen-docker
./setup.sh
```

`setup.sh` clones upstream, builds the image, makes sure the embedding model
exists, and hands over to Marveen's own wizard. Have ready:

1. A Claude Code token — `claude setup-token` on a machine with a browser.
2. A Telegram bot token from [@BotFather](https://t.me/BotFather) (`/newbot`).
   No chat ID: pairing happens afterwards, in the dashboard.

Then:

```bash
docker compose up -d
echo "http://localhost:3420/?token=$(cat marveen/store/.dashboard-token)"
```

## Two profiles

| | `./setup.sh` (default) | `./setup.sh --host-ollama` |
|---|---|---|
| Ollama | own container | the host's existing daemon |
| Network | bridge, isolated | `network_mode: host`, **no isolation** |
| Dashboard | published on `127.0.0.1` | bound to `127.0.0.1` |
| GPU | needs `nvidia-container-toolkit` | whatever the host already uses |

Use the default unless you already run Ollama and want to share its models and
GPU rather than download them twice.

`--host-ollama` needs `network_mode: host` for a specific reason: Ollama binds
`127.0.0.1:11434`, which a bridge container cannot reach through host-gateway,
and opening the host daemon wider would expose it to every container on the
box. It also matters that Marveen's installer hardcodes `localhost:11434` for
its model pull, so "localhost" has to genuinely be the host. The cost is real
and worth stating plainly: that container can reach every service on your host,
including loopback-only ones.

## What the image does that the installer cannot

Three things `install-linux.sh` does with `sudo`, which an unprivileged
container user does not have. They are baked in at build time, as root:

| | Why |
|---|---|
| `/etc/claude-code/managed-settings.json` | `claude-code >= 2.1.205` silently drops **inbound** channel messages on a team/enterprise org without `channelsEnabled: true`. Ignored on a personal org, so it is set unconditionally. |
| Go 1.25 in `/usr/local/go` | The bumblebee supply-chain scanner. Not decoration: this fleet installs and runs packages by itself. |
| `/etc/profile.d/10-marveen-path.sh` | Debian's `/etc/profile` **resets** `PATH` for non-root login shells. `channels.sh` drives agents through tmux, and tmux starts login shells — without this the fleet silently loses Go and `~/.local/bin`, where pipx installs `whisper`. |

There is also no `sudo` in the image, on purpose. The container user has no
password and no sudoers entry, so a `sudo` call can only ever fail — and merely
having it on `PATH` makes one upstream script prompt three times for a password
that does not exist. Passwordless sudo was rejected: under `--host-ollama`,
in-container root could bind privileged ports on the host.

## Warnings you should expect, and ignore

The wizard prints these in a container. None is a problem:

```
! channelsEnabled: nem root es nincs sudo -- kihagyva
```
The image already carries the managed-settings file.

```
! Go >= 1.25 szukseges -- telepites...   ->   bumblebee kihagyva
```
Go is in the image; only the installer's own `sudo tar` step fails.

```
! loginctl linger nem sikerult
! systemd --user nem elerheto (WSL / konteneren / VPS user-session nelkul)
```
Correct. `restart: unless-stopped` and the entrypoint do those jobs.

```
! A marveen-channels service nem indult el. Parositas kihagyva.
```
The bridge *is* running; the check asks systemd, which is absent. Pair from the
dashboard instead (below).

## Pairing Telegram

The wizard's pairing step is skipped in a container, so:

1. `docker compose up -d`
2. open the dashboard
3. message your bot anything — it replies with a 6-character code, valid 1 hour
4. approve the pending pairing on the **Channel** page

Until you pair, the bot answers you but sends nothing on its own (daily digest,
new-agent welcome, alerts).

> [!NOTE]
> The wizard ends by warning that `ALLOWED_CHAT_ID=0` will suppress those
> self-initiated messages. **Do not hand-edit it.** `src/owner-chat.ts` resolves
> the owner chat from `access.json`'s allowlist when the value is `0`, so
> pairing is enough — and upstream deliberately does not write it back, because
> `memories.chat_id` is written *and filtered* with that value and there is no
> migration. Changing it on a running install orphans every memory recorded
> before the change.

## Services

There is no systemd, so the entrypoint reproduces the units, keeping their
restart semantics — which differ per unit deliberately:

| Unit | Command | Restart |
|---|---|---|
| dashboard | `node dist/index.js` | on-failure, 5s |
| channels | `scripts/channels.sh` | **always**, 10s |
| morning | `scripts/morning-briefing.sh` | daily 07:27 |
| host-watchdog | `scripts/host-restart-watchdog.sh` | once at start |

`channels` is `always` on purpose: its watchdog branches exit **zero** in order
to be restarted. Under `on-failure` the channel stays silently dead — upstream
hit exactly that on a live install.

When no channel token is configured yet, the entrypoint starts the dashboard
only and says so, rather than letting `channels.sh` retry-loop into the log.

## Operations

```bash
docker compose up -d                      # start   (add -f docker-compose.host-ollama.yml for that profile)
docker compose logs -f                    # entrypoint log
docker compose down                       # stop
docker compose run --rm marveen shell     # a shell inside
docker compose run --rm marveen update    # upstream's update.sh
docker compose run --rm marveen setup     # re-run the wizard (idempotent)

tail -f marveen/store/dashboard.log       # app logs live in the checkout
tail -f marveen/store/channels.log
```

State lives in bind mounts, so rebuilding the image loses nothing:

```
marveen/      upstream checkout + .env, store/, agents/, dist/   (gitignored here)
data/home/    container $HOME: ~/.claude credentials, plugins
data/tmp/     agent scratch
```

`marveen/` stays a pristine upstream checkout — nothing from this repo is
written into it — so `git pull` and upstream's `update.sh` keep working.

## Known limitations

- **Whisper runs on CPU.** The optional install pulls ~4.9 GB (PyTorch + CUDA
  libraries) into `data/home`, but the container is not given a GPU by default.
- **The bumblebee binary is not built.** Go is present; compiling it is not
  automated yet.
- **The image builds on the Docker data root** (`/var/lib/docker`), not
  wherever you cloned this. Only the *data* follows the checkout.
- **Not tested on macOS or Windows.** The host-ollama profile in particular
  relies on Linux `network_mode: host` semantics.

## Credits

[Marveen](https://github.com/Szotasz/marveen) by
[Szota Szabolcs](https://aiamindennapokban.hu). This packaging is MIT licensed;
see `LICENSE`.
