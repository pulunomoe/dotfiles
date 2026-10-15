#!/usr/bin/env bash
#
# php.sh - apply the PHP configuration used on this machine, idempotently.
#
# The changes live in /etc/php/php.ini (core directives + enabled extensions)
# and /etc/php/conf.d/*.ini (third-party extensions). This reproduces those
# edits on a fresh install without shipping a whole version-specific php.ini.
#
# Run standalone or via install/bootstrap.sh.
#
set -euo pipefail

PHP_INI="${PHP_INI:-/etc/php/php.ini}"
CONF_D="${CONF_D:-/etc/php/conf.d}"

# core directives to enforce: key => value
declare -A DIRECTIVES=(
  [error_reporting]="E_ALL"
  [display_errors]="On"
  [display_startup_errors]="On"
  [post_max_size]="128M"
  [upload_max_filesize]="100M"
  [date.timezone]="Asia/Jakarta"
)

# extensions enabled in php.ini (packages that provide them are in packages.txt)
PHP_EXTENSIONS=(gd iconv pdo_pgsql pdo_sqlite sodium sqlite3)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  SUDO=""
else
  SUDO="${SUDO-sudo}"
fi
sudo_run() { if [[ -n "$SUDO" ]]; then "$SUDO" "$@"; else "$@"; fi; }

# Rewrite "key = value" in php.ini (commented or active), or append if absent.
set_directive() {
  local key="$1" value="$2" re
  re="^[[:space:]]*;?[[:space:]]*${key}[[:space:]]*=.*"
  if grep -qE "$re" "$PHP_INI"; then
    sudo_run sed -i -E "s|$re|${key} = ${value}|" "$PHP_INI"
  else
    printf '%s = %s\n' "$key" "$value" | sudo_run tee -a "$PHP_INI" >/dev/null
  fi
}

# Uncomment ";extension=<ext>" in php.ini.
enable_php_extension() {
  local ext="$1" re
  re="^[[:space:]]*;?[[:space:]]*extension[[:space:]]*=[[:space:]]*${ext}[[:space:]]*$"
  if grep -qE "$re" "$PHP_INI"; then
    sudo_run sed -i -E "s|$re|extension=${ext}|" "$PHP_INI"
  else
    warn "php.ini has no 'extension=${ext}' line (is its package installed?)"
  fi
}

# Rewrite a directive inside a conf.d file.
set_conf_directive() {
  local file="$1" pattern="$2" replacement="$3"
  [[ -f "$file" ]] || { warn "$file is missing"; return 0; }
  if grep -qE "$pattern" "$file"; then
    sudo_run sed -i -E "s|$pattern|$replacement|" "$file"
  fi
}

apply() {
  if [[ ! -f "$PHP_INI" ]]; then
    warn "$PHP_INI not found; is php installed?"
    return 1
  fi

  log "Configuring $PHP_INI"
  local key
  for key in "${!DIRECTIVES[@]}"; do
    set_directive "$key" "${DIRECTIVES[$key]}"
    ok "$key = ${DIRECTIVES[$key]}"
  done

  local ext
  for ext in "${PHP_EXTENSIONS[@]}"; do
    enable_php_extension "$ext"
    ok "extension=$ext"
  done

  log "Configuring extensions in $CONF_D"
  set_conf_directive "$CONF_D/igbinary.ini" \
    '^[[:space:]]*;?[[:space:]]*extension[[:space:]]*=[[:space:]]*igbinary\.so[[:space:]]*$' \
    'extension=igbinary.so'
  set_conf_directive "$CONF_D/imagick.ini" \
    '^[[:space:]]*;?[[:space:]]*extension[[:space:]]*=[[:space:]]*imagick[[:space:]]*$' \
    'extension = imagick'
  set_conf_directive "$CONF_D/xdebug.ini" \
    '^[[:space:]]*;?[[:space:]]*zend_extension[[:space:]]*=[[:space:]]*xdebug\.so[[:space:]]*$' \
    'zend_extension=xdebug.so'
  set_conf_directive "$CONF_D/xdebug.ini" \
    '^[[:space:]]*;?[[:space:]]*xdebug\.mode[[:space:]]*=.*' \
    'xdebug.mode=debug,coverage'
  ok "igbinary, imagick, xdebug enabled"
}

apply
log "Done."
