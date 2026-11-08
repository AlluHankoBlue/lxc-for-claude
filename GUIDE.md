# claude-box: the full guide

This guide covers running Claude Code in an isolated container for each project, managed from the host with `claude-box` and herdr.

---

## 1. How it works

```
HOST (Ubuntu)                                   CONTAINER cb-myapp (Debian 13, unprivileged)
─────────────────────────────                   ────────────────────────────────────────────
~/code/myapp  ◀──── bind mount (same owner) ───▶ /workspace
herdr / ssh   ──── 127.0.0.1:2201 ─────────────▶ sshd :22  (user: dev)
browser       ──── 10.209.199.x:<port> ────────▶ your dev server / docker containers
                                                 Claude Code, Docker, gcc, Node, Python, gh
Incus volume "claude-auth" ───── shared ───────▶ /home/dev/.claude-config  (Claude login)
```

| Term | Meaning |
|---|---|
| **box** | An Incus container named `cb-<name>`. Use one box per project. |
| **`/workspace`** | Your project folder on the host, mounted into the box. Changes show up on both sides immediately. On the host, the files stay owned by you. |
| **`dev`** | The user inside the box, uid 1000. It has sudo without a password and is in the `docker` group. |
| **`claude-base`** | The image every box starts from. |
| **template** | A box you saved as an image (`tpl-<name>`), so new boxes start with your extra setup already in place. |
| **`claude-auth`** | A shared volume that holds the Claude Code login. You log in once, and every box uses it. |

Claude **can** change anything inside its box and inside `/workspace`.

Claude **cannot** reach your host home folder, your `~/.ssh` keys, your host Claude login, your other projects, or host processes.

---

## 2. One-time installation

### 2.1 Group membership
You need the `incus-admin` group in your current login session:
```sh
id | grep incus-admin || echo "log out and back in (or reboot)"
```
Ubuntu 26.04 has no `newgrp`. Until you log in again, `claude-box` re-runs itself through `sudo -g incus-admin` and asks for your password. It still runs as you, not root.

> **Never run `claude-box` with `sudo`.** It refuses to, because your SSH config and herdr setup would end up in root's home.

### 2.2 Fix container networking (ufw and host Docker)
Your host runs ufw and Docker, and both block container traffic by default. Run this once; the fix survives reboots:
```sh
cd ~/soft/lxcForCluade
sudo ./host-net-fix.sh
```

### 2.3 Put `claude-box` on your PATH
```sh
ln -s ~/soft/lxcForCluade/claude-box ~/.local/bin/claude-box
```

### 2.4 Setup
```sh
claude-box setup
```
This creates:
- the storage volume `claude-auth`
- the Incus profile `claude-dev`
- a dedicated SSH key, `~/.ssh/claude-box_ed25519`
- an `Include` line at the top of `~/.ssh/config`

It then builds the `claude-base` image, which takes 5–10 minutes.

### 2.5 Test that everything works (optional, recommended)
```sh
~/soft/lxcForCluade/selftest.sh          # creates cb-selftest, tests everything, then removes it
```
The test checks:
- network access
- the workspace mount and file ownership
- the tools: claude, gcc, node, python, docker, gh
- `docker run` and `docker build`
- SSH lockdown
- snapshots
- herdr registration

The output is also saved to `selftest.log`.

---

## 3. Your first project

```sh
claude-box new myapp ~/code/myapp --herd
```
This does the following:
1. Creates the container `cb-myapp` from `claude-base`.
2. Mounts `~/code/myapp` at `/workspace`. The folder is created if it doesn't exist.
3. Assigns an SSH port on `127.0.0.1`, starting at 2201, and adds an SSH alias so `ssh cb-myapp` works.
4. Registers the box in herdr, because of `--herd`.

Start Claude:
```sh
claude-box claude myapp
```
The **first time you ever** run Claude in any box, type `/login` and finish the browser flow. After that, every box, including future ones, is already logged in.

---

## 4. Daily use

### 4.1 Running Claude Code

