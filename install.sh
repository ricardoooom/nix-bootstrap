#!/usr/bin/env bash
set -e

REPO_URL="git@github.com:ricardoooom/nix-config.git"
TARGET_DIR="$HOME/.config/nix-config"

OP_AGE_KEY_PATH="op://Personal/Nix-Sops-Age-Key/password"

OP_BOOTSTRAP_PRIVATE_URI="op://Personal/SSH-github-ricardoooom-nix-bootstrap/private_key"
OP_BOOTSTRAP_PUBLIC_URI="op://Personal/SSH-github-ricardoooom-nix-bootstrap/public key"

BOOTSTRAP_KEY="$HOME/.ssh/id_github_ricardoooom_nix_bootstrap"
AGE_KEY_DEST="$HOME/.config/sops/age/keys.txt"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

OS="$(uname -s)"
ARCH="$(uname -m)"
log "Detected System: $OS ($ARCH)"
FLAKE_HOST="$ARCH-$OS"
log "Selecting flake: .#${FLAKE_HOST}"

# 1. Nix Installation
if ! command -v nix &> /dev/null; then
  log "Nix not found. Installing via Determinate Systems..."
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm

  if [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then
    . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
  else
    error "Could not find nix-daemon.sh. Installation might have failed."
  fi
else
  success "Nix is already installed."
fi

log "Checking native Rust toolchain..."
RUST_BIN_DIR="$HOME/.cargo/bin"
if [ -x "$RUST_BIN_DIR/rustc" ]; then
  success "Rust is already installed natively."
else
  log "Installing Rust natively (unattended, no PATH mutation)..."
  if curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path; then
    success "Rust installed successfully."
  else
    error "Rust installation failed. Check your network."
  fi
fi

mkdir -p "$(dirname "$AGE_KEY_DEST")"
mkdir -p ~/.ssh
CLEANUP_KEYS=false

# 2. 1Password & Keys Management
if command -v op &> /dev/null; then
  log "1Password detected. Processing keys..."
  
  if ! op account get &> /dev/null; then
    warn "Please sign in to 1Password."
    eval $(op signin)
  fi

  if [ ! -f "$AGE_KEY_DEST" ]; then
      log "Retrieving Age Key from 1Password..."
      op read "$OP_AGE_KEY_PATH" | grep -o "AGE-SECRET-KEY-1[A-Za-z0-9]*" > "$AGE_KEY_DEST"
      chmod 600 "$AGE_KEY_DEST"
      success "Age Key retrieved."
  fi

  if [ ! -f "$BOOTSTRAP_KEY" ]; then
      log "Retrieving temporary Bootstrap SSH Keys from 1Password..."
      op read "$OP_BOOTSTRAP_PRIVATE_URI" > "$BOOTSTRAP_KEY"
      chmod 600 "$BOOTSTRAP_KEY"
      op read "$OP_BOOTSTRAP_PUBLIC_URI" > "${BOOTSTRAP_KEY}.pub"
      chmod 644 "${BOOTSTRAP_KEY}.pub"
      
      CLEANUP_KEYS=true
      success "Bootstrap Keys retrieved (Temporary)."
  fi
else
  if [ ! -f "$AGE_KEY_DEST" ]; then
     warn "⚠️  Sops Age Key not found at $AGE_KEY_DEST"
     warn "Please upload keys.txt manually."
  fi
fi

if [ ! -f "$BOOTSTRAP_KEY" ]; then
  error "🛑 Bootstrap Key not found at: $BOOTSTRAP_KEY"
fi

log "Using Bootstrap Key for git operations."
export GIT_SSH_COMMAND="ssh -i $BOOTSTRAP_KEY -o IdentitiesOnly=yes"

if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
    log "Adding github.com to known_hosts..."
    ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null
fi

# 3. Git Repository Sync
if [ -d "$TARGET_DIR" ]; then
  log "Repository exists. Pulling latest..."
  cd "$TARGET_DIR"
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  git fetch origin "$current_branch"
  git reset --hard "origin/$current_branch"
else
  log "Cloning repository..."
  git clone "$REPO_URL" "$TARGET_DIR"
fi

# 4. Nix Configuration Application
log "Applying Nix configuration for: .#${FLAKE_HOST}"
cd "$TARGET_DIR"
git add .

if [ "$OS" == "Darwin" ]; then
  log "🍎 MacOS detected. Using nix-darwin to switch..."
  
  log "Step 1: Building system configuration..."
  nix build --extra-experimental-features "nix-command flakes" \
    ".#darwinConfigurations.${FLAKE_HOST}.system"
  log "Step 2: Activating system (No sudo password required)..."
  ./result/sw/bin/darwin-rebuild switch --flake ".#${FLAKE_HOST}"

elif [ "$OS" == "Linux" ]; then
  log "🐧 Linux detected. Using home-manager to switch..."

  nix run --extra-experimental-features "nix-command flakes" \
    home-manager -- switch --flake ".#${FLAKE_HOST}" -b backup
fi

# 5. Cleanup
if [ "$CLEANUP_KEYS" = true ]; then
    log "🧹 Cleaning up temporary Bootstrap Keys..."
    rm -f "$BOOTSTRAP_KEY" "${BOOTSTRAP_KEY}.pub"
    success "Temporary keys deleted."
else
    log "Skipping cleanup."
fi

success "🎉 Installation Complete! Please restart your shell."
