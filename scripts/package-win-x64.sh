#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="$ROOT_DIR/App/shell/desktop"
AGENT_DIR="$ROOT_DIR/App/memmy-agent"
MEMORY_DIR="$ROOT_DIR/Memory"
RUNTIME_DIR="$DESKTOP_DIR/dist/runtime"
CLI_BIN_DIR="$RUNTIME_DIR/bin"

if [ "${MEMMY_SKIP_CODESIGN:-}" = "1" ]; then
  BUILDER_CONFIG="electron-builder.win.unsigned.yml"
else
  BUILDER_CONFIG="electron-builder.win.yml"
fi

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

create_memory_runtime_manifest() {
  node - "$MEMORY_DIR/package.json" "$RUNTIME_DIR/memory/package.json" <<'NODE'
const { readFileSync, writeFileSync } = require("node:fs");

const [sourcePackagePath, runtimePackagePath] = process.argv.slice(2);
const sourcePackage = JSON.parse(readFileSync(sourcePackagePath, "utf8"));
const runtimePackage = {
  name: "@memmy/packaged-memory-runtime",
  private: true,
  type: "module",
  dependencies: sourcePackage.dependencies ?? {}
};

writeFileSync(runtimePackagePath, `${JSON.stringify(runtimePackage, null, 2)}\n`);
NODE

  create_memory_runtime_lock
}

create_memory_runtime_lock() {
  if [ -f "$MEMORY_DIR/package-lock.json" ]; then
    cp "$MEMORY_DIR/package-lock.json" "$RUNTIME_DIR/memory/package-lock.json"
    return
  fi

  npm install --prefix "$RUNTIME_DIR/memory" --package-lock-only --ignore-scripts --os=win32 --cpu=x64
}

create_windows_cli_launcher() {
  local output_path="$1"
  local asar_entry="$2"

  cat > "$output_path" <<EOF
@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "RESOURCES_DIR=%%~fI"
for %%I in ("%RESOURCES_DIR%..") do set "APP_DIR=%%~fI"
set "APP_EXEC=%APP_DIR%\Memmy.exe"
set "ENTRY=%RESOURCES_DIR%\app.asar\\$asar_entry"

if not exist "%APP_EXEC%" (
  echo Cannot find Memmy executable: "%APP_EXEC%" 1>&2
  exit /b 1
)

if not defined MEMMY_CONFIG if exist "%USERPROFILE%\.memmy\config.yaml" set "MEMMY_CONFIG=%USERPROFILE%\.memmy\config.yaml"
set "ELECTRON_RUN_AS_NODE=1"
if not defined NODE_ENV set "NODE_ENV=production"

"%APP_EXEC%" "%ENTRY%" %*
exit /b %ERRORLEVEL%
EOF
}

require_windows_signing_env() {
  local csc_link="${WIN_CSC_LINK:-${CSC_LINK:-}}"
  local csc_password="${WIN_CSC_KEY_PASSWORD:-${CSC_KEY_PASSWORD:-}}"

  if [ -z "$csc_link" ] || [ -z "$csc_password" ]; then
    cat >&2 <<'EOF'
Windows signed packaging requires a Windows code-signing certificate.

Set either:
  WIN_CSC_LINK=/absolute/path/to/windows-code-signing.pfx
  WIN_CSC_KEY_PASSWORD=...

or the electron-builder fallback names:
  CSC_LINK=/absolute/path/to/windows-code-signing.pfx
  CSC_KEY_PASSWORD=...

For an unsigned local smoke package, run:
  npm run package:win:unsigned
EOF
    exit 1
  fi
}

verify_windows_native_module() {
  local better_sqlite_node="$RUNTIME_DIR/memory/node_modules/better-sqlite3/build/Release/better_sqlite3.node"

  if [ ! -f "$better_sqlite_node" ]; then
    echo "Missing better-sqlite3 native module: $better_sqlite_node" >&2
    exit 1
  fi

  local file_description
  file_description="$(file "$better_sqlite_node")"
  echo "$file_description"

  case "$file_description" in
    *PE32+*x86-64* | *PE32+*AMD64*)
      ;;
    *)
      echo "Expected a Windows x64 better-sqlite3 native module." >&2
      exit 1
      ;;
  esac
}