| Way | Command |
|---|---|
| From any terminal | `claude-box claude myapp` |
| Without permission prompts (the box is the sandbox) | `claude-box claude myapp --yolo` |
| Passing Claude arguments | `claude-box claude myapp --continue` or `claude-box claude myapp -p "run the tests"` |
| From herdr | `herdr --remote cb-myapp`, or pick `cb-myapp` in the herdr sidebar, then `cd /workspace && claude` |
| Over SSH | `ssh cb-myapp`, then `claude`. You land in `/workspace` automatically. |

**When to use `--yolo`:** it's reasonably safe here, because Claude can only damage the box and `/workspace`. Commit your work before long unattended runs.

### 4.2 Shell access
```sh
claude-box shell myapp      # through incus; works even if SSH is broken
ssh cb-myapp                # through SSH; the same path herdr uses
ssh cb-myapp 'cd /workspace && make test'     # run one command
```

### 4.3 Editing code
- **On the host:** use your normal editor on `~/code/myapp`. The box sees changes instantly.
- **Inside the box:** VS Code Remote-SSH and JetBrains Gateway work with the host name `cb-myapp`, because the alias is in your SSH config. Open the folder `/workspace`.

### 4.4 herdr
```sh
claude-box herd myapp        # register later, if you skipped --herd
herdr machine list           # check it's there
herdr --remote cb-myapp      # open herdr on the box
```
`claude-box rm` also removes the box from herdr.

---

## 5. Reaching services in a box (web apps, APIs, databases)

The service must listen on **`0.0.0.0`**, not on `127.0.0.1`, unless you use option B.

**A. Directly by IP (quickest)**
```sh
incus list cb-myapp -c n4               # e.g. 10.209.199.42
# open http://10.209.199.42:3000 in your host browser
```
How to make common dev servers listen on all interfaces:

| Server | Command |
|---|---|
| Vite / npm | `npm run dev -- --host 0.0.0.0` |
| Python | `python3 -m http.server 8000 --bind 0.0.0.0` |
| uvicorn | `uvicorn app:app --host 0.0.0.0` |
| Rails | `rails s -b 0.0.0.0` |

**B. Fixed port on the host's localhost** (survives restarts, and the service can stay on `127.0.0.1`)
```sh
incus config device add cb-myapp web proxy listen=tcp:127.0.0.1:3000 connect=tcp:127.0.0.1:3000
# http://localhost:3000 on the host
incus config device remove cb-myapp web
```
To expose the port to your LAN as well, use `listen=tcp:0.0.0.0:3000`.

**C. Temporary SSH tunnel**
```sh
ssh -N -L 3000:localhost:3000 cb-myapp      # Ctrl+C to stop
```

**Docker containers inside the box:** `docker run -p 8080:80 nginx` is reachable at `http://<box-ip>:8080`. To use localhost instead, add a proxy device as in option B.

---

## 6. Docker inside the box

Docker works normally for `dev` and for Claude:
```sh
docker run --rm hello-world
docker build -t myimg .
docker compose up -d
```
- Each box has its own Docker daemon, images, and volumes, fully separate from your host's Docker.
- Images pulled in a box stay in that box. To have them ready in new boxes, pull them and save a template (section 8).
- Never mount the host's `/var/run/docker.sock` into a box. Doing that gives root on the host.

---

## 7. Git and GitHub

`git` and `gh` are installed. Each box needs its own GitHub credentials. Your host keys are intentionally out of reach.

**Option 1: `gh` login (easiest)**
```sh
ssh cb-myapp
gh auth login            # GitHub.com → HTTPS → browser or paste a token
gh auth setup-git        # git push over HTTPS uses gh
```

**Option 2: a fine-grained token per project (most contained)**

Create a token on GitHub that is limited to one repo, then:
```sh
ssh -t cb-myapp 'read -rsp "token: " t && echo "$t" | gh auth login --with-token && gh auth setup-git && gh auth status'
```
The token is stored in `/home/dev/.config/gh/hosts.yml` inside that box only, so it works for SSH, herdr, and `claude-box claude`.
(Setting `environment.GH_TOKEN` with `incus config` only reaches `incus exec` sessions, not SSH or herdr.)

