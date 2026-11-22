# shellcheck shell=bash
# update.sh - update the Hermes container image inside the VM, with a data backup and a way back.
#   hermes-vm update [TAG]        check for a newer image of TAG (default: the configured tag) and switch to it
#   hermes-vm update --rollback   go back to the image used before the last update (optionally restoring its data)
#
# The image stays pinned by digest in ~/hermes/compose.yaml, as the build pins it. Each update appends a line to
# /var/lib/hermes-vm/image-history: "<UTC time> <previous image@digest> <data backup path>".

# Runs as root in the Hermes VM through vm_sudo. Printed by a function rather than held in VAR=$(cat <<...),
# because macOS bash 3.2 mis-parses 'case' inside $(...).
_hermes_update_script() {
  cat <<'EOS'
set -u
REPO=nousresearch/hermes-agent
HOME_DIR=/home/hermes/hermes
BACKUPS=/var/backups/hermes-vm
HISTORY=/var/lib/hermes-vm/image-history
KEEP=3
u=$(id -u hermes)
run() { sudo -u hermes env XDG_RUNTIME_DIR=/run/user/$u DOCKER_HOST=unix:///run/user/$u/docker.sock "$@"; }
cd "$HOME_DIR" || { echo "No $HOME_DIR" >&2; exit 1; }

current_image() { sed -n 's/^    image: *\(nousresearch\/hermes-agent@sha256:[0-9a-f]*\).*/\1/p' compose.yaml | head -1; }
# The image carries no version label, so ask it: a throwaway container with no network and no volume. Its hermes
# wrapper starts as root and drops to the hermes user, which needs SETUID and SETGID; every other capability is dropped.
version_of() {
  run docker run --rm --network none --cap-drop ALL --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges --entrypoint hermes "$1" --version 2>/dev/null |
    sed -n 's/^Hermes Agent \(v[^ ]*\)\( (\([^)]*\))\)\{0,1\}.*/\1 (\3)/p' | sed 's/ ()$//' | head -1
}
data_dir() { ls -d /home/hermes/.local/share/docker/volumes/*hermes-data/_data 2>/dev/null | head -1; }
pin() { sed -i "s#^\(    image: *\)nousresearch/hermes-agent@sha256:[0-9a-f]*#\1$1#" compose.yaml; }
healthy() {
  i=0
  while [ "$i" -lt 60 ]; do
    if [ -n "$(run docker compose ps -q --status running hermes 2>/dev/null)" ] &&
       run docker compose exec -T hermes hermes config get model.default >/dev/null 2>&1; then return 0; fi
    i=$((i + 1)); sleep 3
  done
  return 1
}
backup_data() {
  d=$(data_dir); [ -n "$d" ] || { echo "Couldn't find Hermes's data volume" >&2; return 1; }
  install -d -m 700 "$BACKUPS"
  need=$(du -sk "$d" | cut -f1); free=$(df -Pk "$BACKUPS" | awk 'NR==2 {print $4}')
  [ "$free" -gt $((need * 2)) ] || { echo "Not enough disk space for a backup (need ~${need} KB free x2, have ${free} KB)" >&2; return 1; }
  f="$BACKUPS/hermes-data-$(date -u +%Y%m%dT%H%M%SZ).tgz"
  tar --numeric-owner -czf "$f" -C "$d" . || return 1
  chmod 600 "$f"
  ls -1t "$BACKUPS"/hermes-data-*.tgz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
  echo "$f"
}

case "$ACTION" in
  check)
    cur=$(current_image)
    [ -n "$cur" ] || { echo "No pinned hermes-agent image in compose.yaml" >&2; exit 1; }
    ok=no
    for attempt in 1 2 3; do
      if run docker pull -q "$REPO:$TAG" >/dev/null 2>&1; then ok=yes; break; fi
      sleep $((attempt * 10))
    done
    [ "$ok" = yes ] || { echo "Couldn't pull $REPO:$TAG (network, Docker Hub, or the tag doesn't exist)" >&2; exit 1; }
    new=$(run docker image inspect --format '{{index .RepoDigests 0}}' "$REPO:$TAG")
    echo "CUR=$cur"
    echo "NEW=$new"
    echo "CURVER=$(version_of "$cur")"
    echo "NEWVER=$(version_of "$new")"
    ;;
  apply)
    cur=$(current_image)
    case "$NEW" in "$REPO"@sha256:*) ;; *) echo "Bad image reference: $NEW" >&2; exit 1 ;; esac
    run docker image inspect "$NEW" >/dev/null 2>&1 || { echo "$NEW isn't in the VM; run the check again" >&2; exit 1; }
    echo "Stopping Hermes for the backup"
    run docker compose stop hermes >/dev/null 2>&1 || true
    if ! f=$(backup_data); then
      run docker compose start hermes >/dev/null 2>&1 || true
      echo "Backup failed; nothing changed" >&2; exit 1
    fi
    echo "Data backed up to $f"
    cp -p compose.yaml compose.yaml.before-update
    pin "$NEW"
    install -d -m 755 /var/lib/hermes-vm
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $cur $f" >> "$HISTORY"
    echo "Starting Hermes on the new image"
    run docker compose up -d >/dev/null 2>&1
    if healthy; then
      echo "RESULT=updated"
    else
      echo "Hermes didn't come up healthy on the new image; switching back" >&2
      pin "$cur"
      run docker compose up -d >/dev/null 2>&1
      sed -i '$d' "$HISTORY"
      if healthy; then echo "RESULT=reverted"; else echo "RESULT=broken"; fi
      exit 1
    fi
    ;;
  rollback)
    [ -s "$HISTORY" ] || { echo "No previous image recorded; nothing to roll back to" >&2; exit 1; }
    last=$(tail -1 "$HISTORY"); prev=$(echo "$last" | awk '{print $2}'); f=$(echo "$last" | awk '{print $3}')
    run docker image inspect "$prev" >/dev/null 2>&1 || run docker pull -q "$prev" >/dev/null 2>&1 ||
      { echo "The previous image $prev isn't available any more" >&2; exit 1; }
    if [ "${RESTORE:-no}" = yes ]; then
      [ -f "$f" ] || { echo "Backup $f is missing; not restoring data" >&2; exit 1; }
      d=$(data_dir); [ -n "$d" ] || { echo "Couldn't find Hermes's data volume" >&2; exit 1; }
      run docker compose stop hermes >/dev/null 2>&1 || true
      find "$d" -mindepth 1 -delete && tar --numeric-owner -xzf "$f" -C "$d" || { echo "Restore failed" >&2; exit 1; }
      echo "Data restored from $f"
    fi
    pin "$prev"
    run docker compose up -d >/dev/null 2>&1
    sed -i '$d' "$HISTORY"
    if healthy; then echo "RESULT=rolledback"; else echo "RESULT=broken"; exit 1; fi
    ;;
  *) echo "Unknown action" >&2; exit 1 ;;
esac
EOS
}

_short() { printf '%s' "${1##*@sha256:}" | cut -c1-12; }

cmd_update() {
  load_config; _require_vm
  if ! vm_running hermes || ! vm_locked hermes; then die "Hermes isn't running. Start it first: ./hermes-vm.sh start"; fi

  if [ "${1:-}" = "--rollback" ]; then
    say "Roll back Hermes to the image used before the last update"
    local restore=no
    if no_default "Also restore Hermes's data (config, memory, sessions) from the backup taken before that update?
    Anything Hermes saved since then would be lost"; then restore=yes; fi
    local out
    out=$(vm_sudo "ACTION=rollback RESTORE=$restore; $(_hermes_update_script)" 2>&1) || {
      printf '%s\n' "$out" | sed 's/^/    /'
      die "Rollback didn't complete. Check: ./hermes-vm.sh ssh, then: sudo machinectl shell hermes@ and docker compose ps"
    }
    printf '%s\n' "$out" | grep -v '^RESULT=' | sed 's/^/    /' || true
    ok "Hermes is back on the previous image"
    return 0
  fi

  local tag=${1:-$HERMES_TAG} out cur new curver newver
  say "Checking for a newer Hermes image (nousresearch/hermes-agent:$tag)"
  info "Pulling inside the VM; this can take a few minutes the first time."
  out=$(vm_sudo "ACTION=check TAG=$(printf '%q' "$tag"); $(_hermes_update_script)" 2>&1) || {
    printf '%s\n' "$out" | sed 's/^/    /'; die "Couldn't check for an update"; }
  cur=$(printf '%s\n' "$out" | sed -n 's/^CUR=//p')
  new=$(printf '%s\n' "$out" | sed -n 's/^NEW=//p')
  curver=$(printf '%s\n' "$out" | sed -n 's/^CURVER=//p')
  newver=$(printf '%s\n' "$out" | sed -n 's/^NEWVER=//p')
  [ -n "$cur" ] && [ -n "$new" ] || { printf '%s\n' "$out" | sed 's/^/    /'; die "Unexpected answer from the VM"; }

  if [ "$cur" = "$new" ]; then
    ok "Already up to date (${curver:-version unknown}, $(_short "$cur"))"
    return 0
  fi
  info "Current: ${curver:-version unknown}  ($(_short "$cur"))"
  info "New:     ${newver:-version unknown}  ($(_short "$new"))"
  info "Hermes stops for about a minute: its data is backed up first, then it starts on the new image."
  info "If it doesn't come up healthy, the script switches back to the current image by itself."
  yes_default "Update Hermes now?" || { info "Nothing changed."; return 0; }

  local rc=0
  out=$(vm_sudo "ACTION=apply NEW=$(printf '%q' "$new"); $(_hermes_update_script)" 2>&1) || rc=$?
  printf '%s\n' "$out" | grep -v '^RESULT=' | sed 's/^/    /' || true
  case "$(printf '%s\n' "$out" | sed -n 's/^RESULT=//p' || true)" in
    updated)
      ok "Hermes updated to ${newver:-$(_short "$new")}"
      info "Previous image kept for: ./hermes-vm.sh update --rollback"
      info "Start a fresh session in Discord (/new) to pick up any new behaviour."
      if [ "$tag" != "$HERMES_TAG" ]; then HERMES_TAG=$tag; save_config; fi
      ;;
    reverted) die "The new image didn't start cleanly, so Hermes is back on the previous one. Nothing else changed." ;;
    *) [ "$rc" -eq 0 ] || die "The update didn't complete and Hermes may not be running. Try: ./hermes-vm.sh update --rollback" ;;
  esac
}
