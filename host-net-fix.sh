#!/bin/bash
# Let Incus containers on incusbr0 reach the network when the host runs ufw and/or Docker.
# Docker sets the iptables FORWARD policy to DROP; ufw blocks DHCP/DNS and routing for the bridge.
# Run with sudo. Idempotent. Installs a systemd unit so the Docker rules survive reboots/docker restarts.
set -euo pipefail
BR=${1:-incusbr0}
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo $0 [$BR]"; exit 1; }

if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  echo ">> ufw: allowing traffic on $BR"
  ufw allow in on "$BR"
  ufw route allow in on "$BR"
  ufw route allow out on "$BR"
fi

if command -v docker >/dev/null; then
  echo ">> Docker: installing incus-docker-forward.service (DOCKER-USER accept rules for $BR)"
  cat > /usr/local/sbin/incus-docker-forward <<EOF
#!/bin/sh
# Wait for Docker to create the DOCKER-USER chain.
for i in \$(seq 30); do iptables -nL DOCKER-USER >/dev/null 2>&1 && break; sleep 1; done
iptables -nL DOCKER-USER >/dev/null 2>&1 || iptables -N DOCKER-USER
iptables -C DOCKER-USER -i $BR -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -i $BR -j ACCEPT
iptables -C DOCKER-USER -o $BR -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || iptables -I DOCKER-USER -o $BR -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
EOF
  chmod 755 /usr/local/sbin/incus-docker-forward
  cat > /etc/systemd/system/incus-docker-forward.service <<'EOF'
[Unit]
Description=Allow Incus bridge traffic through Docker's FORWARD DROP policy
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/incus-docker-forward

[Install]
WantedBy=docker.service multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable incus-docker-forward.service
  systemctl restart incus-docker-forward.service
fi

echo ">> Done. Test: incus launch images:debian/13/cloud nettest && sleep 10 && incus exec nettest -- getent hosts deb.debian.org; incus delete -f nettest"
