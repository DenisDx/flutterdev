# flutterdev

Постоянная среда разработки Flutter-приложений в Docker: OpenCode, Flutter/Dart SDK,
Dart/Flutter MCP, Node.js LTS, Python 3, Git, JDK, Android SDK и headless Android Emulator.

Управление выполняется через Docker Compose. Каталог инфраструктуры и постоянных
пользовательских данных — `/home/denis/flutterdev`.

## Состав

- `Dockerfile`, `compose.yaml` — образ и запуск контейнера `flutterdev`.
- `versions.env` — политики версий (stable/lts) и параметры Android.
- `.env` — реальные локальные адреса, порты и секреты (не коммитится, режим `0600`).
- `.env.example` — шаблон без реальных значений.
- `scripts/entrypoint.sh` — запуск sshd, генерация host keys, создание AVD.
- `scripts/check.sh` — проверка инструментов, Android, mounts и внешних сервисов.
- `scripts/update.sh` — сборка нового образа, проверка, пересоздание контейнера.
- `scripts/rollback.sh` — откат на предыдущий образ.
- `config/opencode/opencode.jsonc` — конфигурация OpenCode (монтируется только для чтения).
- `config/git/config.example` — необязательная глобальная конфигурация Git.
- `workspace/` — независимые проекты со своими `.git`.
- `state/` — постоянный HOME, SSH host keys, authorized_keys и данные обновлений.

## Требования

- Linux-хост с Docker и Docker Compose v2.
- Доступное устройство `/dev/kvm` и включённая аппаратная виртуализация.
- Свободные порты из `.env` (по умолчанию внешние `28080` для Web и `20022` для SSH).
- Внешняя Docker-сеть для связи с browser-контейнером (`DOCKER_NETWORK`).
- Внешние сервисы: SearXNG MCP, Playwright MCP с Chromium, сервер инференса.
  Их полные endpoint'ы задаются только в `.env`.

## Первичная настройка

1. Создайте `.env` из шаблона и заполните реальные значения:

   ```bash
   cp .env.example .env
   chmod 600 .env
   ```

   UID/GID пользователя `dev`:

   ```bash
   id -u; id -g
   ```

   GID устройства KVM:

   ```bash
   stat -c %g /dev/kvm
   ```

   В реальном `.env` для доступа из LAN укажите LAN-адрес хоста в
   `WEB_BIND_ADDRESS` и `SSH_BIND_ADDRESS` (либо `0.0.0.0`), а не `127.0.0.1`.
   Доступ ограничивайте firewall. При bind на loopback используйте SSH-туннель.

2. Создайте каталоги и файл с разрешёнными входящими SSH-ключами:

   ```bash
   mkdir -p workspace state/home state/ssh state/access state/updates
   chmod 700 state/ssh
   cat ~/.ssh/id_ed25519.pub > state/access/authorized_keys
   chmod 600 state/access/authorized_keys
   ```

   Приватные ключи, SSH-agent и Docker socket в контейнер не передаются.
   `authorized_keys` даёт только входящий доступ к контейнеру.

3. Создайте общую внешнюю сеть один раз:

   ```bash
   docker network create "${DOCKER_NETWORK}"
   ```

4. Для сборки образа требуется осознанное согласие с условиями Android SDK.
   В реальном `.env` задайте:

   ```dotenv
   ANDROID_ACCEPT_LICENSES=true
   ```

5. Соберите образ и запустите контейнер:

   ```bash
   ./scripts/update.sh
   ```

   Скрипт собирает образ с `--pull --no-cache`, проверяет его без пользовательских
   mounts, записывает версии в `state/updates/` и после подтверждения пересоздаёт
   контейнер. Для неинтерактивного запуска используйте `./scripts/update.sh --yes`.

Альтернативная первая сборка вручную:

```bash
docker compose --env-file .env --env-file versions.env build --pull
docker compose --env-file .env up -d
```

## Работа

Открыть shell пользователя `dev`:

```bash
docker compose exec --user dev flutterdev bash
cd /workspace/PROJECT
opencode
```

Всегда используйте `--user dev` для пользовательских сессий, Flutter, OpenCode и проверок.
Root-процессы контейнера — только entrypoint и sshd.

### Flutter Web

Запуск dev-сервера из каталога проекта:

```bash
flutter run -d web-server \
  --web-hostname 0.0.0.0 \
  --web-port "$WEB_CONTAINER_PORT"
```

Web публикуется на `WEB_BIND_ADDRESS:WEB_HOST_PORT`. Browser-контейнер обращается к
`http://flutterdev:WEB_CONTAINER_PORT` по общей Docker-сети.

### Android Emulator

Emulator работает headless. AVD создаётся entrypoint'ом при первом запуске в постоянном
`HOME` (`state/home/.android/avd`); system image находится в SDK образа. Запуск:

