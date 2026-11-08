# claude-box

**Run Claude Code in its own isolated Incus (LXC) container for each project. Docker and the usual build tools come preinstalled, and herdr on the host can drive every box over SSH.**

Let Claude work at full speed, `--dangerously-skip-permissions` included, inside a box where the worst it can do is damage that box and the one project folder you gave it. Your host home folder, SSH keys, other projects, and host Claude login stay out of reach.

```
HOST                                             BOX  cb-myapp  (Debian 13, unprivileged)
──────────────────────────────                   ─────────────────────────────────────────
~/code/myapp   ◀──── bind mount, same owner ───▶ /workspace
herdr / ssh    ──── 127.0.0.1:2201 ────────────▶ sshd (user dev, key only)
browser        ──── 10.209.199.x:<port> ───────▶ dev servers, docker containers
                                                 Claude Code · Docker · gcc · Node · Python · gh
Incus volume "claude-auth" ──── shared ────────▶ /home/dev/.claude-config  (log in once)
```

> 📖 **[GUIDE.md](GUIDE.md)** is the full manual: setup, daily use, herdr, ports, Docker, GitHub, templates, snapshots, troubleshooting, and uninstalling.

---

## Features

- **One box per project.** `claude-box new myapp ~/code/myapp` gives you a container with your project at `/workspace`. Files keep your host ownership, through idmapped `shift=true` mounts.
- **Batteries included.** Every box has Claude Code (native installer), Docker CE with buildx and compose, `build-essential`, Node LTS, Python 3, GitHub CLI, git, ripgrep, fd, and jq.
- **Docker inside the box.** Nested Docker runs in an unprivileged container, and Claude can build images and run compose stacks. The host's Docker socket is never exposed.
- **Log in once.** The Claude Code login lives on a shared Incus volume, so every box, including future ones, is already logged in. Host credentials are never copied in.
- **herdr ready.** Each box gets sshd behind a `127.0.0.1` port and an SSH alias, `cb-<name>`. `--herd` registers the box in [herdr](https://herdr.dev) automatically.
- **Snapshots and templates.** Snapshot a box before risky work. Save a customized box as a template and start new boxes from it.
- **Small and readable.** It's plain bash plus one Incus profile, with no daemon of its own.

## Requirements

| | |
|---|---|
| Host | Linux with **Incus ≥ 6.0** (tested on Ubuntu 26.04, Incus 6.0.5, kernel 7.0) |
| User | member of the `incus-admin` group, in your **current** login session |
| Optional | [herdr](https://herdr.dev) on the host |
| Network | internet access for building the image (Debian, Docker, NodeSource, GitHub, and claude.ai repos) |

## Quick start

```sh
git clone <this repo> ~/soft/lxcForCluade && cd ~/soft/lxcForCluade

# 1. Only if the host runs ufw or Docker (both block container traffic by default):
sudo ./host-net-fix.sh

# 2. Put the CLI on PATH and do the one-time setup (builds the image, ~5–10 min)
ln -s "$PWD/claude-box" ~/.local/bin/claude-box
claude-box setup

# 3. Optional: check everything end to end
./selftest.sh

# 4. Create a box for a project and start Claude
claude-box new myapp ~/code/myapp --herd
claude-box claude myapp          # first time ever: type /login
```

> **Never run `claude-box` with sudo.** If your session doesn't have `incus-admin` yet (Ubuntu 26.04 has no `newgrp`), the script re-runs itself through `sudo -u $USER -g incus-admin`, still as you. Logging out and back in fixes this for good.

## Usage

```sh
# Boxes
claude-box new <name> <dir> [--from <tpl>] [--herd]   # create cb-<name>, <dir> → /workspace
claude-box ls                                          # list boxes, SSH ports, workspaces
claude-box start|stop <name>
claude-box rm <name> [-y]                              # delete box (host folder is kept)

# Working
claude-box claude <name> [--yolo] [claude args…]       # Claude Code in /workspace
claude-box shell <name>                                # bash as dev (incus exec)
claude-box ssh <name> [cmd]                            # ssh, same path herdr uses
ssh cb-<name>                                          # plain ssh / VS Code Remote-SSH
claude-box herd <name>                                 # register in herdr → herdr --remote cb-<name>

# Snapshots (cover the box, NOT /workspace) and templates
claude-box snap <name> [label]
claude-box restore <name> <label>
claude-box template <name> [tpl]                       # save as image tpl-<tpl>
claude-box templates
claude-box rm-template <tpl>

# Maintenance
claude-box setup [--rebuild]
claude-box rebuild-base                                # new Claude/OS/Docker in the base image
```

### Typical day

```sh
claude-box start myapp
claude-box claude myapp --yolo     # or open cb-myapp in herdr
# open http://<box-ip>:3000. Find the IP with: incus list cb-myapp -c n4
git -C ~/code/myapp commit -am wip
claude-box stop myapp
```

### Reaching a service in a box

```sh
incus list cb-myapp -c n4                                    # browse http://<ip>:<port>; bind servers to 0.0.0.0
incus config device add cb-myapp web proxy \
  listen=tcp:127.0.0.1:3000 connect=tcp:127.0.0.1:3000       # or: http://localhost:3000 on the host
```

### GitHub inside a box

Credentials are set up **per box** and never copied from the host:

```sh
ssh -t cb-myapp
gh auth login && gh auth setup-git     # or pipe a fine-grained, single-repo token into: gh auth login --with-token
```

See [GUIDE.md §7](GUIDE.md#7-git-and-github) for tokens and deploy keys.

## Configuration

| Setting | Where | Default |
|---|---|---|
| CPU and RAM per box | `profile-claude-dev.yaml` (then `claude-box setup`), or `incus config set cb-x limits.memory=…` | 4 CPU / 6 GiB |
| Tools in every box | `base/provision.sh` (then `claude-box rebuild-base`) | see Features |
| Storage pool | `CB_POOL` | `default` |
| First SSH port | `CB_PORT_BASE` | `2201` |
| Base image name | `CB_IMAGE` | `claude-base` |
| Upstream image | `CB_SOURCE_IMAGE` | `images:debian/13/cloud` |
| herdr binary | `CB_HERDR_BIN` | found in `PATH` or `~/.local/bin` |

## Project layout

| Path | Purpose |
|---|---|
| `claude-box` | The CLI |
| `build-base.sh` | Builds and publishes the `claude-base` image |
| `base/provision.sh` | Runs inside the build container: packages, Docker, Node, gh, Claude Code, sshd, and the environment |
| `profile-claude-dev.yaml` | Incus profile `claude-dev`: limits, Docker nesting, the shared login volume |
| `host-net-fix.sh` | ufw and Docker firewall fix for `incusbr0` (persistent systemd unit) |
| `selftest.sh` | End-to-end test (writes `selftest.log`) |
| `GUIDE.md` | Full user guide |

Files it creates on the host:
- `~/.ssh/claude-box_ed25519`: the dedicated box key
- `~/.ssh/claude-box.d/cb-*.conf`: one SSH alias per box
- `~/.ssh/claude-box_known_hosts`
- one `Include` line at the top of `~/.ssh/config`

## Security model

| | |
|---|---|
| ✅ **Isolated** | Host home folder, `~/.ssh`, the host Claude login, other projects, host processes. Boxes are **unprivileged**, so root in a box is an unmapped uid on the host. |
| ✅ **SSH** | Listens on host `127.0.0.1` only, key auth only, user `dev` only, with a dedicated key. |
| ⚠️ **`/workspace`** | Claude can change or delete the mounted project. Use git. Snapshots don't cover it. |
| ⚠️ **Nesting** | `security.nesting=true` (needed for Docker) weakens the boundary somewhat. It's still far safer than sharing the host's Docker socket, which you should never mount. |
| ⚠️ **Shared login** | Every box can read the Claude token on the `claude-auth` volume. Use per-box volumes or a capped API key if that matters. |
| ⚠️ **Network** | Full internet and LAN access through `incusbr0`. Add an Incus network ACL to block RFC1918 ranges if needed. |
| ⚠️ **incus-admin** | Anyone in this group can `incus exec` into any box. The group is effectively root on the host. |
| ⚠️ **Templates** | A template copies everything in the box, including any `gh` or git credentials you added. |

## Troubleshooting (short)

| Symptom | Fix |
|---|---|
| `cannot talk to incus daemon` | Log out and back in, or enter your sudo password when asked |
| No internet in the box, or `apt-get update` fails | `sudo ./host-net-fix.sh`, then `claude-box setup --rebuild` |
| `herdr not found` | Don't use sudo, or set `CB_HERDR_BIN=$(command -v herdr)` |
| Service not reachable | Bind it to `0.0.0.0` inside the box, or add a proxy device |
| Host key warning after recreating a box | `ssh-keygen -R "[127.0.0.1]:<port>" -f ~/.ssh/claude-box_known_hosts` |

The full list is in [GUIDE.md §12](GUIDE.md#12-troubleshooting).

## Uninstall

See [GUIDE.md §13](GUIDE.md#13-uninstall). In short:
1. `claude-box rm` every box.
2. Delete the `claude-base` and `tpl-*` images, the `claude-dev` profile, and the `claude-auth` volume.
3. Remove `~/.ssh/claude-box*` and the `Include` line from `~/.ssh/config`.
