# 01 — Quickstart: from a brand-new VM to a working agent

This page takes you from a freshly made Linux VM to an AI coding agent
working on one of your repositories, inside a container that holds none of
your credentials. Every command is written out. Copy them one block at a
time, in order, and check what each block tells you to check before going on.

It takes about 45 minutes the first time. Most of that is waiting for
packages and for the first image build.

Read [00 — Threat model](00-threat-model.md) if you want to know what this
protects and what it does not. The short version: the agent gets one copy of
one repository, a short list of hosts it may reach, and a number of model
requests. It does not get your files, your keys or your login.

> **What has been tried.** Every step here was run on **Debian 13** with
> rootless Podman 5.4.2 on 2026-10-10, and every barrier held. The **Ubuntu**
> and **Fedora** commands use those distributions' own packages for the same
> pieces, but have not been run by the authors. On any host,
> `./sandbox doctor` (step 12) has the last word: it checks every condition
> the sandbox depends on and prints the fix for each one that fails.
> [08 — Verification](08-verification.md) has the details.

## How to read this page

There are **three places** you type commands. Every block says which one:

| Label | Where | Who you are |
|---|---|---|
| **workstation** | Your own laptop or desktop: the machine with a browser | yourself |
| **VM, admin** | The new VM, logged in as the user it came with (`debian`, `ubuntu`, `fedora`, `root`...) | the admin, who can use `sudo` |
| **VM, sandboxer** | The new VM, logged in as `sandboxer`, the account made in step 4 | an ordinary user with **no** `sudo` |

When a command contains something in angle brackets, like `<vm-address>`,
replace the whole thing, brackets included, with your own value.

When a block has lines for several distributions, run **only the lines for
yours**.

## Contents

