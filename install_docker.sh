#!/bin/bash
set -euo pipefail

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
trap 'die "failed at line $LINENO"' ERR

ARCH="$(dpkg --print-architecture || echo unknown)"        # amd64, arm64, ...
OS_CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" || true)"
TARGET_USER="${SUDO_USER:-${USER}}"

# --- Non-interactive + quieter apt/dpkg/needrestart ---
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a            # auto-restart services
export NEEDRESTART_SUSPEND=1         # silence needrestart scan output
APT_OPTS=(-y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")
PHASE_OPTS=(-o APT::Get::Always-Include-Phased-Updates=true)  # avoid “deferred due to phasing”

# --- Helpers ---
have_url() { curl -fsSL --retry 3 --max-time 10 -o /dev/null "$1"; }
choose_repo_codename() {
  local c
  for c in "${OS_CODENAME:-}" noble jammy focal; do
    [[ -n "$c" ]] || continue
    have_url "https://download.docker.com/linux/ubuntu/dists/${c}/Release" && { echo "$c"; return; }
  done
  die "No suitable Docker repo codename found."
}

remove_if_installed() {
  local p="$1"
  if dpkg -s "$p" >/dev/null 2>&1; then
    log "Removing conflicting package: $p"
    sudo apt-get remove "${APT_OPTS[@]}" "$p"
  else
    log "Not installed (skipping): $p"
  fi
}

log "Installing prerequisites..."
sudo apt-get update -y -q
sudo apt-get install "${APT_OPTS[@]}" ca-certificates curl gnupg lsb-release >/dev/null

log "Removing conflicting distro packages (if any)..."
for p in docker.io docker-doc docker-compose podman-docker moby-engine moby-cli containerd runc; do
  remove_if_installed "$p"
done

log "Configuring Docker APT repository..."
sudo install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
fi

CODENAME="$(choose_repo_codename)"
log "Using Docker repo codename: ${CODENAME}"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

log "Updating APT cache for Docker repo..."
sudo apt-get update -y -q

log "Installing Docker Engine and plugins..."
sudo apt-get install "${APT_OPTS[@]}" "${PHASE_OPTS[@]}" \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Enabling and starting Docker service..."
sudo systemctl enable --now docker

# ensure docker group exists (package usually creates it)
getent group docker >/dev/null || sudo groupadd docker || true

if [[ "${TARGET_USER}" != "root" ]]; then
  if id -nG "${TARGET_USER}" | grep -qw docker; then
    log "User '${TARGET_USER}' already in 'docker' group."
  else
    log "Adding '${TARGET_USER}' to 'docker' group..."
    sudo usermod -aG docker "${TARGET_USER}" || warn "Could not add user to docker group."
  fi
fi

# quick sanity (won’t break script if PATH/group not updated yet)
log "Docker versions:"
docker --version || warn "docker CLI not yet in current shell PATH."
docker compose version || warn "compose plugin not yet visible in current shell."

log "Docker installation complete."
log "Tip: run 'newgrp docker' or re-login to use docker without sudo."