**Option 3: a deploy key per repo**
```sh
ssh cb-myapp 'ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub'
# add the key under the repo's Settings → Deploy keys (tick "write" if pushing is needed)
```

Set your git identity once per box, or put it in a template:
```sh
ssh cb-myapp 'git config --global user.name "Your Name"; git config --global user.email "you@example.com"'
```

> ⚠️ A GitHub login or key made inside a box **is copied into any template you save from that box**.

---

## 8. Templates (reuse your setup)

Use a template when you've customized a box (extra apt packages, global npm tools, pulled Docker images, git config) and want new boxes to start that way.
```sh
claude-box template myapp web              # save cb-myapp as image tpl-web
claude-box new shop ~/code/shop --from web # new box from the template
claude-box templates                       # list claude-base and tpl-*
claude-box rm-template web
```
- A template **does not** include `/workspace` or the Claude login. The login comes from the shared volume either way.
- It **does** include everything else in the box, including any `gh` or git credentials.
- Each new box from a template gets its own SSH host keys and machine-id.

---

## 9. Snapshots (undo for the box)

```sh
claude-box snap myapp before-upgrade
claude-box restore myapp before-upgrade
incus snapshot list cb-myapp
incus snapshot delete cb-myapp before-upgrade
```
Snapshots cover the box: system, packages, Docker images, home folder.

**Snapshots do not cover `/workspace`.** Use git for your code:
```sh
git add -A && git commit -m wip
```
Do this before `--yolo` sessions.

---

## 10. Managing boxes

```sh
claude-box ls                   # name, state, SSH port, workspace folder
claude-box stop myapp           # frees RAM; files and setup are kept
claude-box start myapp
claude-box rm myapp             # deletes the box, its SSH alias and herdr entry; ~/code/myapp is kept
```

### Resources
Each box can use up to **4 CPUs and 6 GiB RAM**. These are limits, not reservations. Your host has 14 GiB, so stop boxes you aren't using.

Change the limits for one box:
```sh
incus config set cb-myapp limits.memory=10GiB limits.cpu=6
```
Change them for all boxes: edit `profile-claude-dev.yaml`, then run `claude-box setup`.

Check usage:
```sh
incus info cb-myapp | grep -A5 Resources
incus list -c ns4mu
```

### Mounting an extra host folder
```sh
incus config device add cb-myapp data disk source=$HOME/datasets path=/data shift=true
incus config device add cb-myapp data-ro disk source=$HOME/datasets path=/data readonly=true shift=true
```
The second line shows a read-only variant.

---

## 11. Updating

| What | How |
|---|---|
| Claude Code inside boxes | Updates itself. To force an update: `ssh cb-myapp claude update` |
| OS packages in one box | `ssh cb-myapp 'sudo apt update && sudo apt upgrade -y'` |
| The base image (new Claude, Docker, Node, gh, OS) | `claude-box rebuild-base`. Only **new** boxes use it. |
| Templates | Recreate them from a box that's up to date. |
| Profile changes (limits, devices) | Edit `profile-claude-dev.yaml`, then run `claude-box setup`. Applies to all boxes. |

---

## 12. Troubleshooting

