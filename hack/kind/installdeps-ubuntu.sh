#!/usr/bin/env bash

# installdeps-ubuntu.sh — Install dependencies and tune Ubuntu 24.04 (noble)
# for running the ScyllaDB Operator e2e suite on KinD with rootless podman.
#
# Run as a regular user with sudo access:
#   bash installdeps-ubuntu.sh
#
# What it does:
#   1. Installs system packages (podman, aardvark-dns, uidmap, slirp4netns, etc.)
#   2. Downloads Go, kind, kubectl, yq at pinned versions
#   3. Applies kernel / sysctl / PAM tuning required by ScyllaDB in KinD
#   4. Configures rootless podman and systemd linger

set -euo pipefail

# ---------------------------------------------------------------------------
# Versions — keep in sync with go.mod and the Jenkins pipeline
# ---------------------------------------------------------------------------
GO_VERSION="1.26.0"
KIND_VERSION="0.31.0"
KIND_SHA512="813e82cf7a82a034d099476e1b423bbdd7c32fb36c5209a0fa74c20c58d2676fc06509fd4bf6f0019e146c3b3e8b5ce85d26878ce336e8eeb3c66aa9e7efe35b"
KUBECTL_VERSION="1.33.3"
YQ_VERSION="4.44.3"
YQ_SHA256="a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7"

INSTALL_DIR="/usr/local/bin"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m>>> %s\033[0m\n' "$*"; }
error() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require_ubuntu_24() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect OS — /etc/os-release not found"
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]] || [[ "${VERSION_ID:-}" != "24.04" ]]; then
        error "This script targets Ubuntu 24.04 (noble). Detected: ${PRETTY_NAME:-unknown}"
    fi
}

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
install_packages() {
    info "Installing system packages"
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        git \
        make \
        curl \
        jq \
        util-linux \
        podman \
        aardvark-dns \
        uidmap \
        slirp4netns \
        crun \
        bsdextrautils
}

# ---------------------------------------------------------------------------
# 2. Go
# ---------------------------------------------------------------------------
install_go() {
    if command -v go &>/dev/null && [[ "$(go version 2>/dev/null)" == *"go${GO_VERSION}"* ]]; then
        info "Go ${GO_VERSION} already installed — skipping"
        return
    fi
    info "Installing Go ${GO_VERSION}"
    local tarball="go${GO_VERSION}.linux-amd64.tar.gz"
    curl -fsSL -o "/tmp/${tarball}" "https://go.dev/dl/${tarball}"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/${tarball}"
    rm -f "/tmp/${tarball}"
}

