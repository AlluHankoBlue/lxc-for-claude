#!/bin/bash
# End-to-end test of claude-box. Creates box cb-selftest on ./selftest-ws and removes it at the end
# (keep it with KEEP=1). Log: ./selftest.log
set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
cd "$HERE"

# Same group fallback as claude-box (Ubuntu 26.04 has no newgrp).
if ! incus info >/dev/null 2>&1; then
  if [ -z "${CB_REEXEC:-}" ] && id -nG "$(id -un)" | grep -qw incus-admin; then
    exec sudo -u "$(id -un)" -g incus-admin -- env CB_REEXEC=1 KEEP="${KEEP:-}" TERM="${TERM:-xterm}" "$0" "$@"
  fi
  echo "cannot reach incus"; exit 1
fi

exec > >(tee "$HERE/selftest.log") 2>&1
N=selftest; C=cb-$N; WS=$HERE/selftest-ws
pass=0; fail=0
ok()   { printf '\033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
t()    { local name=$1; shift; echo "--- $name: $*"; if "$@"; then ok "$name"; else bad "$name"; fi; }

echo "=== host: $(id) | $(date)"
echo "=== incus $(incus version | tr '\n' ' ')"
incus network list -f csv; incus storage list -f csv

echo "=== 1. network sanity (plain debian container)"
incus delete -f cb-nettest >/dev/null 2>&1
incus launch images:debian/13/cloud cb-nettest -q
for _ in $(seq 30); do incus exec cb-nettest -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 1; done
incus exec cb-nettest -- ip -br addr
incus exec cb-nettest -- ip route
t "container DNS"      incus exec cb-nettest -- getent hosts deb.debian.org
t "container HTTP out" incus exec cb-nettest -- bash -c 'exec 3<>/dev/tcp/deb.debian.org/80 && printf "HEAD / HTTP/1.0\r\nHost: deb.debian.org\r\n\r\n" >&3 && head -1 <&3'
incus delete -f cb-nettest
if [ $fail -gt 0 ]; then echo "Network broken -> run: sudo ./host-net-fix.sh"; echo "RESULT: $pass passed, $fail failed"; exit 1; fi

echo "=== 2. setup (builds image if missing)"
t "setup" ./claude-box setup

echo "=== 3. new box"
./claude-box rm $N -y >/dev/null 2>&1
mkdir -p "$WS"
t "new" ./claude-box new $N "$WS"
./claude-box ls

echo "=== 4. checks"
t "bind mount uid shift" bash -c "./claude-box ssh $N 'touch /workspace/owner-test' && [ \"\$(stat -c %U '$WS/owner-test')\" = '$(id -un)' ]"
t "ssh env + tools"   ./claude-box ssh $N 'echo CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR; [ "$CLAUDE_CONFIG_DIR" = /home/dev/.claude-config ] && which claude gcc make node python3 docker git gh rg && gh --version | head -1 && claude --version && gcc --version | head -1 && node --version'
t "docker group"      ./claude-box ssh $N 'id -nG | grep -qw docker'
t "docker run"        ./claude-box ssh $N 'docker run --rm hello-world | grep -q "Hello from Docker"'
t "docker build"      ./claude-box ssh $N 'cd /workspace && printf "FROM debian:13-slim\nRUN echo built > /x\n" > Dockerfile.selftest && docker build -q -f Dockerfile.selftest -t cbtest . && docker run --rm cbtest cat /x && docker rmi -f cbtest >/dev/null; rm -f Dockerfile.selftest'
t "sudo nopasswd"     ./claude-box ssh $N 'sudo -n true'
t "no host home"      ./claude-box ssh $N '! ls /home/allu 2>/dev/null'
t "ssh 127.0.0.1 only" bash -c "ss -Hltn | grep -E ':$(incus config get $C user.claude-box.sshport)\b' | grep -q '127.0.0.1'"
t "password auth off" bash -c "! ssh -o BatchMode=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no $C true 2>/dev/null"
t "incus exec claude" ./claude-box claude $N --version
t "snapshot"          bash -c "./claude-box snap $N s1 >/dev/null && ./claude-box ssh $N 'touch ~/after-snap' && incus stop $C && ./claude-box restore $N s1 && incus start $C && sleep 3 && ./claude-box ssh $N '[ ! -e ~/after-snap ]'"

echo "=== 5. herdr"
HERDR=$(command -v herdr || echo "$HOME/.local/bin/herdr")
if [ -x "$HERDR" ]; then
  t "herdr machine add" ./claude-box herd $N
  "$HERDR" machine list 2>&1 | head
else
  echo "herdr not found, skipped"
fi

echo "=== 6. cleanup"
if [ -n "${KEEP:-}" ]; then echo "KEEP=1: leaving $C"; else
  t "rm" ./claude-box rm $N -y
  rm -rf "$WS"
fi

echo "RESULT: $pass passed, $fail failed"
[ $fail -eq 0 ]
