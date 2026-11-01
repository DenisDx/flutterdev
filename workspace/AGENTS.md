# flutterdev container runbook

This file is the canonical operating guide for agents working inside the
flutterdev container. It applies to every project under `/workspace`.

## First steps

1. Read `/run/flutterdev/topology.json` for resolved, non-secret values.
2. Run `fd-info` for a human-readable summary and file paths.
3. Read the project's own `AGENTS.md` for project-specific build and test rules.

Do not guess addresses or ports. Use environment variables or `topology.json`.
Never print secret values from the environment.

## Topology

- Container: `flutterdev`.
- Shared Docker network: `DOCKER_NETWORK`.
- Browser container service name: `browser`.
- Playwright MCP endpoint: `PLAYWRIGHT_MCP_URL`.
- SearXNG MCP endpoint: `SEARXNG_MCP_URL`.
- Local LLM: `LOCAL_LLM_BASE_URL`, model `LOCAL_LLM_MODEL`.
- OpenCode Go: `OPENCODE_GO_BASE_URL` and `OPENCODE_GO_API_KEY`.
- Flutter Web inside the network: `http://flutterdev:${WEB_CONTAINER_PORT}`.

Host access to Web and SSH is configured by the operator outside the container.
The container does not know host LAN addresses. Do not hardcode them.

## Filesystem

- `/workspace` - projects; each project has its own `.git`. This file appears at
  `/workspace/AGENTS.md`.
- `/home/dev` - persistent HOME (OpenCode auth, caches, AVD, Gradle, pub cache).
- `/home/dev/.config/opencode/opencode.jsonc` - OpenCode config, mounted read-only.
- `/opt/flutter` - Flutter SDK; Dart is `/opt/flutter/bin/dart`.
- `/opt/android-sdk` - Android SDK; `adb`, `emulator`, `sdkmanager`, `avdmanager`.
- `/opt/java-home` - `JAVA_HOME`.
- `/run/flutterdev/topology.json` - generated runtime topology.

Do not edit files under `/home/dev/.config/opencode`; edit them on the host.
If a project-specific OpenCode override is needed (model options, extra MCP
servers, permission tweaks), create or edit `/workspace/opencode.jsonc`.
OpenCode deep-merges it over the global config at startup.

## What to start manually

Flutter Web and the Android emulator are not started automatically.

Flutter Web:

```bash
cd /workspace/PROJECT
flutter run -d web-server --web-hostname 0.0.0.0 --web-port "$WEB_CONTAINER_PORT"
```

Wait until the server responds. Use the internal URL from `topology.json`.

Android emulator:

```bash
emulator -avd "$ANDROID_AVD_NAME" -no-window -no-audio -gpu swiftshader_indirect
adb wait-for-device
adb shell getprop sys.boot_completed
```

Wait for `1` before installing or testing the app.

## Browser rendering and screenshots

Do not install or run Chromium inside the flutterdev container. Use the
Playwright MCP server in the browser container.

OpenCode already has the Playwright MCP server configured. In OpenCode, its tools
are exposed under the `playwright` MCP server. For other MCP clients, connect to
`PLAYWRIGHT_MCP_URL` (streamable HTTP). Use the endpoint exactly as provided; do
not append `/mcp`.

Workflow:

1. Start the Flutter Web server.
2. Navigate to `http://flutterdev:${WEB_CONTAINER_PORT}` (not `localhost`, not
   `127.0.0.1`).
3. Use `browser_navigate`, `browser_snapshot`, `browser_click`,
   `browser_take_screenshot`, and related Playwright MCP tools.
4. Treat screenshot results as MCP image content returned to the agent.

Do not assume the browser container shares `/workspace`. If a persistent
screenshot file is required, use an explicit shared volume configured by the
operator.

For Android UI screenshots and hierarchy:

```bash
adb exec-out screencap -p > /workspace/PROJECT/screenshot.png
adb shell uiautomator dump /sdcard/window.xml
adb pull /sdcard/window.xml /workspace/PROJECT/window.xml
```

## MCP servers

- `dart`: local stdio server, command `dart mcp-server`.
- `searxng`: remote MCP at `SEARXNG_MCP_URL`.
- `playwright`: remote MCP at `PLAYWRIGHT_MCP_URL`.

Use full endpoints from the environment. Do not add suffixes.

## Models

OpenCode providers:

- `local-llm/local-model` - OpenAI-compatible server at `LOCAL_LLM_BASE_URL`.
- `opencode-go/<model-id>` - OpenCode Go via `OPENCODE_GO_BASE_URL` and
  `OPENCODE_GO_API_KEY`.
- `deepseek` - built-in provider via `DEEPSEEK_API_KEY`.

Select a model with `-m provider/model` or the `/models` command. Do not print
keys.

## Git and state

- Commit, pull, and push in the project on the host. The container has no private
  keys or tokens for private remotes.
- Never put tokens in remote URLs.
- Do not run recursive `chown` on `/workspace`.
- Do not delete or rewrite files in `/home/dev` unless the task requires it.
- `/home/dev` contains authentication data and is not a backup target.

## Safety

- Run user commands as `dev`. The container user has no sudo.
- No Docker socket, no privileged mode, no host networking.
- Stop long-running processes when finished to free resources.
- If a required value is missing, report it instead of inventing a value.
