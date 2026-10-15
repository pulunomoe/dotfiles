#!/usr/bin/env bash
#
# bootstrap.sh - reproduce this Arch setup on a fresh install.
#
#   ./install/bootstrap.sh [--skip-packages] [--skip-services] [--skip-dotfiles]
#
# It will:
#   1. full system upgrade + install every package in install/packages.txt
#   2. enable the systemd units in install/services-system.txt and
#      install/services-user.txt
#   3. symlink every top-level config in this repo into ~/.config and set
#      fish as the login shell
#   4. apply the PHP configuration (install/php.sh)
#
# Run it as your normal user (it calls sudo when it needs root), not as root.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"

PKG_FILE="$SCRIPT_DIR/packages.txt"
SYSTEM_SERVICES_FILE="$SCRIPT_DIR/services-system.txt"
USER_SERVICES_FILE="$SCRIPT_DIR/services-user.txt"

# Top-level names in the repo that are NOT configs to deploy into ~/.config.
# (Everything else in the repo root is treated as a ~/.config/<name> entry.)
EXCLUDE=(install)

DO_PACKAGES=1
DO_SERVICES=1
DO_DOTFILES=1
DO_PHP=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [options]

Options:
  --skip-packages    don't install the package list
  --skip-services    don't enable systemd services
  --skip-dotfiles    don't symlink configs or change the shell
  --skip-php         don't apply the PHP configuration
  -h, --help         show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-packages) DO_PACKAGES=0 ;;
    --skip-services) DO_SERVICES=0 ;;
    --skip-dotfiles) DO_DOTFILES=0 ;;
    --skip-php) DO_PHP=0 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# Read a list file, dropping comments and blank lines.
read_list() { grep -vE '^[[:space:]]*(#|$)' "$1" || true; }

check_environment() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    warn "run this as your normal user, not root (it uses sudo internally)"
    exit 1
  fi
  if ! command -v pacman >/dev/null 2>&1; then
    warn "pacman not found - this script targets Arch Linux"
    exit 1
  fi
  command -v sudo >/dev/null 2>&1 || { warn "sudo is not installed"; exit 1; }
  sudo -v
}

install_packages() {
  log "Installing packages from $(basename "$PKG_FILE")"
  mapfile -t pkgs < <(read_list "$PKG_FILE")
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    warn "no packages listed in $PKG_FILE"
    return
  fi
  echo "  ${#pkgs[@]} packages"
  sudo pacman -Syu --needed --noconfirm "${pkgs[@]}"
  ok "packages installed"
}

enable_system_services() {
  log "Enabling system services"
  local svc
  while read -r svc; do
    [[ -n "$svc" ]] || continue
    sudo systemctl enable "$svc"
  done < <(read_list "$SYSTEM_SERVICES_FILE")
  ok "system services enabled"
}

enable_user_services() {
  log "Enabling user services"
  local svc
  while read -r svc; do
    [[ -n "$svc" ]] || continue
    if systemctl --user enable "$svc" >/dev/null 2>&1; then
      ok "$svc"
    else
      warn "could not enable $svc (no user session running?)"
    fi
  done < <(read_list "$USER_SERVICES_FILE")
}

deploy_dotfiles() {
  log "Linking configs into $CONFIG_DIR"
  mkdir -p "$CONFIG_DIR"
  local ts entry name target skip
  ts="$(date +%Y%m%d-%H%M%S)"
  shopt -s nullglob
  for entry in "$DOTFILES_DIR"/*; do
    name="$(basename "$entry")"

    skip=0
    for x in "${EXCLUDE[@]}"; do
      [[ "$name" == "$x" ]] && skip=1
    done
    [[ $skip -eq 1 ]] && continue

    target="$CONFIG_DIR/$name"
    if [[ -L "$target" ]]; then
      ln -sfn "$entry" "$target"
      ok "relinked $name"
    elif [[ -e "$target" ]]; then
      mv "$target" "$target.bak.$ts"
      ln -sfn "$entry" "$target"
      ok "backed up existing $name -> ${name}.bak.$ts and linked"
    else
      ln -sfn "$entry" "$target"
      ok "linked $name"
    fi
  done
  shopt -u nullglob
}

setup_shell() {
  log "Setting default shell"
  local fish_bin
  fish_bin="$(command -v fish || true)"
  if [[ -z "$fish_bin" ]]; then
    warn "fish is not installed; skipping"
    return
  fi
  if [[ "$SHELL" == "$fish_bin" ]]; then
    ok "already using $fish_bin"
    return
  fi
  if grep -qx "$fish_bin" /etc/shells; then
    chsh -s "$fish_bin"
    ok "login shell set to $fish_bin"
  else
    warn "$fish_bin is not in /etc/shells; run: echo $fish_bin | sudo tee -a /etc/shells && chsh -s $fish_bin"
  fi
}

configure_php() {
  log "Configuring PHP"
  "$SCRIPT_DIR/php.sh"
}

print_followups() {
  cat <<EOF

$(log "Manual steps this script does not cover")
  - timezone:   sudo ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime && sudo hwclock --systohc
  - locale:     uncomment en_US.UTF-8 in /etc/locale.gen && sudo locale-gen
  - hostname:   echo screemkii | sudo tee /etc/hostname
  - multilib:   uncomment the [multilib] section in /etc/pacman.conf
  - zram (zram-generator.conf):
        [zram0]
        compression-algorithm = zstd
  - regenerate initramfs: sudo mkinitcpio -P
  - bootloader:  sudo bootctl install   (and create /boot/loader/entries/*)
  - mirrors:     sudo systemctl enable --now reflector.timer
  - reboot
EOF
}

main() {
  check_environment
  log "Bootstrapping from $DOTFILES_DIR"
  (( DO_PACKAGES ))  && install_packages
  if (( DO_SERVICES )); then
    enable_system_services
    enable_user_services
  fi
  if (( DO_DOTFILES )); then
    deploy_dotfiles
    setup_shell
  fi
  (( DO_PHP )) && configure_php
  print_followups
  log "Done."
}

main
