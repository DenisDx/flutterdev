# flutterdev

A persistent Docker-based development environment for Flutter applications: OpenCode,
Flutter/Dart SDK, Dart/Flutter MCP, Node.js LTS, Python 3, Git, JDK, Android SDK, and a
headless Android Emulator.

The environment is managed with Docker Compose. The infrastructure root and persistent
user data live in `/path/to/flutterdev`.

## Contents

- `Dockerfile`, `compose.yaml` - image definition and the `flutterdev` container.
- `versions.env` - version policies (stable/lts) and Android settings.
- `.env` - real local addresses, ports, and secrets (not committed, mode `0600`).
- `.env.example` - template without real values.
- `scripts/entrypoint.sh` - starts sshd, generates host keys, creates the AVD, and
  writes the runtime topology.
- `scripts/check.sh` - checks tools, Android, mounts, and external services.
- `scripts/update.sh` - builds a new image, verifies it, and recreates the container.
- `scripts/rollback.sh` - rolls back to the previous image.
- `scripts/fd-info.sh` - prints the runtime topology and runbook paths.
- `workspace/AGENTS.md` - canonical container runbook for agents (tracked via a
  `.gitignore` exception).
- `config/opencode/opencode.jsonc` - OpenCode configuration (mounted read-only).
- `config/git/config.example` - optional global Git configuration.
- `workspace/` - independent projects with their own `.git`.
- `state/` - persistent HOME, SSH host keys, authorized_keys, and update data.

## Requirements

- A Linux host with Docker and Docker Compose v2.
- An accessible `/dev/kvm` device and enabled hardware virtualization.
- Free host ports configured in `.env` for Web and SSH.
- An external Docker network for communication with the browser container
  (`DOCKER_NETWORK`).
- External services: SearXNG MCP, Playwright MCP with Chromium, and an inference server.
  Their full endpoints are configured only in `.env`.

## Initial setup

1. Create `.env` from the template and fill in real values:

   ```bash
   cp .env.example .env
   chmod 600 .env
   ```

   UID/GID of the `dev` user:

   ```bash
   id -u; id -g
   ```

   KVM device GID:

   ```bash
   stat -c %g /dev/kvm
   ```

   For LAN access, set the host LAN address in `WEB_BIND_ADDRESS` and
   `SSH_BIND_ADDRESS` in the real `.env` (or `0.0.0.0`), not `127.0.0.1`.
   Restrict access with a firewall. When binding to loopback, use an SSH tunnel.

2. Create the directories and the file with allowed incoming SSH keys:

   ```bash
   mkdir -p workspace state/home state/ssh state/access state/updates
   chmod 700 state/ssh
   cat ~/.ssh/id_ed25519.pub > state/access/authorized_keys
   chmod 600 state/access/authorized_keys
   ```

   Private keys, the SSH agent, and the Docker socket are not passed into the
   container. `authorized_keys` only grants incoming access to the container.

3. Create the shared external network once:

   ```bash
   docker network create "${DOCKER_NETWORK}"
   ```

4. Building the image requires explicit acceptance of the Android SDK terms.
   Set this in the real `.env`:

   ```dotenv
   ANDROID_ACCEPT_LICENSES=true
   ```

5. Build the image and start the container:

   ```bash
   ./scripts/update.sh
   ```

   The script builds the image with `--pull --no-cache`, verifies it without user
   mounts, writes versions to `state/updates/`, and recreates the container after
   confirmation. For non-interactive execution, use `./scripts/update.sh --yes`.

Alternative manual first build:

```bash
docker compose --env-file .env --env-file versions.env build --pull
docker compose --env-file .env up -d
```

## Usage

Open a shell as the `dev` user:

```bash
docker compose exec --user dev flutterdev bash
cd /workspace/PROJECT
opencode
```

Always use `--user dev` for user sessions, Flutter, OpenCode, and checks.
The container's root processes are only the entrypoint and sshd.

### Flutter Web

Start the dev server from the project directory:

```bash
flutter run -d web-server \
  --web-hostname 0.0.0.0 \
  --web-port "$WEB_CONTAINER_PORT"
```

Web is published on `WEB_BIND_ADDRESS:WEB_HOST_PORT`. The browser container connects to
`http://flutterdev:WEB_CONTAINER_PORT` over the shared Docker network.

### Android Emulator

The emulator runs headless. The AVD is created by the entrypoint on first start in the
persistent `HOME` (`state/home/.android/avd`); the system image lives in the image's SDK.
Start it with:

```bash
emulator -avd "$ANDROID_AVD_NAME" -no-window -no-audio -gpu swiftshader_indirect
adb devices
```

ADB and emulator ports are not published to the host by default. For acceleration, the
container receives `/dev/kvm`, and `dev` gets the host device GID group (`KVM_GID`).
Privileged mode is not used.

