# Marveen container image.
#
# Upstream ships no Docker support: the supported path is install-linux.sh,
# which apt-installs system packages and generates systemd --user units. This
# image exists because that installer's prerequisite check is a plain
# `command -v` loop -- satisfy every tool up front and its entire sudo/apt block
# is skipped, so the REAL installer runs unprivileged inside the container and
# does all of its own configuration work. We do not reimplement it.
#
# The concrete reason to containerise: package.json declares
# "node": ">=20 <24", and a modern distro ships Node 24.

FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# The first group mirrors install-linux.sh's prerequisite loop verbatim
# (ffmpeg git tmux lsof curl python3 pipx unzip zstd + build-essential); the
# rest is what the runtime scripts actually shell out to.
#
# NOTE sudo is deliberately ABSENT. The container user has no password and no
# sudoers entry, so every sudo call can only fail -- and its mere presence on
# PATH sends scripts/ensure-managed-channels-enabled.sh down a branch that
# prompts three times for a password that does not exist. Passwordless sudo was
# rejected too: under the host-ollama profile this container shares the host
# network namespace, where in-container root could bind privileged host ports.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        git \
        tmux \
        lsof \
        curl \
        ca-certificates \
        python3 \
        python3-venv \
        pipx \
        unzip \
        zstd \
        build-essential \
        jq \
        sqlite3 \
        bc \
        procps \
        openssh-client \
        locales \
        tzdata \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/; s/^# *\(hu_HU.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# Bun: the Telegram channel plugin runs under it. System-wide rather than into
# $HOME so it survives the HOME bind mount.
ENV BUN_INSTALL=/usr/local/bun
RUN curl -fsSL https://bun.sh/install | bash \
    && ln -s "${BUN_INSTALL}/bin/bun" /usr/local/bin/bun \
    && ln -s "${BUN_INSTALL}/bin/bunx" /usr/local/bin/bunx

# Pinned to the CLAUDE_PIN in install-linux.sh, not "latest": Marveen drives the
# CLI programmatically and upstream tests against that version.
ARG CLAUDE_VERSION=2.1.110
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
    && npm cache clean --force

# Go, for the bumblebee supply-chain scanner. install-linux.sh installs it with
# `sudo tar -C /usr/local`, which cannot work as an unprivileged container user;
# it falls through to "bumblebee kihagyva" and the seeded hygiene-scan task then
# has no binary. Worth carrying: this fleet installs and runs packages on its
# own. Floor is Go >= 1.25 (the installer's own check).
ARG GO_VERSION=1.25.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) goarch=amd64 ;; \
      arm64) goarch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    /usr/local/go/bin/go version

# Claude Code managed (org-policy) settings.
#
# claude-code >= 2.1.205 SILENTLY drops channel-plugin INBOUND notifications on
# a TEAM/ENTERPRISE org unless the MANAGED settings carry "channelsEnabled":
# true. Outbound keeps working, so it looks almost-fine while replies never
# reach the session. It is a managed-layer-only key. On a personal org it is
# simply ignored, so setting it unconditionally is safe and survives a later
# personal -> team move. Upstream does this via sudo; in an image the correct
# layer is build time, as root, before dropping privileges.
RUN mkdir -p /etc/claude-code \
    && printf '{\n  "channelsEnabled": true\n}\n' > /etc/claude-code/managed-settings.json

COPY ollama-shim.sh /usr/local/bin/ollama
COPY entrypoint.sh /usr/local/bin/marveen-entrypoint
RUN chmod +x /usr/local/bin/ollama /usr/local/bin/marveen-entrypoint

# Debian's /etc/profile HARD-RESETS PATH for non-root LOGIN shells:
#   PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games"
# which discards everything ENV adds below. That matters because channels.sh
# drives the agents through tmux, and tmux starts login shells -- without this
# the fleet silently loses Go and, worse, ~/.local/bin, where pipx installs
# whisper. Re-prepending from profile.d keeps the two PATHs in agreement.
RUN printf '%s\n' \
    '# Restore the image PATH that Debian'"'"'s /etc/profile resets.' \
    'PATH="/home/node/.local/bin:/usr/local/bun/bin:/usr/local/go/bin:$PATH"' \
    'export PATH' \
    > /etc/profile.d/10-marveen-path.sh \
    && chmod 0644 /etc/profile.d/10-marveen-path.sh

# Drop Debian's ~/.bash_logout.
#
# It runs `clear_console -q` when a LOGIN shell exits. With no TTY -- which is
# every shell in this container -- that command fails, and its status REPLACES
# the shell's own: `bash -lc 'exit 0'` returns 1. Measured in this image.
#
# That is not cosmetic. channels.sh drives the agents through tmux, and tmux
# starts login shells, so anything that reads the exit status of one gets a
# fabricated failure. Clearing a physical console for privacy is meaningless in
# a container; corrupting exit codes is not.
RUN rm -f /home/node/.bash_logout /etc/skel/.bash_logout

# uid/gid 1000 already exists in the node image as `node`. Compose overrides the
# runtime user to match whoever owns the bind mounts.
ENV HOME=/home/node \
    PATH=/home/node/.local/bin:/usr/local/bun/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /opt/marveen
USER node

ENTRYPOINT ["/usr/local/bin/marveen-entrypoint"]
CMD ["run"]
