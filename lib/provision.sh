# shellcheck shell=bash
# provision: stage 2 of 4. Turns the base Ubuntu install into a hardened Hermes VM (or router VM), one step at a
# time, over SSH from the Mac. Each finished step leaves a marker inside the VM, so a re-run picks up at the step
# that failed instead of starting again, and a failed step can be retried on the spot.
#
#   base (Packer) -> provision (this) -> lockdown -> run
#
# Markers live in the VM itself (/var/lib/hermes-vm/provision), so reverting a snapshot reverts them too.

PROVISION_STATE=/var/lib/hermes-vm/provision
PROVISION_DIR=/var/tmp/hermes-provision

_provision_steps() { # _provision_steps ROLE
  if [ "$1" = router ]; then
    echo "10-base 20-harden reboot 90-finalise"
  else
    echo "10-base 20-harden reboot 40-docker-rootless 50-hermes 90-finalise"
  fi
}

_step_label() {
  case "$1" in
    10-base) echo "updates and base packages" ;;
    20-harden) echo "hardening (kernel, SSH, sudo, audit, AppArmor, auto-updates)" ;;
    reboot) echo "reboot onto the hardened kernel settings" ;;
    40-docker-rootless) echo "rootless Docker for the 'hermes' user" ;;
    50-hermes) echo "Hermes image (digest-pinned) and its config" ;;
    90-finalise) echo "finalise (cloud-init off, cleanup, Lynis baseline)" ;;
    *) echo "$1" ;;
  esac
}

_provision_env() { # environment for the guest scripts, as a string for the VM's shell
  printf 'ADMIN_USER=%q VM_GW=%q LLM_PORT=%q LLM_MODEL=%q HERMES_TAG=%q DNS_SERVERS=%q MEMORY_GB=%q CPUS=%q' \
    "$ADMIN_USER" "$VM_GW" "$LLM_PORT" "$LLM_MODEL" "$HERMES_TAG" "$DNS_SERVERS" "$MEMORY_GB" "$CPUS"
}

_upload_provision_files() { # _upload_provision_files ROLE
  local flag="" tmp
  [ "$1" = router ] && flag=--router
  tmp=$(mktemp -d)
  mkdir -p "$tmp/files" "$tmp/scripts"
  cp -R "$REPO/guest/files/." "$tmp/files/"
  cp "$REPO"/guest/scripts/*.sh "$tmp/scripts/"
  (cd "$tmp" && COPYFILE_DISABLE=1 tar --no-xattrs -czf bundle.tgz files scripts)
  vm_scp $flag "$tmp/bundle.tgz" /var/tmp/hermes-provision.tgz
  rm -rf "$tmp"
  # The scripts read their config files from /var/tmp/hermes-files (/var/tmp survives the reboot; /tmp is tmpfs).
  vm_ssh $flag -o BatchMode=yes "rm -rf $PROVISION_DIR && mkdir -p $PROVISION_DIR && tar -xzf /var/tmp/hermes-provision.tgz -C $PROVISION_DIR && rm -f /var/tmp/hermes-provision.tgz && rm -rf /var/tmp/hermes-files && cp -R $PROVISION_DIR/files /var/tmp/hermes-files"
}

_steps_done() { # _steps_done ROLE -> names of finished steps
  local flag=""
  [ "$1" = router ] && flag=--router
  vm_ssh $flag -o BatchMode=yes "ls $PROVISION_STATE 2>/dev/null || true" 2>/dev/null || true
}

_run_step() { # _run_step ROLE STEP
  local role=$1 step=$2 flag=""
  [ "$role" = router ] && flag=--router
  if [ "$step" = reboot ]; then
    vm_sudo $flag "systemctl reboot" >/dev/null 2>&1 || true   # the connection drops: expected
    sleep 20
    vm_wait_ssh "$role" || return 1
    vm_sudo $flag "mkdir -p $PROVISION_STATE && touch $PROVISION_STATE/reboot"
    return
  fi
  vm_sudo $flag "cd /var/tmp && env $(_provision_env) bash -euo pipefail $PROVISION_DIR/scripts/$step.sh && mkdir -p $PROVISION_STATE && touch $PROVISION_STATE/$step"
}

# _provision_vm ROLE [background] : run the steps that aren't done yet. Foreground: on failure, offer a retry.
# Background (the router, while Hermes runs in the foreground): retry twice by itself, then give up.
_provision_vm() {
  local role=$1 mode=${2:-foreground} done_steps step n=0 total attempt
  total=$(_provision_steps "$role" | wc -w | tr -d ' ')
  _start_one "$role"
  info "Waiting for SSH on $(vm_name_of "$role")"
  vm_wait_ssh "$role" || { vm_no_ip_help "$role"; die "Can't reach $(vm_name_of "$role") over SSH"; }
  _upload_provision_files "$role"
  done_steps=" $(_steps_done "$role" | tr '\n' ' ') "
  for step in $(_provision_steps "$role"); do
    n=$((n + 1))
    case "$done_steps" in *" $step "*) ok "[$n/$total] $(_step_label "$step") - already done"; continue ;; esac
    say "$(vm_name_of "$role") [$n/$total] $(_step_label "$step")"
    attempt=1
    until _run_step "$role" "$step"; do
      if [ "$mode" = background ]; then
        [ "$attempt" -ge 3 ] && return 1
        warn "Step $step failed (attempt $attempt); retrying in 30 seconds"
        sleep 30; attempt=$((attempt + 1))
        vm_wait_ssh "$role" || return 1
        continue
      fi
      warn "Step '$step' on $(vm_name_of "$role") failed (details above)."
      yes_default "Retry this step now?" \
        || die "Stopped at '$step'. Re-run ./hermes-vm.sh to continue from this step (finished steps are skipped)."
      vm_wait_ssh "$role" || die "Can't reach $(vm_name_of "$role") over SSH"
    done
  done

  # Hardening report, then a powered-off snapshot of the finished VM.
  local flag=""
  [ "$role" = router ] && flag=--router
  # shellcheck disable=SC2086
  vm_ssh $flag -o BatchMode=yes "cat /home/$ADMIN_USER/lynis-baseline.txt" \
    > "$BUILD_DIR/lynis-baseline-$role.txt" 2>/dev/null || true
  # shellcheck disable=SC2086
  vm_ssh $flag -o BatchMode=yes "rm -rf $PROVISION_DIR" >/dev/null 2>&1 || true
  vm_stop "$role"
  local waited=0
  while vm_running "$role" && [ "$waited" -lt 120 ]; do sleep 3; waited=$((waited + 3)); done
  _snapshot "$role" provisioned
  if [ -s "$BUILD_DIR/lynis-baseline-$role.txt" ]; then
    cp "$BUILD_DIR/lynis-baseline-$role.txt" "$(vm_dir_of "$role")/lynis-baseline.txt"
    ok "$(vm_name_of "$role") provisioned; snapshot 'provisioned'. Hardening index: $(grep -m1 'Hardening index' "$BUILD_DIR/lynis-baseline-$role.txt" | sed 's/^[^:]*: *//')"
  else
    ok "$(vm_name_of "$role") provisioned; snapshot 'provisioned'"
  fi
}

