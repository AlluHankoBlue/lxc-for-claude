#!/bin/bash
# Runs as root INSIDE the build container (pushed there by build-base.sh).
# Env: GIT_NAME, GIT_EMAIL (optional)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
log() { printf '\n\033[1;34m[provision]\033[0m %s\n' "$*"; }

log "Waiting for cloud-init and network"
cloud-init status --wait >/dev/null 2>&1 || true
net_ok=0
for _ in $(seq 60); do
  if getent hosts deb.debian.org >/dev/null && { ! command -v curl >/dev/null || curl -fsS -m 5 -o /dev/null http://deb.debian.org/debian/; }; then net_ok=1; break; fi
  sleep 1
done
if [ $net_ok = 0 ]; then
  echo "ERROR: container has no working network (cannot reach deb.debian.org)." >&2
  ip -br addr >&2 || true; ip route >&2 || true; cat /etc/resolv.conf >&2 || true
  echo "No IPv4 above => DHCP blocked (ufw). IP but no route out => FORWARD blocked (Docker/ufw)." >&2
  echo "Fix on host: sudo ~/soft/lxcForCluade/host-net-fix.sh   then: ./claude-box setup --rebuild" >&2
  exit 1
fi

log "User 'dev' (uid/gid 1000)"
existing=$(getent passwd 1000 | cut -d: -f1 || true)
if [ -n "$existing" ] && [ "$existing" != dev ]; then
  userdel -r "$existing" 2>/dev/null || userdel "$existing"
fi
egrp=$(getent group 1000 | cut -d: -f1 || true)
if [ -n "$egrp" ] && [ "$egrp" != dev ]; then groupdel "$egrp" || true; fi
getent group dev >/dev/null || groupadd -g 1000 dev
id dev >/dev/null 2>&1 || useradd -m -u 1000 -g 1000 -s /bin/bash dev
# /home/dev may pre-exist (Incus creates the claude-auth mountpoint), so skel may not have been copied.
cp -rn /etc/skel/. /home/dev/
chown dev:dev /home/dev /home/dev/.claude-config 2>/dev/null || chown dev:dev /home/dev
find /home/dev -maxdepth 1 -mindepth 1 ! -name .claude-config -exec chown -R dev:dev {} +

log "Base packages"
apt-get update
apt-get install -y --no-install-recommends \
  build-essential pkg-config git curl wget ca-certificates gnupg \
  ripgrep fd-find jq unzip zip less vim-tiny file procps iproute2 \
  python3 python3-pip python3-venv openssh-server sudo fuse-overlayfs locales
ln -sf /usr/bin/fdfind /usr/local/bin/fd
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen >/dev/null

echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev && chmod 440 /etc/sudoers.d/dev

log "Docker CE"
. /etc/os-release
install -m 0755 -d /etc/apt/keyrings
if curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; then
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
fi
if apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
  :
else
  log "Docker CE repo unavailable for ${VERSION_CODENAME}; falling back to Debian docker.io"
  rm -f /etc/apt/sources.list.d/docker.sources
  apt-get update
  apt-get install -y docker.io docker-compose docker-buildx || apt-get install -y docker.io
fi
usermod -aG docker dev
systemctl enable --now docker

log "Docker smoke test"
if ! docker run --rm hello-world >/dev/null 2>&1; then
  log "overlay2 failed; switching Docker to fuse-overlayfs"
  echo '{ "storage-driver": "fuse-overlayfs" }' > /etc/docker/daemon.json
  systemctl restart docker
  docker run --rm hello-world >/dev/null
fi
docker info --format 'Docker storage driver: {{.Driver}}'
docker system prune -af >/dev/null

log "Node.js LTS"
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

log "GitHub CLI (gh)"
if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; then
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
fi
apt-get update
apt-get install -y gh || { rm -f /etc/apt/sources.list.d/github-cli.list; apt-get update; apt-get install -y gh; }
gh --version | head -1

log "Environment for all sessions (incus exec, ssh login + non-login)"
grep -q '^CLAUDE_CONFIG_DIR=' /etc/environment 2>/dev/null \
  || echo 'CLAUDE_CONFIG_DIR=/home/dev/.claude-config' >> /etc/environment
cat > /etc/profile.d/claude-box.sh <<'EOF'
export CLAUDE_CONFIG_DIR=/home/dev/.claude-config
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
EOF
cat >> /home/dev/.bashrc <<'EOF'

# claude-box
export CLAUDE_CONFIG_DIR=/home/dev/.claude-config
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
if [[ $- == *i* ]] && [ "$PWD" = "$HOME" ] && [ -d /workspace ]; then cd /workspace; fi
EOF

log "Claude Code (native installer, as dev)"
install -d -o dev -g dev /home/dev/.claude-config
chown dev:dev /home/dev/.claude-config
su - dev -c 'export CLAUDE_CONFIG_DIR=/home/dev/.claude-config; curl -fsSL https://claude.ai/install.sh | bash'
ln -sf /home/dev/.local/bin/claude /usr/local/bin/claude   # on PATH for non-login ssh / herdr
su - dev -c 'claude --version'

if [ -n "${GIT_NAME:-}" ];  then su - dev -c "git config --global user.name  \"$GIT_NAME\""; fi
if [ -n "${GIT_EMAIL:-}" ]; then su - dev -c "git config --global user.email \"$GIT_EMAIL\""; fi
su - dev -c 'git config --global --add safe.directory /workspace; git config --global init.defaultBranch main'

log "sshd (key-only, dev only)"
cat > /etc/ssh/sshd_config.d/10-claude-box.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers dev
EOF
install -d -m 700 -o dev -g dev /home/dev/.ssh
cat > /etc/systemd/system/ssh-hostkeys.service <<'EOF'
[Unit]
Description=Generate SSH host keys if missing
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
systemctl enable ssh-hostkeys.service ssh.service

log "Cleanup for publishing"
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs >/dev/null 2>&1 || true
truncate -s 0 /etc/machine-id
log "Provisioning done"
