#!/usr/bin/env bash
# Bootstrap mlwm on a fresh Arch Linux installation (bare metal or QEMU VM).
# Works whether piped via `curl -fsSL .../bootstrap.sh | bash` or run from a local checkout.
set -euo pipefail

REPO_URL="${MLWM_REPO_URL:-https://github.com/NandanBali/fatewm.git}"
BRANCH="${MLWM_BRANCH:-main}"
CURRENT_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
[ -n "$TARGET_HOME" ] || TARGET_HOME="${HOME:-/root}"
SRC_DIR="${MLWM_SRC_DIR:-$TARGET_HOME/mlwm}"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    if ! command -v sudo >/dev/null 2>&1; then
        echo "mlwm bootstrap: run as root or install/configure sudo first." >&2
        exit 1
    fi
    SUDO="sudo"
fi

if ! command -v pacman >/dev/null 2>&1; then
    echo "mlwm bootstrap: this script targets Arch Linux (pacman not found)." >&2
    exit 1
fi

echo "==> Installing Xorg, fonts, launchers, and OCaml build tools..."
$SUDO pacman -Syu --needed --noconfirm \
    git base-devel ocaml dune \
    xorg-server xorg-xinit xorg-xrandr libx11 libxrandr \
    xterm rofi dmenu ttf-dejavu

# Reuse the current checkout if run from inside it; otherwise clone/update REPO_URL.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/dune-project" ] && [ -f "$SCRIPT_DIR/packaging/arch/xinitrc" ]; then
    WORK_DIR="$SCRIPT_DIR"
else
    if [ -d "$SRC_DIR/.git" ]; then
        echo "==> Updating existing checkout in $SRC_DIR..."
        git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH"
        git -C "$SRC_DIR" checkout -q -B "$BRANCH" "origin/$BRANCH"
    else
        echo "==> Cloning $REPO_URL ($BRANCH) into $SRC_DIR..."
        git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
        if [ "$(id -u)" -eq 0 ] && [ "$CURRENT_USER" != "root" ]; then
            chown -R "$CURRENT_USER:$CURRENT_USER" "$SRC_DIR"
        fi
    fi
    WORK_DIR="$SRC_DIR"
fi

echo "==> Building and running pure unit tests..."
BUILD_DIR=$(mktemp -d /tmp/mlwm-bootstrap.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
(
    cd "$WORK_DIR"
    dune build --profile=release --build-dir="$BUILD_DIR"
    dune runtest --build-dir="$BUILD_DIR"
)
strip "$BUILD_DIR/default/bin/main.exe" -o "$BUILD_DIR/mlwm"

echo "==> Installing mlwm binary and X11 session files..."
$SUDO install -Dm755 "$BUILD_DIR/mlwm" /usr/local/bin/mlwm
$SUDO install -Dm644 "$WORK_DIR/packaging/arch/mlwm.desktop" /usr/share/xsessions/mlwm.desktop

if [ ! -s /usr/local/bin/mlwm ]; then
    echo "mlwm bootstrap: /usr/local/bin/mlwm is empty after install (check disk space with df -h)." >&2
    exit 1
fi

if [ -f "$TARGET_HOME/.xinitrc" ] && ! grep -q "exec mlwm" "$TARGET_HOME/.xinitrc"; then
    cp "$TARGET_HOME/.xinitrc" "$TARGET_HOME/.xinitrc.bak"
    echo "    (backed up existing $TARGET_HOME/.xinitrc to $TARGET_HOME/.xinitrc.bak)"
fi
install -Dm644 "$WORK_DIR/packaging/arch/xinitrc" "$TARGET_HOME/.xinitrc"
if [ "$(id -u)" -eq 0 ] && [ "$CURRENT_USER" != "root" ]; then
    chown "$CURRENT_USER:$CURRENT_USER" "$TARGET_HOME/.xinitrc"
fi

# Flush Btrfs delayed-allocation extents so an immediate VM reboot/close never leaves 0-byte files.
sync

echo ""
echo "==> mlwm installed successfully!"
echo "    Binary:   /usr/local/bin/mlwm ($(wc -c < /usr/local/bin/mlwm) bytes)"
echo "    Xinitrc:  $TARGET_HOME/.xinitrc"
echo "    Source:   $WORK_DIR (edit config/config.ml and re-run ./bootstrap.sh to rebuild)"
echo ""
echo "Log in on a virtual console (TTY1) and run:"
echo "    startx"