After a system image update, check that the existing AVD is compatible; if necessary,
remove the AVD directory under `state/home/.android/avd` and recreate it.

### SSH

Settings: key-only authentication, `PasswordAuthentication no`, `PermitRootLogin no`,
`AuthorizedKeysFile /etc/flutterdev/access/authorized_keys`.

```bash
ssh -p "${SSH_HOST_PORT}" dev@"${SSH_BIND_ADDRESS}"
ssh -p "${SSH_HOST_PORT}" -L "${WEB_HOST_PORT}:127.0.0.1:${WEB_CONTAINER_PORT}" dev@"${SSH_BIND_ADDRESS}"
```

Host keys are created on first start in `state/ssh` and are not baked into the image.

### OpenCode and MCP

`config/opencode/opencode.jsonc` is mounted read-only at
`/home/dev/.config/opencode` on startup. Addresses and keys are substituted from
environment variables that Compose explicitly passes into the container:

- `dart mcp-server` - local Dart/Flutter MCP;
- `SEARXNG_MCP_URL` - external SearXNG MCP;
- `PLAYWRIGHT_MCP_URL` - external Playwright MCP;
- `LOCAL_LLM_BASE_URL`, `LOCAL_LLM_MODEL`, `LOCAL_LLM_API_KEY` - inference;
- `OPENCODE_GO_BASE_URL`, `OPENCODE_GO_API_KEY` - OpenCode Go provider.

OpenCode Go models are available as `opencode-go/<model-id>`; the provider uses the
base URL and API key from `.env`.

The `/mcp` suffix is not appended automatically: the full verified endpoint must be
provided in `.env`. Playwright MCP must run in a separate browser container on the
`DOCKER_NETWORK` network. OpenCode authentication is stored in the persistent HOME
(`state/home/.local/share/opencode`), not in the image.

### Agent runbook and runtime topology

`workspace/AGENTS.md` is the canonical container runbook. It is tracked in the
infrastructure repository through a `.gitignore` exception; the rest of
`workspace/` remains ignored. OpenCode includes it through the `instructions`
setting in `config/opencode/opencode.jsonc`.

At startup the entrypoint generates `/run/flutterdev/topology.json` from the
container environment. It contains resolved non-secret values: the internal Web
URL, browser render URL, MCP endpoints, model endpoints, AVD, SDK and toolchain
paths. API keys are not written to this file.

Print the topology and file paths with:

```bash
fd-info
```

Project-specific rules belong in each project's own `AGENTS.md`; they are
combined with the container runbook. Do not store local addresses or secrets in
the tracked runbook.

### Git

Git commands, including local commits, are available to the `dev` user. Public
repositories are accessible over HTTPS without keys. Keys for private remotes are not
passed by default - run normal `commit`/`pull`/`push` on the host in `workspace/PROJECT`.

Tokens in remote URLs are forbidden: `.git/config` is readable by the container.

The optional global Git configuration is disabled. To enable it:

```bash
cp config/git/config.example config/git/config
```

Then uncomment both the mount and the `GIT_CONFIG_GLOBAL` variable in `compose.yaml`.
Local project identity settings can override the global ones.

## Update and rollback

```bash
./scripts/update.sh
```

Order of operations: validate `.env`/`versions.env`/Docker, save the previous image
under a rollback tag in `state/updates`, build with `--pull --no-cache`, verify the new
image without mounts and without SSH/emulator, record actual versions, ask for
confirmation, recreate the container with the same mounts, and verify services.

The floating `stable`/`lts` policies update Flutter, Node.js, and OpenCode on rebuild
even without changes to `versions.env`.

Rollback:

```bash
./scripts/rollback.sh
```

Only the image is rolled back. The contents of `workspace/` and `state/` are not rolled
back - separate backups are required for user state.

An update does not run git pull in projects, does not change their lockfiles, and does
not update external services. `workspace/` and `state/` are not deleted. System packages
installed manually in a running container are lost on recreation: add permanent
additions to the Dockerfile.

## Checks

```bash
docker compose exec --user dev flutterdev check.sh
```

The checks cover Flutter, Dart, OpenCode, Node.js, Python/venv, Git, JDK, Android tools,
jq/mc, KVM, AVD, OpenCode configuration, and MCP/LLM availability. An unreachable
Playwright MCP or local LLM produces a warning; use `check.sh --strict-playwright` for
strict Playwright validation.

## Security and limitations

- No privileged mode, Docker socket, or host networking.
- `dev` has no sudo.
- CPU/RAM/PID limits and `no-new-privileges` are enabled.
- The entrypoint and sshd run as root with minimal capabilities; user processes run
  only as `dev`.
- The RW `workspace/` is writable and removable by the agent. Containerization does not
  replace Git and backups.
- `state/home` contains authentication secrets and must be protected on the host.
- Root-owned directories in `workspace` are not fixed automatically. Check permissions
  before startup; no recursive `chown` of the entire workspace is performed.
