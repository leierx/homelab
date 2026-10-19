# pi on loft01

The pi coding agent runs on loft01, so a long task does not depend on the
workstation staying awake. It runs as `leier` on the host, unsandboxed: it
can do everything `leier` can, including `doas` and the admin kubeconfig.
That is deliberate; see "Deliberate, don't fix" in `AGENTS.md`.

## Connect

From the workstation:

```sh
ssh -t -o ClearAllForwardings=yes loft01 tmux new-session -A -s pi pi
```

`-A` attaches to the session named `pi` if it exists, otherwise creates it.
`Ctrl-b d` detaches; the session and whatever pi is running keep going.
`-o ClearAllForwardings=yes` skips the workstation's kube-apiserver forward.

## First login

The first start has no model: run `/login` inside pi and finish the
provider's login (OAuth or an API key). The credentials go to
`/home/leier/.pi/agent/auth.json` on loft01, not to git. `/login` is also
where to add another provider later.

## Where things live

| What | Where |
| --- | --- |
| settings, system prompt, commit-style skill | `nixos/pi.nix` and `nixos/pi/`, symlinked from the Nix store into `/home/leier/.pi/agent/` |
| logins, sessions, npm packages | `/home/leier/.pi/agent/`, written by pi, not in git |

Only those three config files are symlinked; the rest of `~/.pi/agent/` is
pi's own state. The npm packages listed under `packages` in the settings
install into `~/.pi/agent/npm/` on first start.

## Change the settings

Edit the `settings` attrset in `nixos/pi.nix` (or the files under
`nixos/pi/`), commit and push, then deploy the host with the pinned rev as
`AGENTS.md` describes:

```sh
ssh loft01 "doas nixos-rebuild switch --flake 'git+https://github.com/leierx/homelab.git?ref=main&rev=<full sha>#loft01'"
```

A running pi keeps its old settings; the next start reads the new ones.

## Reboots

The host auto-upgrades from `main` on Fridays from 02:00 and may reboot
until 04:00. A reboot ends the tmux session and any agent running in it;
logins, sessions and npm packages survive. Run the ssh command again after
the reboot.
