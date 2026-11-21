# shellcheck shell=bash
# preflight: make sure the Mac can run the build, and offer to install what's missing.

BREW_PACKAGES="hashicorp/tap/packer openssl@3 caddy gnupg"

_preflight_checks() {
  local quiet=${1:-}
  [ "$(uname -s)" = "Darwin" ] || die "hermes-vm runs on macOS."
  [ "$(uname -m)" = "arm64" ] || die "hermes-vm targets Apple Silicon (arm64) Macs."
  [ -x "$VMRUN" ] || die "VMware Fusion not found at $FUSION_APP. Install it (free for personal use) and run this again."
  [ -n "$quiet" ] || ok "macOS on Apple Silicon, VMware Fusion installed"

  command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"

  local missing="" pkg name
  for pkg in $BREW_PACKAGES; do
    name=${pkg##*/}
    case "$name" in
      openssl@3) brew --prefix openssl@3 >/dev/null 2>&1 && [ -x "$(brew --prefix openssl@3)/bin/openssl" ] || missing="$missing $pkg" ;;
      gnupg)     command -v gpg >/dev/null || missing="$missing $pkg" ;;
      *)         command -v "$name" >/dev/null || missing="$missing $pkg" ;;
    esac
  done
  if [ -n "$missing" ]; then
    warn "Missing tools:$missing"
    if yes_default "Install them with Homebrew now?"; then
      case "$missing" in *hashicorp/tap/*) brew tap hashicorp/tap ;; esac
      # shellcheck disable=SC2086
      brew install $missing
    else
      die "Install them, then run this again: brew install$missing"
    fi
  fi
  [ -n "$quiet" ] || ok "Packer, Caddy, OpenSSL 3 and GnuPG available"

  if ! command -v ollama >/dev/null; then
    warn "Ollama isn't installed. Hermes in the VM uses your Mac's Ollama for its model: https://ollama.com/download"
  else
    [ -n "$quiet" ] || ok "Ollama installed"
  fi
}

cmd_preflight()       { say "Preflight checks"; _preflight_checks; }
cmd_preflight_quiet() { _preflight_checks quiet; }