| Problem | Fix |
|---|---|
| `cannot talk to incus daemon` | Log out and back in so your session has `incus-admin`. Until then, enter your sudo password when asked. |
| `apt-get update` fails, or a box has no internet | `sudo ./host-net-fix.sh`, then `claude-box setup --rebuild`. Check with `incus exec cb-myapp -- getent hosts deb.debian.org`. |
| A box has no IPv4 address in `incus list` | ufw is blocking DHCP. Run `sudo ./host-net-fix.sh`. |
| `herdr not found` | Run as your normal user, not sudo. Or set `CB_HERDR_BIN=$(command -v herdr)`. |
| `ssh cb-myapp` fails | Check `claude-box ls` (is the box running?) and `incus config device show cb-myapp` (the `ssh` proxy). Then `ssh -v cb-myapp`. |
| "Host key changed" warning | Run `ssh-keygen -R "[127.0.0.1]:<port>" -f ~/.ssh/claude-box_known_hosts`. |
| Claude asks for login again | Check `ssh cb-myapp 'echo $CLAUDE_CONFIG_DIR; ls -la ~/.claude-config'`. It should show `/home/dev/.claude-config`, owned by `dev`. |
| Permission denied in `/workspace` | Run `incus config device show cb-myapp`. The `work` device needs `shift: "true"`. |
| A Docker image or container fails with an overlay error | Check `ssh cb-myapp docker info \| grep Storage`. The build falls back to `fuse-overlayfs` automatically. |
| Service not reachable | Make sure it listens on `0.0.0.0` (section 5): `ssh cb-myapp 'ss -ltnp'`. |
| Box is slow or killed (out of memory) | Raise `limits.memory` and stop boxes you aren't using. |
| Leftover `cb-base-build` after a failed build | `incus delete -f cb-base-build`, then `claude-box rebuild-base`. |

Useful Incus commands:
```sh
incus list
incus info cb-myapp --show-log
incus config show cb-myapp --expanded
incus exec cb-myapp -- bash        # root shell (debugging only)
```

---

## 13. Uninstall

```sh
for b in $(incus list -f csv -c n '^cb-'); do claude-box rm "${b#cb-}" -y; done
incus image delete claude-base; for t in $(incus image list -f csv -c l | grep '^tpl-'); do incus image delete "$t"; done
incus profile delete claude-dev
incus storage volume delete default claude-auth          # removes the shared Claude login
rm -rf ~/.ssh/claude-box* && sed -i '\|Include .*claude-box.d|d' ~/.ssh/config
sudo systemctl disable --now incus-docker-forward.service
sudo rm /etc/systemd/system/incus-docker-forward.service /usr/local/sbin/incus-docker-forward
```

---

## 14. Command reference

| Command | Does |
|---|---|
| `setup [--rebuild]` | One-time host setup. `--rebuild` also rebuilds the image. |
| `rebuild-base` | Rebuilds the `claude-base` image. |
| `new <name> <dir> [--from <tpl>] [--herd]` | Creates box `cb-<name>` with `<dir>` mounted at `/workspace`. |
| `claude <name> [--yolo] [args…]` | Runs Claude Code in `/workspace`. |
| `shell <name>` | Opens a login shell as `dev` through incus. |
| `ssh <name> [cmd]` | Connects over SSH, the same way herdr does. |
| `herd <name>` | Registers the box in herdr. |
| `snap <name> [label]` | Snapshots the box. |
| `restore <name> <label>` | Restores a snapshot. |
| `template <name> [tpl]` | Saves the box as image `tpl-<tpl>`. |
| `templates` | Lists the base image and templates. |
| `rm-template <tpl>` | Deletes a template. |
| `start` / `stop <name>` | Starts or stops a box. |
| `rm <name> [-y]` | Deletes a box (the host folder is kept). |
| `ls` | Lists boxes. |

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `CB_POOL` | `default` | Storage pool |
| `CB_PORT_BASE` | `2201` | First SSH port |
| `CB_IMAGE` | `claude-base` | Base image |
| `CB_SOURCE_IMAGE` | `images:debian/13/cloud` | Image the base is built from |
| `CB_HERDR_BIN` | auto | Path to `herdr` |

## 15. Files

| Path | Purpose |
|---|---|
| `~/soft/lxcForCluade/claude-box` | The CLI |
| `build-base.sh`, `base/provision.sh` | Image build; edit `provision.sh` to add tools to every box |
| `profile-claude-dev.yaml` | Limits, Docker support, shared login volume |
| `host-net-fix.sh` | ufw and Docker firewall fix |
| `selftest.sh` | End-to-end test |
| `~/.ssh/claude-box_ed25519` | Dedicated key for boxes |
| `~/.ssh/claude-box.d/cb-*.conf` | SSH alias for each box |
| `~/.ssh/claude-box_known_hosts` | Host keys of the boxes |
