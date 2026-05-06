#!/bin/sh
set -e

REPO="alexdesousa/planck"
RELEASES="https://github.com/$REPO/releases/latest/download"
BIN_NAME="planck"

# ── Detect OS ────────────────────────────────────────────────────────────────
os="$(uname -s)"
case "$os" in
  Linux)  platform="linux"  ;;
  Darwin) platform="macos"  ;;
  *)
    echo "Unsupported OS: $os"
    echo "Download manually from https://github.com/$REPO/releases"
    exit 1
    ;;
esac

# ── Detect architecture ───────────────────────────────────────────────────────
arch="$(uname -m)"
case "$arch" in
  x86_64)          suffix="" ;;
  amd64)           suffix="" ;;
  aarch64|arm64)   suffix="_arm" ;;
  *)
    echo "Unsupported architecture: $arch"
    echo "Download manually from https://github.com/$REPO/releases"
    exit 1
    ;;
esac

asset="${BIN_NAME}_${platform}${suffix}"
url="$RELEASES/$asset"

# ── Pick install directory ────────────────────────────────────────────────────
if [ -w /usr/local/bin ]; then
  install_dir="/usr/local/bin"
elif [ -w "$HOME/.local/bin" ]; then
  install_dir="$HOME/.local/bin"
else
  install_dir="$HOME/.local/bin"
  mkdir -p "$install_dir"
fi

dest="$install_dir/$BIN_NAME"

# ── Download ──────────────────────────────────────────────────────────────────
echo "Downloading $asset..."

if command -v curl > /dev/null 2>&1; then
  curl -fsSL "$url" -o "$dest"
elif command -v wget > /dev/null 2>&1; then
  wget -qO "$dest" "$url"
else
  echo "Neither curl nor wget found. Please install one and retry."
  exit 1
fi

chmod +x "$dest"

# ── Done ──────────────────────────────────────────────────────────────────────
echo "Installed planck to $dest"

if ! echo "$PATH" | grep -q "$install_dir"; then
  echo ""
  echo "Add $install_dir to your PATH:"
  echo "  export PATH=\"\$PATH:$install_dir\""
fi