cmd_provision() { # cmd_provision [hermes|router]... (default: whichever need it)
  load_config
  export_config
  mkdir -p "$BUILD_DIR"
  ensure_agent_key
  local roles="${*:-}" role rpid="" todo=""
  if [ -z "$roles" ]; then
    for role in hermes router; do
      [ "$(vm_stage "$role")" = base ] && todo="$todo $role"
    done
  else
    todo=$roles
  fi
  [ -n "$todo" ] || { ok "Nothing to provision"; return 0; }
  for role in $todo; do vm_exists "$role" || die "No $(vm_name_of "$role") yet. Run: ./hermes-vm.sh build"; done
  SUDO_PW=$(keychain_get "$ADMIN_USER") || die "Couldn't read the admin password from the Keychain"

  say "Provisioning"
  info "Each step is recorded inside the VM: if one fails you can retry it, or re-run ./hermes-vm.sh later"
  info "and it continues from that step."

  case " $todo " in
    *" hermes "*" router "*|*" router "*" hermes "*)
      info "The router provisions alongside Hermes; its log is $BUILD_DIR/router-provision.log"
      ( trap - ERR; _provision_vm router background ) > "$BUILD_DIR/router-provision.log" 2>&1 &
      rpid=$!
      _provision_vm hermes || { kill "$rpid" 2>/dev/null || true; SUDO_PW=""; return 1; }
      if kill -0 "$rpid" 2>/dev/null; then
        say "Waiting for the router to finish provisioning"
        while kill -0 "$rpid" 2>/dev/null; do
          info "router: $(_last_log_line "$BUILD_DIR/router-provision.log")"
          sleep 30
        done
      fi
      if wait "$rpid"; then
        ok "Router provisioned ($BUILD_DIR/router-provision.log)"
      else
        warn "Router provisioning stopped. The end of its log:"
        sed -e 's/\x1b\[[0-9;]*m//g' "$BUILD_DIR/router-provision.log" | tail -25 | sed 's/^/      /' >&2
        SUDO_PW=""
        die "Re-run ./hermes-vm.sh to continue the router from where it stopped (Hermes is done)."
      fi
      ;;
    *)
      for role in $todo; do _provision_vm "$role"; done
      ;;
  esac
  SUDO_PW=""
}