```bash
emulator -avd "$ANDROID_AVD_NAME" -no-window -no-audio -gpu swiftshader_indirect
adb devices
```

ADB и emulator-порты на хост по умолчанию не публикуются. Для ускорения контейнеру
передаётся `/dev/kvm`, а `dev` получает группу с GID устройства хоста (`KVM_GID`).
Привилегированный режим не используется.

После обновления system image проверьте совместимость существующего AVD; при
необходимости удалите каталог AVD в `state/home/.android/avd` и пересоздайте его.

### SSH

Параметры: только ключи, `PasswordAuthentication no`, `PermitRootLogin no`,
`AuthorizedKeysFile /etc/flutterdev/access/authorized_keys`.

```bash
ssh -p "${SSH_HOST_PORT}" dev@"${SSH_BIND_ADDRESS}"
ssh -p "${SSH_HOST_PORT}" -L 28080:127.0.0.1:8080 dev@"${SSH_BIND_ADDRESS}"
```

Host keys создаются при первом запуске в `state/ssh` и не запекаются в образ.

### OpenCode и MCP

`config/opencode/opencode.jsonc` подключается при запуске в
`/home/dev/.config/opencode` только для чтения. Адреса и ключи подставляются из
переменных окружения, которые Compose явно передаёт в контейнер:

- `dart mcp-server` — локальный Dart/Flutter MCP;
- `SEARXNG_MCP_URL` — внешний SearXNG MCP;
- `PLAYWRIGHT_MCP_URL` — внешний Playwright MCP;
- `LOCAL_LLM_BASE_URL`, `LOCAL_LLM_MODEL`, `LOCAL_LLM_API_KEY` — инференс.

Суффикс `/mcp` автоматически не добавляется: в `.env` указывается полный проверенный
endpoint. Playwright MCP должен быть запущен в отдельном browser-контейнере в сети
`DOCKER_NETWORK`. Аутентификация OpenCode хранится в постоянном HOME
(`state/home/.local/share/opencode`), а не в образе.

### Git

Git-команды, включая локальный commit, доступны пользователю `dev`. Публичные
репозитории доступны по HTTPS без ключей. Ключи для приватных remotes по умолчанию
не передаются — обычный `commit`/`pull`/`push` выполняйте на хосте в `workspace/PROJECT`.

Токены в remote URL запрещены: `.git/config` доступен контейнеру.

Необязательная глобальная конфигурация Git отключена. Чтобы включить:

```bash
cp config/git/config.example config/git/config
```

Затем одновременно раскомментируйте mount и переменную `GIT_CONFIG_GLOBAL` в
`compose.yaml`. Локальные identity-настройки проектов могут переопределять глобальные.

## Обновление и откат

```bash
./scripts/update.sh
```

Порядок: проверка `.env`/`versions.env`/Docker, сохранение предыдущего образа под
rollback-тегом в `state/updates`, сборка `--pull --no-cache`, проверка нового образа
без mounts и без SSH/эмулятора, запись фактических версий, подтверждение, пересоздание
контейнера с теми же mounts, проверка сервисов.

Плавающие политики `stable`/`lts` обновляют Flutter, Node.js и OpenCode при пересборке
даже без изменения `versions.env`.

Откат:

```bash
./scripts/rollback.sh
```

Откатывается только образ. Содержимое `workspace/` и `state/` не откатывается —
для пользовательского состояния нужна отдельная резервная копия.

Обновление не выполняет git pull проектов, не меняет их lockfiles и не обновляет
внешние сервисы. `workspace/` и `state/` не удаляются. Системные доустановки в
работающем контейнере теряются при пересоздании: постоянные дополнения добавляйте
в Dockerfile.

## Проверки

```bash
docker compose exec --user dev flutterdev check.sh
```

Проверяются Flutter, Dart, OpenCode, Node.js, Python/venv, Git, JDK, Android tools,
jq/mc, KVM, AVD, конфигурация OpenCode и доступность MCP/LLM. Недоступность
Playwright MCP и локального LLM — предупреждение; для строгой проверки Playwright
используйте `check.sh --strict-playwright`.

## Безопасность и ограничения

- Нет privileged, Docker socket и host networking.
- У `dev` нет sudo.
- Заданы лимиты CPU/RAM/PIDs и `no-new-privileges`.
- Entrypoint и sshd запускаются root с минимальными capabilities; пользовательские
  процессы — только `dev`.
- RW `workspace/` доступен агенту на изменение и удаление. Контейнеризация не заменяет
  Git и резервные копии.
- `state/home` содержит секреты авторизации и требует защиты на хосте.
- Root-owned каталоги в `workspace` автоматически не исправляются. Проверяйте права
  до запуска; рекурсивный `chown` всего workspace не выполняется.
