# Running the whole sandbox in a throwaway VM (optional)

Two example recipes for a virtual machine that exists for one job and is
then deleted: `agent-sandbox.yaml` for [Lima](https://lima-vm.io) (macOS and
Linux) and `cloud-init.yaml` for [Multipass](https://multipass.run) (macOS,
Linux, Windows). Both give you Ubuntu 26.04 with rootless Podman and an
unprivileged user called `sandbox`.

**Untested.** Neither file has been started by the authors: there was no
Lima, Multipass or Podman on the machine they were written on. Treat them as
a starting point, and run `./sandbox doctor` in the VM before anything else;
it checks every condition the sandbox depends on and says how to fix what is
missing.

## What a VM adds

**A second kernel.** A container is a group of processes on your host's
kernel. Every barrier in [the threat model](../../docs/00-threat-model.md)
that is marked *physical* is that kernel keeping its word, and a kernel bug
the agent can reach is the one thing the sandbox does not claim to stop.
Inside a VM, such a bug gets the agent out of the container and into the
VM's kernel, not yours. To reach your machine it would then need a second,
different bug in the virtual machine software.

What it lands in is a machine set up to be worthless:

- **no folder of yours** is mounted (`mounts: []`; Multipass mounts none
  unless asked);
- **no SSH agent** is forwarded and none of your keys are copied in;
- **no ports** are forwarded to your host;
- **no credential is stored in it** (next section).

It does not add anything against the threats the sandbox already handles
(the allowlist, the credential sidecar, export), and it costs memory: the VM
is given 12 GB so that one default session (up to 10 GB) fits.

## The three commands

Lima:

```sh
limactl start --name=agent-sandbox ./agent-sandbox.yaml    # create
limactl shell agent-sandbox sudo -iu sandbox               # enter, as the unprivileged user
limactl delete --force agent-sandbox                       # delete, with everything in it
```

Multipass:

```sh
multipass launch 26.04 --name agent-sandbox --cpus 4 --memory 12G --disk 30G --cloud-init cloud-init.yaml
multipass exec agent-sandbox -- sudo -iu sandbox
multipass delete --purge agent-sandbox
```

You enter through the VM's default user and step down to `sandbox` at once.
The default user has passwordless `sudo`, and the sandbox refuses to run as
a user who can become root; `sandbox` cannot.

Getting things in and out, since nothing is mounted (Lima shown; Multipass
has `multipass transfer`):

```sh
limactl copy -r ./agent-sandbox agent-sandbox:/tmp/agent-sandbox      # this repository, in
limactl copy -r agent-sandbox:/tmp/out ./from-the-vm                  # an export, out
```

Inside the VM, copy from and to `/tmp` as `sandbox`. A public repository can
be given to `./sandbox run` by URL. For a private one, copy a clone in and
give `run` the path: the VM has no credential to clone it with, and should
not get one. Push from your own machine, from the exported copy, after
reading the diff.

## Where the credential is

Still outside. The VM starts with no model login, no git token and no SSH
key, and none of the files above contains or asks for one.

- `./sandbox run` in the VM finds no stored credential and **asks for it on
  the terminal**. What you paste is piped into the credential sidecar and
  kept in that container's memory for the session. It is never written to
  the VM's disk, and it is gone when the session is destroyed.
- **Nothing is stored in the VM unless you run `./sandbox login` there.**
  That puts the credential in the VM's keyring, which defeats the point;
  paste it per session instead.
- The exception is a Codex subscription login: the launcher has to renew it
  during a session and reads it from the keyring to do so, so it needs
  `login`, and then the login is in the VM until you delete the VM. Use an
  API key, or Claude's inference-only token, if you want nothing stored.
- With `--git-relay` the git token is asked for the same way and held only
  by the relay container.

So during a session the credential exists in the VM's memory, inside the
sidecar. An agent that broke out of its container, through the VM's kernel,
could reach it there. What it could not reach is anything on your machine.

## When you are done

Export, copy the result out, then delete the VM. Do not keep one around: a
VM that has run untrusted code is as trustworthy as that code.
