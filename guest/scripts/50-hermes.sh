#!/usr/bin/env bash
# 50-hermes.sh - stage Hermes for the 'hermes' user: pull the image, pin its digest, write compose + reference config.
# Hermes is NOT started here: first run needs the interactive setup wizard (README "First run").
set -euo pipefail
F=/var/tmp/hermes-files
log() { echo "==> [50-hermes] $*"; }
: "${VM_GW:?}" "${LLM_PORT:?}" "${LLM_MODEL:?}" "${HERMES_TAG:?}"

HUID="$(id -u hermes)"
as_hermes() {
  sudo -iu hermes env XDG_RUNTIME_DIR="/run/user/${HUID}" \
    DOCKER_HOST="unix:///run/user/${HUID}/docker.sock" "$@"
}

log "Pulling nousresearch/hermes-agent:${HERMES_TAG}"
# Retry: a brief network or Docker Hub hiccup (e.g. its token service) shouldn't fail a 20-minute build.
# Layers already downloaded are kept between attempts.
pulled=no
for attempt in 1 2 3 4 5; do
  if as_hermes docker pull "nousresearch/hermes-agent:${HERMES_TAG}"; then pulled=yes; break; fi
  log "Pull attempt $attempt failed; retrying in $((attempt * 15)) seconds"
  sleep $((attempt * 15))
done
[ "$pulled" = yes ] || { echo "ERROR: couldn't pull nousresearch/hermes-agent:${HERMES_TAG} after 5 attempts" >&2; exit 1; }
IMAGE_PINNED="$(as_hermes docker image inspect --format '{{index .RepoDigests 0}}' "nousresearch/hermes-agent:${HERMES_TAG}")"
log "Pinned to ${IMAGE_PINNED}"

log "Writing /home/hermes/hermes/"
install -d -o hermes -g hermes -m 0750 /home/hermes/hermes
MEM_GB="${MEMORY_GB:-4}"; CPU_N="${CPUS:-2}"
sed -e "s#@HERMES_IMAGE@#${IMAGE_PINNED}#" -e "s#@MEM_LIMIT@#$(( MEM_GB > 2 ? MEM_GB - 1 : 1 ))g#" \
    -e "s#@CPU_LIMIT@#${CPU_N}.0#" "$F/hermes/compose.yaml.tpl" > /home/hermes/hermes/compose.yaml
install -d -m 0755 /var/lib/hermes-vm
echo "${MEM_GB} ${CPU_N}" > /var/lib/hermes-vm/limits   # what the container limits were set for
sed -e "s#@VM_GW@#${VM_GW}#g" -e "s#@LLM_PORT@#${LLM_PORT}#g" -e "s#@LLM_MODEL@#${LLM_MODEL}#g" \
  "$F/hermes/config.yaml.tpl" > /home/hermes/hermes/config.reference.yaml
chown hermes:hermes /home/hermes/hermes/*
chmod 0640 /home/hermes/hermes/*

log "Validating compose file"
as_hermes bash -c 'cd ~/hermes && docker compose config --quiet'

log "Done"
