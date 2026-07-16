#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="$ROOT_DIR/App/shell/desktop"
AGENT_DIR="$ROOT_DIR/App/memmy-agent"
MEMORY_DIR="$ROOT_DIR/Memory"
RUNTIME_DIR="$DESKTOP_DIR/dist/runtime"
CLI_BIN_DIR="$RUNTIME_DIR/bin"
DMG_HELPER_DIR="$DESKTOP_DIR/dist/dmg"

resolve_target_cpu() {
  local target_cpu=""

  for arg in "$@"; do
    case "$arg" in
      --arm64|arm64)
        target_cpu="arm64"
        ;;
      --x64|x64)
        target_cpu="x64"
        ;;
      --universal|universal)
        echo "Universal macOS packaging is not supported by this script yet; build --arm64 and --x64 separately." >&2
        exit 1
        ;;
    esac
  done

  if [ -z "$target_cpu" ]; then
    case "$(uname -m)" in
      arm64)
        target_cpu="arm64"
        ;;
      x86_64)
        target_cpu="x64"
        ;;
      *)
        echo "Cannot infer macOS packaging CPU from uname -m. Pass --arm64 or --x64." >&2
        exit 1
        ;;
    esac
  fi

  echo "$target_cpu"
}

create_cli_launcher() {
  local output_path="$1"
  local asar_entry="$2"

  cat > "$output_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SOURCE="\${BASH_SOURCE[0]}"
while [ -L "\$SOURCE" ]; do
  SOURCE_DIR="\$(cd -P "\$(dirname "\$SOURCE")" && pwd)"
  TARGET="\$(readlink "\$SOURCE")"
  if [[ "\$TARGET" == /* ]]; then
    SOURCE="\$TARGET"
  else
    SOURCE="\$SOURCE_DIR/\$TARGET"
  fi
done
SCRIPT_DIR="\$(cd -P "\$(dirname "\$SOURCE")" && pwd)"
RESOURCES_DIR="\$(cd "\$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="\$RESOURCES_DIR/../MacOS"
APP_EXEC="\$MACOS_DIR/Memmy"

if [ ! -x "\$APP_EXEC" ]; then
  for candidate in "\$MACOS_DIR"/*; do
    if [ -f "\$candidate" ] && [ -x "\$candidate" ]; then
      APP_EXEC="\$candidate"
      break
    fi
  done
fi

if [ ! -x "\$APP_EXEC" ]; then
  echo "Cannot find Memmy app executable under \$MACOS_DIR" >&2
  exit 1
fi

DEFAULT_CONFIG="\$HOME/.memmy/config.yaml"
if [ -z "\${MEMMY_CONFIG:-}" ] && [ -f "\$DEFAULT_CONFIG" ]; then
  export MEMMY_CONFIG="\$DEFAULT_CONFIG"
fi

export ELECTRON_RUN_AS_NODE=1
export NODE_ENV="\${NODE_ENV:-production}"
exec "\$APP_EXEC" "\$RESOURCES_DIR/app.asar/$asar_entry" "\$@"
EOF

  chmod 755 "$output_path"
}

create_cli_installer() {
  local output_path="$1"

  cat > "$output_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  TARGET="$(readlink "$SOURCE")"
  if [[ "$TARGET" == /* ]]; then
    SOURCE="$TARGET"
  else
    SOURCE="$SOURCE_DIR/$TARGET"
  fi
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PREFIX="${MEMMY_CLI_PREFIX:-}"

usage() {
  cat <<'USAGE'
Usage: install-cli [--prefix <dir>]

Installs symlinks for:
  memmy-memory
  memmy-agent
  memmy

Default prefix:
  /usr/local/bin when writable, otherwise ~/.local/bin
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      if [ "$#" -lt 2 ]; then
        echo "--prefix requires a directory" >&2
        exit 1
      fi
      PREFIX="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$PREFIX" ]; then
  if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    PREFIX="/usr/local/bin"
  else
    PREFIX="$HOME/.local/bin"
  fi
fi

mkdir -p "$PREFIX"
ln -sf "$SCRIPT_DIR/memmy-memory" "$PREFIX/memmy-memory"
ln -sf "$SCRIPT_DIR/memmy-agent" "$PREFIX/memmy-agent"
ln -sf "$SCRIPT_DIR/memmy" "$PREFIX/memmy"

add_local_bin_to_profile() {
  local profile_path="$1"
  local marker="# Memmy CLI PATH"

  if [ ! -f "$profile_path" ] || ! grep -Fq "$marker" "$profile_path"; then
    {
      echo ""
      echo "$marker"
      echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> "$profile_path"
  fi
}

cat <<MESSAGE
Memmy CLI installed:
  $PREFIX/memmy-memory -> $SCRIPT_DIR/memmy-memory
  $PREFIX/memmy-agent  -> $SCRIPT_DIR/memmy-agent
  $PREFIX/memmy        -> $SCRIPT_DIR/memmy
MESSAGE

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    if [ "$PREFIX" = "$HOME/.local/bin" ]; then
      add_local_bin_to_profile "$HOME/.zshrc"
      add_local_bin_to_profile "$HOME/.bash_profile"
      cat <<MESSAGE

Added ~/.local/bin to ~/.zshrc and ~/.bash_profile when needed.
Run the command for your shell now, or open a new terminal:

  source ~/.zshrc
  source ~/.bash_profile
MESSAGE
    else
      cat <<MESSAGE

Warning: $PREFIX is not in PATH for this shell.
Add this line to ~/.zshrc, then open a new terminal:

  export PATH="$PREFIX:\$PATH"
MESSAGE
    fi
    ;;
esac
EOF

  chmod 755 "$output_path"
}

create_dmg_cli_installer_command() {
  local output_path="$1"

  cat > "$output_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/Memmy.app"
INSTALLER="$APP_PATH/Contents/Resources/cli/install-cli"

if [ ! -x "$INSTALLER" ]; then
  MESSAGE="Please drag Memmy to Applications first, then run Install CLI again."
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display dialog \"$MESSAGE\" buttons {\"OK\"} default button \"OK\" with icon caution" >/dev/null
  else
    echo "$MESSAGE" >&2
  fi
  exit 1
fi

"$INSTALLER"

echo
echo "Done. You can close this window."
EOF

  chmod 755 "$output_path"
}

create_memory_runtime_manifest() {
  local output_dir="$1"

  ROOT_DIR="$ROOT_DIR" MEMORY_DIR="$MEMORY_DIR" MEMORY_RUNTIME_DIR="$output_dir" node --input-type=module <<'NODE'
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const rootDir = requiredEnv("ROOT_DIR");
const memoryDir = requiredEnv("MEMORY_DIR");
const runtimeDir = requiredEnv("MEMORY_RUNTIME_DIR");
const runtimeName = "memmy-memory-runtime";
const runtimeVersion = "0.0.0";

const memoryPackage = JSON.parse(await readFile(join(memoryDir, "package.json"), "utf8"));
const rootLock = JSON.parse(await readFile(join(rootDir, "package-lock.json"), "utf8"));
const dependencies = memoryPackage.dependencies ?? {};
const runtimePackage = {
  name: runtimeName,
  version: runtimeVersion,
  private: true,
  type: "module",
  dependencies
};
const runtimeLock = JSON.parse(JSON.stringify(rootLock));
runtimeLock.name = runtimeName;
runtimeLock.version = runtimeVersion;
runtimeLock.packages ??= {};
runtimeLock.packages[""] = {
  name: runtimeName,
  version: runtimeVersion,
  private: true,
  type: "module",
  dependencies
};

await mkdir(runtimeDir, { recursive: true });
await writeFile(join(runtimeDir, "package.json"), `${JSON.stringify(runtimePackage, null, 2)}\n`);
await writeFile(join(runtimeDir, "package-lock.json"), `${JSON.stringify(runtimeLock, null, 2)}\n`);

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}
NODE
}

cd "$ROOT_DIR"

# Guard the Node version because a version newer than Electron's embedded Node builds native modules
# such as better-sqlite3 against the wrong ABI. Package with Node 20 or 22 to match Electron and CI.
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -gt 22 ]; then
  echo "[package] 错误:当前 Node $(node -v) 主版本 > 22,与 Electron 内嵌 Node 不匹配。" >&2
  echo "[package] 这会让包内 better-sqlite3 按错误 ABI 构建,装到机器上记忆管理会报错(dev 却正常)。" >&2
  echo "[package] 请改用 Node 20 或 22 打包,例如:" >&2
  echo "[package]   export PATH=\"/opt/homebrew/opt/node@20/bin:\$PATH\" && node -v" >&2
  echo "[package] 确需强制继续:MEMMY_ALLOW_NODE_MISMATCH=1" >&2
  if [ "${MEMMY_ALLOW_NODE_MISMATCH:-}" != "1" ]; then
    exit 1
  fi
fi

BUILDER_CONFIG="electron-builder.yml"
TARGET_CPU="$(resolve_target_cpu "$@")"
if [ "${MEMMY_SKIP_CODESIGN:-}" = "1" ]; then
  BUILDER_CONFIG="electron-builder.unsigned.yml"
  echo "Building unsigned DMG for local testing. This build is not notarized."
fi

echo "Preparing macOS $TARGET_CPU package."

# Synchronize dependencies before building because pulled or merged package.json changes can add modules.
# Checking only for tsc or electron-builder misses new dependencies and causes module-resolution failures.
# npm install is idempotent; use MEMMY_SKIP_INSTALL=1 only when node_modules is known to be current.
if [ "${MEMMY_SKIP_INSTALL:-}" = "1" ]; then
  echo "[package] MEMMY_SKIP_INSTALL=1;跳过依赖同步(请自行确保 node_modules 与 package.json 一致)。"
else
  echo "[package] 同步依赖(npm install)以避免合并/拉取后的依赖漂移..."
  npm install
  npm install --prefix "$AGENT_DIR"
fi

npm run build -w @memmy/memory
npm --prefix "$AGENT_DIR" run build
npm run build -w @memmy/desktop

rm -rf "$RUNTIME_DIR"
rm -rf "$DMG_HELPER_DIR"
mkdir -p "$RUNTIME_DIR/memory" "$RUNTIME_DIR/memmy-agent" "$CLI_BIN_DIR" "$DMG_HELPER_DIR"
cp -R "$MEMORY_DIR/dist/src" "$RUNTIME_DIR/memory/src"
cp -R "$AGENT_DIR/dist" "$RUNTIME_DIR/memmy-agent/dist"
create_memory_runtime_manifest "$RUNTIME_DIR/memory"
npm ci --prefix "$RUNTIME_DIR/memory" --omit=dev --os=darwin --cpu="$TARGET_CPU"
ELECTRON_VERSION="$(node -p "require('./App/shell/desktop/node_modules/electron/package.json').version")"
node_modules/.bin/electron-rebuild \
  -f \
  -v "$ELECTRON_VERSION" \
  -a "$TARGET_CPU" \
  -w better-sqlite3 \
  -m "$RUNTIME_DIR/memory"
cp "$AGENT_DIR/package.json" "$RUNTIME_DIR/memmy-agent/package.json"
cp "$AGENT_DIR/package-lock.json" "$RUNTIME_DIR/memmy-agent/package-lock.json"
npm ci --prefix "$RUNTIME_DIR/memmy-agent" --omit=dev --os=darwin --cpu="$TARGET_CPU"
create_cli_launcher "$CLI_BIN_DIR/memmy-memory" "dist/runtime/memory/src/cli/index.js"
create_cli_launcher "$CLI_BIN_DIR/memmy-agent" "dist/runtime/memmy-agent/dist/main.js"
create_cli_launcher "$CLI_BIN_DIR/memmy" "dist/runtime/memmy-agent/dist/main.js"
create_cli_installer "$CLI_BIN_DIR/install-cli"
create_dmg_cli_installer_command "$DMG_HELPER_DIR/Install CLI.command"

if [ "${MEMMY_PACKAGE_PREPARE_ONLY:-}" = "1" ]; then
  echo "Prepared desktop runtime resources at $RUNTIME_DIR"
  exit 0
fi

cd "$DESKTOP_DIR"
BUILDER_ARGS=(--config "$BUILDER_CONFIG")
if [ -n "${MEMMY_ELECTRON_DIST:-}" ]; then
  BUILDER_ARGS+=(--config.electronDist="$MEMMY_ELECTRON_DIST")
fi

npx electron-builder "${BUILDER_ARGS[@]}" --mac dmg "$@"
