#!/usr/bin/env bash
# hermes-vm - run Hermes Agent in an isolated, hardened VMware Fusion VM on an Apple Silicon Mac.
#
#   ./hermes-vm.sh            does whatever is next: set up, continue an unfinished setup, or start the VMs
#   ./hermes-vm.sh help       all commands
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=lib/preflight.sh
. "$REPO/lib/preflight.sh"
# shellcheck source=lib/configure.sh
. "$REPO/lib/configure.sh"
# shellcheck source=lib/host.sh
. "$REPO/lib/host.sh"
# shellcheck source=lib/build.sh
. "$REPO/lib/build.sh"
# shellcheck source=lib/manage.sh
. "$REPO/lib/manage.sh"
# shellcheck source=lib/lockdown.sh
. "$REPO/lib/lockdown.sh"
# shellcheck source=lib/provision.sh
. "$REPO/lib/provision.sh"
# shellcheck source=lib/update.sh
. "$REPO/lib/update.sh"

# If anything fails unexpectedly, say where instead of exiting silently.
# Only the main shell reports: a failure inside $(...) or a subshell is handled (or reported) by the code that ran
# it, e.g. an SSH attempt inside a retry loop.
trap 'rc=$?; if [ "${BASH_SUBSHELL:-0}" -eq 0 ]; then printf "\n%s✗ Stopped unexpectedly (exit %s) at %s line %s: %s%s\n" "$RED" "$rc" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" "$X" >&2; printf "    Fix the cause and re-run the same command; every step is safe to repeat.\n" >&2; fi' ERR

usage() {
  cat <<EOF
${B}hermes-vm${X} - Hermes Agent in an isolated, hardened VM on your Mac

${B}Just run it${X}
  ./hermes-vm.sh               Works out where things are and does what's next: first-time questions,
                               then each stage below, picking up after any failure. Once everything is
                               set up, it simply starts both VMs headless.

${B}Stages${X} (each one re-runnable on its own)
  preflight      Check macOS, VMware Fusion and Homebrew; offer to install Packer, Caddy, OpenSSL, GnuPG
  configure      Answer the questions (saved to ~/.config/hermes-vm; password goes to your Keychain)
  build          1. Base install: verify Ubuntu, install it in both VMs with Packer (no sudo)
  provision      2. Harden, Docker, Hermes: separate steps over SSH, resumed from the step that failed
  lockdown       3. Put Hermes behind the router VM: private network, router firewall, Mac firewall,
                 Ollama gateway, Hermes firewall, snapshots, then verify (needs sudo)
  host           Re-apply only the Mac side of lockdown (networks, firewall, gateway)
  post-build [hermes|router]
                 Accept an install Packer marked failed after a successful 'r' retry

${B}Day to day${X}
  start | stop | status   (start brings the router up before Hermes, then asks which model to use:
                           Enter keeps the current one; HERMES_VM_MODEL=<name> skips the question)
  model [NAME]   Switch Hermes's Ollama model while it runs (no NAME: pick from 'ollama list')
  update [TAG]   Update the Hermes image in the VM (backs up its data first; switches back if it fails)
  update --rollback   Go back to the image used before the last update
  ssh            SSH into Hermes as the admin user (through the router)
  ssh-router     SSH into the router VM
  setup-hermes   First run of Hermes (setup wizard), then start it
  verify         Isolation tests from inside Hermes (its own firewall on, then off)
  logs           Tail the Ollama gateway log on the Mac

${B}Removal${X}
  uninstall      Remove the host pieces (asks before deleting the VM, key or Keychain entry)
EOF
}

_stage_text() {
  case "$1" in
    none) echo "not built" ;;
    installed) echo "installed, not finished" ;;
    base) echo "base install done" ;;
    provisioned) echo "provisioned" ;;
    locked) echo "locked down" ;;
  esac
}

# The default command: work out each VM's stage and carry on from there.
cmd_install() {
  if [ ! -f "$CONFIG_FILE" ]; then
    cmd_preflight
    cmd_configure
  elif ! (load_config) >/dev/null 2>&1; then
    cmd_preflight_quiet
    cmd_configure
  else
    cmd_preflight_quiet
  fi
  load_config

  local h r role
  h=$(vm_stage hermes); r=$(vm_stage router)
  if [ "$h" = locked ] && [ "$r" = locked ]; then
    cmd_start
    say "Ready"
    cat <<EOF
    ./hermes-vm.sh ssh            a shell in Hermes          ./hermes-vm.sh stop     shut both VMs down
    ./hermes-vm.sh setup-hermes   Hermes's setup wizard      ./hermes-vm.sh verify   re-run the isolation tests
EOF
    return 0
  fi

  say "Where things are"
  info "Hermes: $(_stage_text "$h")      Router: $(_stage_text "$r")"

  for role in hermes router; do
    if [ "$(vm_stage "$role")" = installed ]; then
      warn "Packer didn't finish $(vm_name_of "$role") cleanly last time."
      if no_default "Use it as it is? (No deletes it and installs it again)"; then
        _post_build "$role"
      else
        vm_running "$role" && "$VMRUN" -T fusion stop "$(vmx_path "$role")" hard >/dev/null 2>&1 || true
        "$VMRUN" -T fusion deleteVM "$(vmx_path "$role")" >/dev/null 2>&1 || true
        rm -rf "$(vm_dir_of "$role")"
      fi
    fi
  done
  if [ "$(vm_stage hermes)" = none ] || [ "$(vm_stage router)" = none ]; then cmd_build --missing; fi
  cmd_provision
  cmd_lockdown
  say "All done"
  cat <<EOF
    Hermes and its router are built, isolated and verified. Next time, ./hermes-vm.sh just starts them.
      ./hermes-vm.sh setup-hermes   run Hermes's setup wizard and start it
EOF
}

case "${1:-install}" in
  install)       cmd_install ;;
  preflight)     cmd_preflight ;;
  configure)     cmd_preflight_quiet; cmd_configure ;;
  host)          cmd_host ;;
  build)         cmd_build ;;
  provision)     shift; cmd_provision "$@" ;;
  lockdown)      cmd_lockdown ;;
  post-build)    cmd_post_build "${2:-hermes}" ;;
  start)         cmd_start ;;
  stop)          cmd_stop ;;
  status)        cmd_status ;;
  model)         cmd_model "${2:-}" ;;
  update)        cmd_update "${2:-}" ;;
  ssh)           shift; cmd_ssh "$@" ;;
  ssh-router)    shift; cmd_ssh_router "$@" ;;
  setup-hermes)  cmd_setup_hermes ;;
  verify)        cmd_verify ;;
  logs)          cmd_logs ;;
  uninstall)     cmd_uninstall ;;
  help|-h|--help) usage ;;
  *)             usage; exit 1 ;;
esac