# ---------------------------------------------------------------------------
# 3. kind
# ---------------------------------------------------------------------------
install_kind() {
    if [[ -x "${INSTALL_DIR}/kind" ]] && "${INSTALL_DIR}/kind" version 2>/dev/null | grep -q "v${KIND_VERSION}"; then
        info "kind v${KIND_VERSION} already installed — skipping"
        return
    fi
    info "Installing kind v${KIND_VERSION}"
    local tmp
    tmp="$(mktemp)"
    curl -fsSL -o "${tmp}" \
        "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64"
    echo "${KIND_SHA512}  ${tmp}" | sha512sum -c -
    sudo install -m 0755 "${tmp}" "${INSTALL_DIR}/kind"
    rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# 4. kubectl
# ---------------------------------------------------------------------------
install_kubectl() {
    if [[ -x "${INSTALL_DIR}/kubectl" ]] && "${INSTALL_DIR}/kubectl" version --client 2>/dev/null | grep -q "v${KUBECTL_VERSION}"; then
        info "kubectl v${KUBECTL_VERSION} already installed — skipping"
        return
    fi
    info "Installing kubectl v${KUBECTL_VERSION}"
    local tmp
    tmp="$(mktemp)"
    curl -fsSL -o "${tmp}" \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    local expected_sha256
    expected_sha256="$(curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256")"
    echo "${expected_sha256}  ${tmp}" | sha256sum -c -
    sudo install -m 0755 "${tmp}" "${INSTALL_DIR}/kubectl"
    rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# 5. yq
# ---------------------------------------------------------------------------
install_yq() {
    if [[ -x "${INSTALL_DIR}/yq" ]] && "${INSTALL_DIR}/yq" --version 2>/dev/null | grep -q "${YQ_VERSION}"; then
        info "yq v${YQ_VERSION} already installed — skipping"
        return
    fi
    info "Installing yq v${YQ_VERSION}"
    local tmp
    tmp="$(mktemp)"
    curl -fsSL -o "${tmp}" \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64"
    echo "${YQ_SHA256}  ${tmp}" | sha256sum -c -
    sudo install -m 0755 "${tmp}" "${INSTALL_DIR}/yq"
    rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# 6. OS tuning for ScyllaDB on KinD
# ---------------------------------------------------------------------------
tune_os() {
    info "Applying OS tuning for ScyllaDB"

    # PAM limits (applies to future login sessions).
    sudo tee /etc/security/limits.d/99-scylla-operator-e2e.conf > /dev/null <<'EOF'
* soft nofile 1073741816
* hard nofile 1073741816
root soft nofile 1073741816
root hard nofile 1073741816
EOF

    # Persistent sysctls via drop-in (survives reboot).
    sudo tee /etc/sysctl.d/99-scylla-operator-e2e.conf > /dev/null <<'EOF'
fs.aio-max-nr = 30000000
fs.file-max = 9223372036854775807
fs.nr_open = 1073741816
fs.inotify.max_user_instances = 1200
vm.swappiness = 1
vm.vfs_cache_pressure = 2000
EOF
    sudo sysctl --system

    # Kernel keyring limits (runtime only — no sysctl.d equivalent).
    echo 50000  | sudo tee /proc/sys/kernel/keys/maxkeys      > /dev/null
    echo 50000  | sudo tee /proc/sys/kernel/keys/root_maxkeys > /dev/null
    echo 2000000 | sudo tee /proc/sys/kernel/keys/maxbytes     > /dev/null
    echo 2000000 | sudo tee /proc/sys/kernel/keys/root_maxbytes > /dev/null

    # Raise the current shell's nofile ceiling.
    sudo prlimit --pid=$$ --nofile=1073741816:1073741816 || \
        sudo prlimit --pid=$$ --nofile=1048576:1048576 || true
}

# ---------------------------------------------------------------------------
# 7. Rootless podman / systemd configuration
# ---------------------------------------------------------------------------
configure_podman() {
    info "Configuring rootless podman for KinD"

    # Podman drop-in: lift pids_limit, set utsns, enable cgroups.
    sudo mkdir -p /etc/containers/containers.conf.d
    printf '[containers]\npids_limit = 0\nutsns = "private"\ncgroups = "enabled"\n' \
        | sudo tee /etc/containers/containers.conf.d/99-kind-overrides.conf > /dev/null

    # Enable systemd linger so the user D-Bus session is available for
    # rootless podman's `systemd-run --user` (used by KinD).
    local uid user
    uid="$(id -u)"
    user="$(id -un)"

    # Ensure pam_systemd.so is loaded by sshd — without it, SSH sessions
    # do not register with systemd-logind and /run/user/<uid>/ is never
    # created.  Stock Ubuntu includes it via common-session, but
    # minimal/cloud images may omit it.
    if ! grep -rq 'pam_systemd' /etc/pam.d/sshd 2>/dev/null; then
        info "Adding pam_systemd.so to /etc/pam.d/sshd"
        echo 'session optional pam_systemd.so' | sudo tee -a /etc/pam.d/sshd > /dev/null
        sudo systemctl restart ssh
    fi

    sudo loginctl enable-linger "${user}" || true

    # Start the user manager explicitly if the D-Bus socket is not yet
    # present (linger alone only takes effect on next login).
    if [[ ! -S "/run/user/${uid}/bus" ]]; then
        sudo systemctl start "user@${uid}.service" || true

        # Ensure the runtime directory exists with correct ownership
        # (normally created by pam_systemd on login, but we may be in a
        # session that predates the PAM fix).
        if [[ ! -d "/run/user/${uid}" ]]; then
            sudo mkdir -p "/run/user/${uid}"
            sudo chown "${user}:${user}" "/run/user/${uid}"
        fi

        # Start the per-user D-Bus socket (the user manager doesn't
        # auto-start it unless triggered by a proper PAM login session).
        sudo -u "${user}" XDG_RUNTIME_DIR="/run/user/${uid}" \
            systemctl --user start dbus.socket || true

        for _ in $(seq 1 20); do
            [[ -S "/run/user/${uid}/bus" ]] && break
            sleep 0.5
        done
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_ubuntu_24
    install_packages
    install_go
    install_kind
    install_kubectl
    install_yq
    tune_os
    configure_podman

    # Ensure Go and local binaries are in PATH for future shells.
    # Also export XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS so rootless
    # podman can reach the user D-Bus session in SSH shells.
    if ! grep -qF '/usr/local/go/bin' ~/.bashrc 2>/dev/null; then
        cat >> ~/.bashrc <<'BASHRC_EOF'
export PATH="/usr/local/go/bin:/usr/local/bin:${PATH}"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
BASHRC_EOF
        info "Appended PATH and systemd session exports to ~/.bashrc"
    fi

    # Configure git: SSH key and email.
    git config --global core.sshCommand "ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes"
    git config --global user.email "yevhen.abramchuk@scylladb.com"
    info "Configured git SSH key (~/.ssh/id_ed25519) and email"

    info "Done. Reconnect your SSH session for all changes to take effect."
}

main "$@"