verify_windows_onnxruntime_module() {
  local onnxruntime_node="$RUNTIME_DIR/memory/node_modules/onnxruntime-node/bin/napi-v3/win32/x64/onnxruntime_binding.node"

  if [ ! -f "$onnxruntime_node" ]; then
    echo "Missing onnxruntime-node Windows x64 native module: $onnxruntime_node" >&2
    exit 1
  fi

  local file_description
  file_description="$(file "$onnxruntime_node")"
  echo "$file_description"

  case "$file_description" in
    *PE32+*x86-64* | *PE32+*AMD64*)
      ;;
    *)
      echo "Expected a Windows x64 onnxruntime-node native module." >&2
      exit 1
      ;;
  esac
}

npm_ci_win_x64() {
  local package_dir="$1"

  npm ci --prefix "$package_dir" --omit=dev --ignore-scripts --os=win32 --cpu=x64
}

install_better_sqlite3_win_x64() {
  local electron_version
  electron_version="${MEMMY_ELECTRON_VERSION:-$(node -p "require('$DESKTOP_DIR/node_modules/electron/package.json').version")}"

  (
    cd "$RUNTIME_DIR/memory/node_modules/better-sqlite3"
    ../.bin/prebuild-install --platform win32 --arch x64 --runtime electron --target "$electron_version"
  )
}

if [ "${MEMMY_SKIP_CODESIGN:-}" != "1" ]; then
  require_windows_signing_env
else
  log "MEMMY_SKIP_CODESIGN=1, building unsigned Windows smoke package"
fi

if [ ! -d "$ROOT_DIR/node_modules" ]; then
  log "Installing root workspace dependencies"
  npm install
fi

if [ ! -d "$AGENT_DIR/node_modules" ]; then
  log "Installing memmy-agent dependencies"
  npm ci --prefix "$AGENT_DIR"
fi

log "Building Memory workspace"
npm run build -w @memmy/memory

log "Building memmy-agent CLI"
npm run build --prefix "$AGENT_DIR"

log "Building Electron desktop shell"
npm run build -w @memmy/desktop

log "Preparing Windows x64 packaged runtime"
rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR/memory" "$RUNTIME_DIR/memmy-agent" "$CLI_BIN_DIR"

cp -R "$MEMORY_DIR/dist/src" "$RUNTIME_DIR/memory/src"
create_memory_runtime_manifest

log "Installing Windows x64 Memory runtime dependencies"
npm_ci_win_x64 "$RUNTIME_DIR/memory"
install_better_sqlite3_win_x64
verify_windows_native_module
verify_windows_onnxruntime_module

cp -R "$AGENT_DIR/dist" "$RUNTIME_DIR/memmy-agent/dist"
cp "$AGENT_DIR/package.json" "$RUNTIME_DIR/memmy-agent/package.json"
cp "$AGENT_DIR/package-lock.json" "$RUNTIME_DIR/memmy-agent/package-lock.json"

log "Installing Windows x64 memmy-agent runtime dependencies"
npm_ci_win_x64 "$RUNTIME_DIR/memmy-agent"

log "Creating Windows CLI launchers"
create_windows_cli_launcher "$CLI_BIN_DIR/memmy-memory.cmd" "dist\\runtime\\memory\\src\\cli\\index.js"
create_windows_cli_launcher "$CLI_BIN_DIR/memmy-agent.cmd" "dist\\runtime\\memmy-agent\\dist\\main.js"
create_windows_cli_launcher "$CLI_BIN_DIR/memmy.cmd" "dist\\runtime\\memmy-agent\\dist\\main.js"

log "Packaging Windows x64 installer"
cd "$DESKTOP_DIR"

BUILDER_ARGS=(--config "$BUILDER_CONFIG")
if [ -n "${MEMMY_ELECTRON_DIST:-}" ]; then
  BUILDER_ARGS+=(--config.electronDist="$MEMMY_ELECTRON_DIST")
fi

npx electron-builder "${BUILDER_ARGS[@]}" --win nsis --x64 "$@"

log "Done. Output directory: $DESKTOP_DIR/release"