1. [What you need](#1-what-you-need)
2. [Make the VM and log in](#2-make-the-vm-and-log-in)
3. [Install the packages](#3-install-the-packages)
4. [Make the sandbox account](#4-make-the-sandbox-account)
5. [Let that account set resource limits](#5-let-that-account-set-resource-limits)
6. [Make the disk store](#6-make-the-disk-store)
7. [Install gitleaks](#7-install-gitleaks)
8. [Switch off the crash reporter (Ubuntu only)](#8-switch-off-the-crash-reporter-ubuntu-only)
9. [Reboot, then log in as sandboxer](#9-reboot-then-log-in-as-sandboxer)
10. [Check the account](#10-check-the-account)
11. [Get the sandbox](#11-get-the-sandbox)
12. [Run the doctor](#12-run-the-doctor)
13. [Make a keyring](#13-make-a-keyring)
14. [Store the model credential](#14-store-the-model-credential)
15. [Decide how the work gets back to GitHub](#15-decide-how-the-work-gets-back-to-github)
16. [Start your first session](#16-start-your-first-session)
17. [Bring the work out and read it](#17-bring-the-work-out-and-read-it)
18. [Push it](#18-push-it)
19. [Clean up](#19-clean-up)
20. [The next repository, and the other agent](#20-the-next-repository-and-the-other-agent)
21. [After a reboot](#21-after-a-reboot)
22. [Updating the sandbox](#22-updating-the-sandbox)

---

## 1. What you need

**A new Linux VM** that you can throw away, with one of these:

| Distribution | Versions | Notes |
|---|---|---|
| Debian | **13** (trixie) | What the real run used. Debian 12 is **too old** (its Podman is 4.3). |
| Ubuntu | **24.04 LTS** or newer | Ubuntu 22.04 is **too old** (its Podman is 3.4). |
| Fedora | **41** or newer (Server or Cloud) | |

Size: **4 CPU cores, 8 GB of memory, 50 GB of disk.** 20 GB of the disk
becomes the store where sessions keep their work. With the defaults one
session can take about 6.6 GB of memory, so 8 GB fits one session at a time.
Give it **16 GB** if you want two sessions running at once.

Any provider works: a cloud VM (Hetzner, DigitalOcean, AWS, Azure, GCP...) or
one on your own machine (Proxmox, VirtualBox, VMware, UTM...). When you make
the VM, give it **your SSH public key**, so you can log in with a key rather
than a password. Most providers ask for one when the VM is created.

**On your workstation:**

- An SSH client (`ssh` is built in on Linux, macOS and Windows 10 or newer).
- An SSH key. If you do not have one, make one: `ssh-keygen -t ed25519`, and
  press Enter at every question. The public half is `~/.ssh/id_ed25519.pub`;
  that is what you give the VM provider.
- A browser.
- For Claude: **Claude Code** installed (step 14 says how).
- For Codex: the **Codex CLI** installed (step 14 says how).

**Accounts:**

- A **dedicated** Claude Pro or Max account, or a dedicated ChatGPT account
  with Codex, used only for the sandbox. Not your everyday account. Switch
  **extra usage / overage billing off** on it, so the most an agent can spend
  is the plan you have already paid for. (An API key from a dedicated
  workspace with a spend limit works too; see
  [03 — Credentials](03-credentials.md).)
- A GitHub (or GitLab) repository you want the agent to work on.

## 2. Make the VM and log in

Make the VM with your provider, with the distribution and size above and your
SSH key. Note its **IP address**.

**workstation:**

```bash
ssh <admin-user>@<vm-address>
```

`<admin-user>` is the user the image came with: usually `debian` on Debian,
`ubuntu` on Ubuntu, `fedora` on Fedora, and sometimes `root`. Your provider's
page for the VM says which.

The first time, ssh asks `Are you sure you want to continue connecting
(yes/no/[fingerprint])?`. Type `yes` and press Enter.

**Never** connect with `ssh -A` (agent forwarding), to this VM or to any host
running the sandbox. It would put your workstation's SSH key within reach of
the VM.

> If your image only gave you `root`, everything in steps 3 to 8 works the
> same: you can leave out `sudo`, or keep it, it does no harm.

## 3. Install the packages

**VM, admin.** Bring the system up to date first, then install what the
sandbox needs.

**Debian 13:**

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y podman netavark aardvark-dns uidmap slirp4netns passt catatonit \
  dbus-user-session git jq openssl curl ca-certificates tmux \
  libsecret-tools gnome-keyring python3-gi
```

**Ubuntu 24.04 or newer:** the same, after turning on the `universe`
component, where Podman lives:

```bash
sudo add-apt-repository -y universe
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y podman netavark aardvark-dns uidmap slirp4netns passt catatonit \
  dbus-user-session git jq openssl curl ca-certificates tmux \
  libsecret-tools gnome-keyring python3-gi
```

If a screen titled *Daemons using outdated libraries* or *Pending kernel
upgrade* appears, press Enter to accept it; step 9 reboots anyway.

**Fedora 41 or newer:**

```bash
sudo dnf upgrade -y
sudo dnf install -y podman git jq openssl curl tmux \
  libsecret gnome-keyring python3-gobject policycoreutils-python-utils
```

What each piece is for:

| Package | Why |
|---|---|
| `podman` | Runs the containers, as your ordinary user, with no background service running as root. 4.4 or newer is needed. |
| `netavark`, `aardvark-dns` | Podman's network backend. The sandbox needs it for a network with no route out. |
| `uidmap`, `slirp4netns`, `passt`, `catatonit` | Let Podman run as an ordinary user and give its containers networking. (Fedora's `podman` brings them along.) |
| `dbus-user-session` | Gives an SSH login its own D-Bus, which Podman's resource limits and the keyring need. (Built in on Fedora.) |
| `git`, `jq`, `openssl`, `curl` | Used by the launcher on the host. |
| `tmux` | Keeps the agent running if your SSH connection drops. Optional, but you will be glad of it. |
| `libsecret-tools` / `libsecret`, `gnome-keyring`, `python3-gi` / `python3-gobject` | The keyring the model credential is kept in between sessions (step 13). |
| `policycoreutils-python-utils` (Fedora) | `semanage`, used in step 6 to label the disk store for SELinux. |

## 4. Make the sandbox account

If a kernel bug ever lets an agent out of its container, it lands in the
account that started the container. So the sandbox runs from an account that
**cannot become root**: no `sudo`, no password. The user you are logged in as
now has `sudo`, so it must not be that one.

`./sandbox` refuses to run as root, with no way to override it.

**VM, admin.** Make the account. On **Debian or Ubuntu:**

```bash
sudo adduser --disabled-password --gecos "" sandboxer
```

On **Fedora:**

```bash
sudo useradd --create-home sandboxer
```

Then, on **all three**:

```bash
# Let its containers keep running when you are not logged in, and give it a
# user session that starts at boot.
sudo loginctl enable-linger sandboxer

# Let yourself log in as sandboxer with the same SSH key you just used.
sudo install -d -m 700 -o sandboxer -g sandboxer /home/sandboxer/.ssh
sudo install -m 600 -o sandboxer -g sandboxer ~/.ssh/authorized_keys /home/sandboxer/.ssh/authorized_keys
```

If the last line says `No such file or directory`, you are logged in as root
and the key is somewhere else. Use `/root/.ssh/authorized_keys` in its place.

On **Fedora** only, give those files the label SSH expects:

```bash
sudo restorecon -R /home/sandboxer/.ssh
```

**Check** that the account got a range of spare user ids, which rootless
Podman needs:

```bash
grep sandboxer /etc/subuid /etc/subgid
```

You should see two lines, like `/etc/subuid:sandboxer:165536:65536` and the
same for `/etc/subgid`. The numbers may differ. If nothing is printed, add a
range:

```bash
sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 sandboxer
```

## 5. Let that account set resource limits

Every session has limits on memory, CPU and the number of processes, and the
kernel enforces them through cgroups. systemd has to hand those controls to
ordinary users. Recent versions hand over most of them by default; this makes
sure all of them are handed over. It is harmless if they already are.

**VM, admin:**

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload
```

`tee` prints the two lines it wrote. That is all it should print.

## 6. Make the disk store

Sessions keep their workspaces on a **disk store**: a filesystem of fixed
size, made only for this. A session that fills it gets "no space left on
device", and the VM's own disk is not touched. 20 GB here, which is the most
all sessions together can put on disk. It can be larger if your disk is.

**VM, admin.** Run these one at a time:

```bash
sudo fallocate -l 20G /var/lib/agent-sandbox-store.img
sudo mkfs.ext4 -q -m 0 /var/lib/agent-sandbox-store.img
sudo mkdir -p /var/lib/agent-sandbox-store
echo '/var/lib/agent-sandbox-store.img /var/lib/agent-sandbox-store ext4 loop,nosuid,nodev,nofail 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /var/lib/agent-sandbox-store
sudo chown sandboxer: /var/lib/agent-sandbox-store
```

What they do: make a 20 GB file, put a filesystem in it, make the folder it
is opened at, have it opened at every boot (the `/etc/fstab` line), open it
now, and give it to `sandboxer`.

Run the `echo ... | sudo tee -a /etc/fstab` line **once**. Running it twice
adds the line twice; if that happens, open `/etc/fstab` with
`sudo nano /etc/fstab` and delete one of them.

On **Fedora** only, label the store so containers may write to it (SELinux
otherwise refuses, because `/var/lib` is not meant for containers):

```bash
sudo semanage fcontext -a -t container_file_t '/var/lib/agent-sandbox-store(/.*)?'
sudo restorecon -R /var/lib/agent-sandbox-store
```

**Check:**

```bash
df -h /var/lib/agent-sandbox-store
```

Good: one line under the header, with `Size` about `20G` and `Filesystem` a
`/dev/loop...` device. Bad: the `Filesystem` is the VM's main disk (such as
`/dev/sda1` or `/dev/vda1`). Then the `mount` line did not work; read its
error.

`./sandbox` finds a store at this exact path by itself; there is nothing to
configure.

## 7. Install gitleaks

When you bring the agent's work out, `export` scans it for secrets (keys,
tokens) with **gitleaks**. Without it, `export` still works but `push` and
`pr` refuse. Version **8.18 or newer** is needed, and Debian's package is
older (8.16), so take the release from the gitleaks project and check its
checksum.

**VM, admin.** All three distributions:

```bash
cd "$(mktemp -d)"
case "$(uname -m)" in
  x86_64)  arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) echo "unknown processor: $(uname -m)" ;;
esac
v=8.30.1
curl -fsSLO "https://github.com/gitleaks/gitleaks/releases/download/v$v/gitleaks_${v}_linux_${arch}.tar.gz"
curl -fsSLO "https://github.com/gitleaks/gitleaks/releases/download/v$v/gitleaks_${v}_checksums.txt"
grep "linux_${arch}.tar.gz" "gitleaks_${v}_checksums.txt" | sha256sum -c
```

The last line must print `gitleaks_8.30.1_linux_x64.tar.gz: OK` (or `arm64`).
If it prints `FAILED`, **stop**: the download is not what the project
published. Delete it and try again later.

Then install it for everyone on the VM:

```bash
tar -xzf "gitleaks_${v}_linux_${arch}.tar.gz" gitleaks
sudo install -m 755 gitleaks /usr/local/bin/gitleaks
cd ~
gitleaks version
```

Good: it prints `8.30.1`.

## 8. Switch off the crash reporter (Ubuntu only)

Ubuntu sends every program crash to its crash reporter, `apport`. The kernel
starts it **as root, on the host**, for every crash, including crashes inside
a container. `doctor` warns about that. Skip this step on Debian and Fedora.

**VM, admin, Ubuntu only:**

```bash
cat /proc/sys/kernel/core_pattern
```

If it prints something starting with `|/usr/share/apport/`, switch it off:

```bash
sudo systemctl disable --now apport.service
echo 'kernel.core_pattern=core' | sudo tee /etc/sysctl.d/60-agent-sandbox-core.conf
sudo sysctl --system >/dev/null
cat /proc/sys/kernel/core_pattern     # now prints: core
```

## 9. Reboot, then log in as sandboxer

The update in step 3 may have brought a new kernel, and a reboot also proves
the disk store comes back by itself.

**VM, admin:**

```bash
sudo reboot
```

Your SSH connection closes. Wait a minute.

**workstation.** From now on you log in **as `sandboxer`**, not as the admin.
To save typing, add this to the file `~/.ssh/config` on your workstation
(make the file if it does not exist; on Windows it is
`C:\Users\<you>\.ssh\config`):

```
Host sandbox
    HostName <vm-address>
    User sandboxer
    ForwardAgent no
```

Then:

```bash
ssh sandbox
```

Always log in this way, over SSH, straight as `sandboxer`. **Do not** log in
as the admin and then use `su sandboxer` or `sudo -u sandboxer`: that gives
no proper login session, and Podman's limits and the keyring then do not
work.

## 10. Check the account

**VM, sandboxer.** Each line, and what it must say:

```bash
whoami                      # sandboxer
id                          # no "sudo", "wheel" or "admin" in the groups list
sudo -n true                # must FAIL: "a password is required" or "not in the sudoers file"
echo "$XDG_RUNTIME_DIR"     # /run/user/ and a number, such as /run/user/1001
df -h /var/lib/agent-sandbox-store    # about 20G again, after the reboot
podman info --format '{{.Host.Security.Rootless}} {{.Version.Version}} {{.Host.NetworkBackend}}'
```

The last line must print `true`, a version of 4.4 or higher, and `netavark`,
for example `true 5.4.2 netavark`.

- If `XDG_RUNTIME_DIR` is empty, you did not log in over SSH as `sandboxer`.
  Log out and do step 9 again.
- If the backend says `cni` instead of `netavark`, tell Podman to use
  netavark. This account has no containers yet, so the reset loses nothing:

  ```bash
  mkdir -p ~/.config/containers
  printf '[network]\nnetwork_backend = "netavark"\n' > ~/.config/containers/containers.conf
  podman system reset --force
  podman info --format '{{.Host.NetworkBackend}}'     # now: netavark
  ```

- If `podman info` prints an error instead, read its first line; the most
  common ones are in [07 — Troubleshooting](07-troubleshooting.md).

## 11. Get the sandbox

**VM, sandboxer:**

```bash
git clone https://github.com/Grumbly4308/agent-sandbox-bundle.git ~/agent-sandbox
cd ~/agent-sandbox
```

**Every `./sandbox` and `scripts/...` command from here on is run in
`~/agent-sandbox`.** If you log in again later, run `cd ~/agent-sandbox`
first.

Tell git who you are. The agent's commits carry this name and address, and
without them its commits fail:

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

Use the name and email you use on GitHub, so the commits are linked to you.

**Pin the base images.** The sandbox builds its images from base images named
by an exact digest, so that nobody can swap their contents under you. The
digests cannot be known ahead of time, so the files ship with `UNPINNED` and
every build refuses until you run this, once:

```bash
scripts/pin-images.sh
```

It downloads each base image and prints one `old -> new` line for each,
then `pin-images: done. Review with 'git diff', then commit.` You do not need
to commit anything: the files are now right for this VM.

## 12. Run the doctor

**VM, sandboxer:**

```bash
./sandbox doctor
```

It prints one line per check: `ok`, `warn` or `FAIL`, with a one-line `fix:`
under every `FAIL`. It ends with either `This host is ready.` or
`Not safe to run yet: fix the FAIL lines above.`

**Every `FAIL` must be fixed** before the sandbox will run. Copy the `fix:`
line, run it (some need the admin account: log in as the admin in a second
terminal for those), then run `./sandbox doctor` again.

Some `warn` lines are expected at this point:

| `warn` line | What to do |
|---|---|
| `no SELinux on this host, and rootless Podman applies no AppArmor profile: barrier B05 is absent here` | Nothing. Normal on Debian and Ubuntu. On Fedora, where SELinux is on, this line is `ok`. |
| `your account has no keyring` | Step 13 fixes it. |
| `crashes are piped to ...` | On Ubuntu: step 8 was skipped. Elsewhere: run the command it names. |
| `gitleaks is not installed` or `gitleaks ... is too old` | Step 7 was skipped or did not work. |
| `no disk store is set up` | Step 6 did not work. `df -h /var/lib/agent-sandbox-store` says what is there. |

The `FAIL`s you might see on a new VM:

| `FAIL` line | Fix |
|---|---|
| `cgroup v2, but your user may not set limits for: ...` | Step 5 was skipped. Do it as admin, then log out of `sandboxer` and back in. |
| `your subordinate UID range does not reach 61003` | As admin: `sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 sandboxer`; then, as sandboxer, `podman system migrate`. |
| `images/PINS still has UNPINNED base images` | Step 11: `scripts/pin-images.sh`. |
| `Podman ... is too old` | The distribution is too old; see step 1. |

## 13. Make a keyring

The model credential is kept in your account's **keyring** between sessions,
so you paste it once and not at every run. On a desktop, the login screen
makes and opens the keyring. An account reached only over SSH has none, and
the usual tools can only make one through a pop-up window, which there is no
screen for. This script does it without one.

**VM, sandboxer:**

```bash
scripts/keyring-unlock.py
```

It asks: `Choose a password for the new keyring:`. Type a new password (it
does not show as you type) and press Enter. It asks **only once**, with no
second prompt to catch a typo, so it is easiest to paste one from your
password manager. **Keep this password**: after every reboot the keyring is
locked again, and the next `./sandbox run` (or `login`) asks for it before
going on (step 21).

Good: it prints `created a keyring and made it the default` and
`the keyring is unlocked; ./sandbox login can store the credential now`.

**Check:**

```bash
./sandbox doctor
```

It should now say `ok    the keyring is unlocked`.

You can skip the keyring altogether. Then `run` asks for the model
credential every time and nothing is stored on the VM. That is a sound
choice too; [03 — Credentials](03-credentials.md#where-the-credential-rests)
weighs the two. A **Codex subscription login** does need the keyring, because
the host has to keep renewing it.

## 14. Store the model credential

The credential is made on your **workstation** (it needs a browser), then
pasted or copied to the VM. Do the part for the agent you want, or both.

### Claude Code (a Pro or Max subscription)

**workstation.** Install Claude Code if you do not have it:

```bash
# macOS, Linux or WSL
curl -fsSL https://claude.ai/install.sh | bash
# Windows (PowerShell)
irm https://claude.ai/install.ps1 | iex
```

Then:

```bash
claude setup-token
```

A browser opens. **Sign in as the dedicated sandbox account**, not your
everyday one, and approve. The terminal prints a token starting with
`sk-ant-oat01-`. It is valid for one year and can make model requests and
nothing else. Copy it.

**VM, sandboxer:**

```bash
./sandbox login
```

It asks `Paste that token:`. Paste it (right-click, or Ctrl+Shift+V in most
Linux terminals, Cmd+V on a Mac). Nothing appears as you paste; that is on
purpose. Press Enter.

It answers with where it stored the token and three things to do: use a
dedicated account, switch overage billing off, and how to revoke the token.
Read them.

### Codex (a ChatGPT plan)

Codex has no long-lived token. Its login is a file, `auth.json`, holding a
pair of tokens that the VM renews as they run out.

**workstation.** Install the Codex CLI if you do not have it (it needs
Node.js 18 or newer):

```bash
npm install -g @openai/codex
```

Sign in **as the dedicated sandbox account**, into a folder of its own so
your everyday Codex login (if you have one) is not touched:

```bash
export CODEX_HOME="$(mktemp -d)"
codex login
```

A browser opens; sign in and approve. Then copy the file to the VM and delete
it from your workstation:

```bash
scp "$CODEX_HOME/auth.json" sandbox:codex-auth.json
rm -rf "$CODEX_HOME"
unset CODEX_HOME
```

Do not keep using that login anywhere else. The VM replaces its tokens at
each renewal, and two copies that both renew knock each other out.

**VM, sandboxer:**

```bash
./sandbox login --agent codex
```

It asks `Path to that file [/home/sandboxer/.codex/auth.json]:`. Type
`/home/sandboxer/codex-auth.json` and press Enter. Once it says it is stored,
delete the file:

```bash
shred -u ~/codex-auth.json
```

## 15. Decide how the work gets back to GitHub

The agent works on a copy of your repository inside the VM. When it is done,
you bring its branch out (`export`), read it, and send it to GitHub
(`push`). Sending needs a git credential, and **where that credential lives
matters**: a breakout from a container lands in the `sandboxer` account and
takes whatever it finds there. So never put your personal SSH key or a
broad token on the VM. Choose one of these two ways **before** your first
`run`, because the first one is chosen at `run`.

### Option 1: a token for one repository, for one session

You make a token on GitHub that can reach **only this one repository**, and
type it in at `run`. It is held in memory for the session, used by the VM to
clone, push and open the pull request, never written to a file, never put in
a container, and forgotten at `destroy`. It works for public and private
repositories alike.

**workstation, in the browser**, on GitHub:

1. Click your profile picture (top right), then **Settings**.
2. At the bottom of the left menu: **Developer settings**.
3. **Personal access tokens**, then **Fine-grained tokens**, then **Generate
   new token**.
4. **Token name:** `sandbox <repo name>`. **Expiration:** 7 days (the
   shortest that fits your work).
5. **Repository access:** **Only select repositories**, and pick the one
   repository.
6. **Permissions**, under **Repository permissions:** set **Contents** to
   **Read and write**. If you want `./sandbox pr` to open the pull request,
   also set **Pull requests** to **Read and write**. Leave everything else
   alone.
7. **Generate token**, and copy it (it starts with `github_pat_`). GitHub
   shows it only once; keep it in your password manager until you are done.

On GitLab: a project access token with the `write_repository` scope, made
under the project's **Settings → Access tokens**.

You will use it in step 16 with `--git-token`.

### Option 2: no git credential on the host

The VM never holds a git credential and never talks to GitHub about your
repository. Your workstation, which already has your git credentials, sends
the code to the VM over SSH and fetches the result back.

**VM, sandboxer.** Make an empty repository for it to land in:

```bash
mkdir -p ~/repos
git init --quiet --bare --initial-branch=main ~/repos/project.git
```

**workstation**, in a clone of your repository (`git clone` it first if you
have none):

```bash
cd <your-clone>
git push sandbox:repos/project.git main
```

(`sandbox` is the name from your `~/.ssh/config` in step 9. If your main
branch has another name, such as `master`, use that name in place of `main`
in both commands: in `--initial-branch=` on the VM and in `git push` here.)

You will run the session from `~/repos/project.git` in step 16, and fetch the
result back in step 18.

## 16. Start your first session

**VM, sandboxer.** Start `tmux` first, so the agent keeps running if your SSH
connection drops:

```bash
tmux new -s sandbox
cd ~/agent-sandbox
```

If the connection drops, `ssh sandbox` and then `tmux attach -t sandbox` puts
you back where you were. (`tmux` in one line: Ctrl+B then D leaves it running
in the background; `tmux attach -t sandbox` comes back.)

Now start the session. **Option 1** (a token):

```bash
./sandbox run https://github.com/<you>/<project>.git --git-token
```

It asks `A git token that can read and push that one repository and nothing
else:`. Paste the `github_pat_...` token (nothing appears) and press Enter.

**Option 2** (no git credential):

```bash
./sandbox run ~/repos/project.git
```

For **Codex** instead of Claude, add `--agent codex` to either line.

What you see, in order:

1. `This session may use up to ... of this host's memory:` and how that adds
   up, then `Its workspace is on disk: up to 4g of the store at
   /var/lib/agent-sandbox-store.`
2. `cloning ... on this host`. The repository is cloned **on the VM** and
   handed to the sandbox as a single file; the sandbox never sees a git
   credential.
3. **The first time only:** the images are built. Many screens of build
   output, for 10 to 20 minutes. Let it run. Later sessions skip this.
4. `creating session asb-<project>-<six characters>`. **That is the
   session's name.** Note it down.
5. `checking the barriers (verify --quick)`, then about 70 lines of `PASS`.
   This happens the first time, and again after anything changes (images,
   Podman, kernel). If any line says `FAIL`, the session is not started; read
   the line and [07 — Troubleshooting](07-troubleshooting.md). **Do not work
   around it.**
6. `Session asb-... has no time limit (it runs until you destroy it), at most
   500 model requests.` (With `--ttl`, `runs until <time>` instead.)
7. The agent: Claude Code or Codex, with **no login prompt**. If it asks a
   first-time question (a colour theme, whether to trust this folder),
   answer it.

From here on everything on the screen comes from the agent. **Never type a
password or token into it.**

Give it a task, and **always end with "and commit it"**: only committed work
comes out of the session. For example:

> Read the README and fix the first typo you find. Commit it.

By default the agent asks before running commands; answer its questions. To
let it act without asking, start the session with `--auto` (the container
is the boundary either way; see
[05 — Agents and toolchains](05-agents-and-toolchains.md#--auto)).

When it is done, leave the agent: type `/exit` (Claude Code) or `/quit`
(Codex) and press Enter. You are back at the VM's prompt, and the session is
still there with its work. Nothing is lost until you destroy it. To get back
in, with the same workspace:

```bash
./sandbox resume
```

The agent starts again in the same repository. The conversation it had is
kept while its container lives (Claude Code: `./sandbox resume -- --continue`
picks it up); after a reboot or the time limit the container is started
afresh and only the files remain, so ask the agent to write anything you want
to keep (a review, notes) **into a file in the repository**.

Other options for `run`:

| Option | What it does |
|---|---|
| `--agent claude\|codex\|opencode` | Which agent. Default `claude`. |
| `--auto` | The agent acts without asking you. |
| `--toolchain node\|python\|full` | What is installed in the image. Default `node`; `full` adds build tools and a browser. |
| `--service postgres:16` | Start a database beside the agent. See [06](06-services.md). |
| `--ttl 2h` | A time limit, after which Podman stops the session's containers (the work stays, and `resume` starts them again). By default there is **none**: the session runs until you destroy it. `TTL=` in your settings file makes one the default. |
| `--budget 200` | How many model requests the session may make. Default 500. |
| `--mem 4g --cpus 2 --pids 512` | Resource limits. |
| `--workspace-size 10g` | This session's share of the disk store. Default 4 GB. |
| `--branch <name>` | Work on that branch. If it exists, carry on from it. See [09](09-sessions.md#carrying-on-from-another-agent). |
| `--git-token` | Option 1 from step 15. |
| `-- <args>` | Everything after `--` goes to the agent unchanged, such as `-- -p "fix the tests"`. |

## 17. Bring the work out and read it

**VM, sandboxer:**

```bash
./sandbox export
```

This brings the session's branch out as a clean repository at
`~/agent-sandbox-out/<session>/repo.git` and prints, in this order:

1. **Commits**: every commit the agent made.
2. **The code diff**: what changed.
3. **RUNS LATER**: changed files that will be **run** on your machine or in
   CI after you merge: lockfiles, dependency lists, CI workflows, build
   scripts, git hooks. **Read this section first and most carefully.** A
   hostile agent's best move is to plant something here, and it is the one
   attack the sandbox cannot stop for you.
4. **The secret scan**: `secret scan: passed` is what you want.
5. A summary.

To look again later, or more closely:

```bash
git --git-dir ~/agent-sandbox-out/<session>/repo.git log --stat
git --git-dir ~/agent-sandbox-out/<session>/repo.git show
```

## 18. Push it

**Option 1** (a token). **VM, sandboxer:**

```bash
./sandbox push      # pushes the branch agent/<session> to GitHub, from the clean copy
./sandbox pr        # push, then open the pull request
```

`pr` opens the request itself if `gh` (GitHub) or `glab` (GitLab) is
installed on the VM; otherwise it prints a link to open it in your browser.

`push` refuses if the secret scan did not pass, if an AI attribution line
could not be removed from a commit, or if the agent rewrote history below
where it started. [07 — Troubleshooting](07-troubleshooting.md#export) says
what to do for each.

**Option 2** (no git credential). **workstation**, in your clone:

```bash
git fetch sandbox:agent-sandbox-out/<session>/repo.git agent/<session>
git log -p FETCH_HEAD -3        # read it here too, if you like
git push origin FETCH_HEAD:refs/heads/agent/<session>
```

Then open the pull request on GitHub as usual. (`./sandbox push` and `pr` are
not used this way.)

## 19. Clean up

**VM, sandboxer:**

```bash
./sandbox destroy
```

The session's containers, networks, workspace and files are removed, and the
`--git-token` token is forgotten. What stays: the images (so the next run
starts fast), the stored model credentials, your settings, and the export in
`~/agent-sandbox-out/`. Delete old exports yourself when you are done with
them:

```bash
rm -rf ~/agent-sandbox-out/<session>
```

A session you forget keeps its workspace, even after a time limit has cut it
off from everything else. Every `./sandbox` command reminds you which
sessions are still there, and `./sandbox resume` gets back into one.

If you made a GitHub token for option 1, delete it on GitHub when you are
done (**Settings → Developer settings → Personal access tokens →
Fine-grained tokens**), or let it expire.

## 20. The next repository, and the other agent

[09 — Sessions](09-sessions.md) covers this in full. In short:

**Another repository:** `export`, `destroy`, then `run` the next one. Steps
16 to 19, again. Nothing carries over from one session to the next except the
images and the stored credentials.

**Two repositories at once:** run two sessions, each in its own `tmux`
window (Ctrl+B then C opens a new one). With more than one session, the other
commands need to be told which one:

```bash
SANDBOX_SESSION=asb-frontend-1a2b3c ./sandbox export
```

**The other agent, from scratch:** a new session with `--agent codex` (or
`--agent claude`). Store its credential first (step 14).

**The other agent, carrying on from the first one's work.** A session starts
from the repository as it is when you `run` it, so the first agent's work has
to come out first. Two ways:

- **Option A, through the remote** (needs option 1 from step 15):

  ```bash
  ./sandbox export && ./sandbox push      # Claude's branch is now on GitHub
  ./sandbox destroy
  ./sandbox run https://github.com/<you>/<project>.git --agent codex \
      --branch agent/<first session> --git-token
  ```

- **Option B, straight from the export** (nothing is pushed in between;
  works with either option from step 15):

  ```bash
  ./sandbox export                        # read it
  ./sandbox destroy                       # the export stays
  ./sandbox run ~/agent-sandbox-out/<first session>/repo.git --agent codex \
      --branch agent/<first session>
  ```

`--branch` with the first session's branch makes the second agent carry on
from the first one's last commit. Read the first export, RUNS LATER above
all, before the second agent starts building on it.
[09 — Sessions](09-sessions.md#carrying-on-from-another-agent) has both ways
in full, including how to push the result of option B, from your workstation
or from the VM with `--git-token`.

## 21. After a reboot

**VM, sandboxer**, after `ssh sandbox`:

```bash
cd ~/agent-sandbox
./sandbox doctor                # should end with: This host is ready (a locked keyring is a warning, not a failure)
./sandbox resume                # back into the session you had
```

The keyring is locked again after a reboot. `resume` (like `run` and
`login`) notices and asks `Keyring password:` first: type the step 13
password. Nothing else is needed.

A reboot stops every session's containers, but the sessions themselves
survive: their workspaces on the disk store, and what `./sandbox` knows about
them. `resume` starts the containers again and puts you back in. What a
reboot does lose is everything held in memory: the agent's home directory
(its conversation, caches, settings it changed), `/tmp`, a sibling service's
data, and a workspace that was in memory because there was no disk store
(`resume` then refuses, and says so). Exports in `~/agent-sandbox-out/`
survive too.

To remove sessions you no longer need instead:

```bash
./sandbox destroy --all        # or SANDBOX_SESSION=<name> ./sandbox destroy, one at a time
```

If you still needed a workspace that was not exported, read
[07 — Troubleshooting](07-troubleshooting.md#getting-back-into-a-session)
**before** running that.

## 22. Updating the sandbox

**VM, sandboxer:**

```bash
cd ~/agent-sandbox
git checkout -- images/PINS services agents   # drop this VM's pins; they are made again below
git pull
scripts/pin-images.sh
./sandbox upgrade                        # pin each agent CLI to npm's latest, rebuild every image from scratch, show old -> new
./sandbox doctor
```

`upgrade` moves the CLI pins (version and package hashes in
`agents/<agent>/install.sh`) to what npm calls `latest`, for the agents whose
images exist here, then rebuilds. The hashes it writes are what the build
verifies every tarball against, so `git diff agents` shows exactly what the
next build will trust. `./sandbox upgrade --keep-clis` rebuilds from the
pins as they are, without asking the registry.

## The whole thing, once more

Once the VM is set up (steps 1 to 14), a session is:

```bash
ssh sandbox
tmux new -s sandbox            # or: tmux attach -t sandbox
cd ~/agent-sandbox
./sandbox run https://github.com/<you>/<project>.git --git-token
#   ... give the agent a task; "commit it"; /exit ...
./sandbox export               # read it: RUNS LATER first
./sandbox push                 # or ./sandbox pr
./sandbox destroy
```

## Commands

| Command | What it does |
|---|---|
| `./sandbox doctor` | Is this host safe to run on? |
| `./sandbox login [--agent A]` | Store the model credential in your keyring |
| `./sandbox run <repo>` | Start a session and attach to the agent |
| `./sandbox resume` | Back into the session: after the agent exited, a time limit, or a reboot |
| `./sandbox shell` | A shell inside the agent container |
| `./sandbox verify` | Attempt every bypass in the barrier register |
| `./sandbox allow <host> --reason "<why>"` | Let the agent reach one more host. See [02](02-egress.md) |
| `./sandbox deny <host>` | Take it off again |
| `./sandbox logs [agent\|proxy\|sidecar\|relay\|service]` | What each container printed |
| `./sandbox export [--commit]` | Bring the branch out and review it; `--commit` first commits what the agent left uncommitted |
| `./sandbox push` / `./sandbox pr` | Send the reviewed branch to the repository |
| `./sandbox destroy [--all]` | Remove the session, or every session |
| `./sandbox upgrade [--keep-clis]` | Pin each agent CLI to npm's latest, rebuild the images from scratch and show old → new versions |

With more than one session, put `SANDBOX_SESSION=<name>` in front of any
command but `run`. See [09 — Sessions](09-sessions.md).

## macOS

The sandbox also runs on a Mac, but that has not been tried yet (see
[08 — Verification](08-verification.md)). Podman runs its containers in a
small Linux VM there, and there is no disk store, so workspaces are held in
memory:

```bash
brew install podman git jq
podman machine init --memory 12288
podman machine start
```

Then continue from step 11 on the Mac itself. Or, simpler and better
isolated: make a Linux VM on the Mac (`extras/vm-wrapper/` has recipes for
Lima and Multipass) and follow this page inside it.

Next: [02 — Egress](02-egress.md).
