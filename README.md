# hermes-vm

Run [Hermes Agent](https://github.com/NousResearch/hermes-agent) on your Mac inside an isolated, hardened
virtual machine. The VM can reach the internet and your local Ollama model, and **nothing else**: not your
Mac's files, not its other services, and not any device on whatever network you're connected to.

```bash
git clone https://github.com/synick/hermes-agent-vm.git
cd hermes-agent-vm
./hermes-vm.sh
```

That one command checks your Mac and asks every question up front, then works through four stages. It records
where it got to, so if anything fails, fix the cause and run `./hermes-vm.sh` again: it carries on from that point,
not from the start. Once everything is set up, the same command just starts both VMs headless.

1. **Base install** (about 10 minutes, unattended, no sudo): Packer installs Ubuntu in two VMs at the same time on
   Fusion's ordinary default network, the Hermes VM and a small router VM, then compacts their disks. Snapshot
   `base`. (The router's output goes to `~/.config/hermes-vm/build/router-build.log`. On a Mac with 16 GB or less,
   build one at a time with `HERMES_VM_SEQUENTIAL=1 ./hermes-vm.sh`.)
2. **Provision** (10-20 minutes, unattended): updates, hardening, rootless Docker and Hermes, run as separate steps
   over SSH. Each finished step is recorded inside the VM; a failed step can be retried on the spot, or the next
   run resumes from it. Snapshot `provisioned`.
3. **Lockdown** (a few minutes, needs sudo on the Mac): puts Hermes on a private network that only the router VM
   shares, makes the router its one way out, switches on the Ollama gateway and both VMs' firewalls, takes clean
   snapshots, and **tests the isolation**.
4. **Run:** headless, at the size you configured (default 2 vCPU / 4 GB for Hermes, 1 vCPU / 1 GB for the router).

Nothing untrusted runs before lockdown, so stages 1 and 2 use a normal network. sudo inside the VMs uses the admin
password from your Keychain, piped over SSH: you never type or paste it.

Hermes only gets started, and only gets credentials, after lockdown passes.

> Not affiliated with Nous Research. Hermes is theirs; this repo just gives it a safer place to run.

## Why

An AI agent that browses the web, reads email or installs packages will eventually read something hostile.
Prompt injection can turn the agent against the machine it runs on. A container alone shares your kernel,
and Hermes's own Docker backend doesn't confine the agent process itself. So hermes-vm stacks several layers
and assumes each one might fail:

```
Hermes VM ──[isolated Fusion network: Hermes + router only; the Mac is not on it]── router VM ──[Fusion NAT]── internet
                                                                                        │
                                       port forward, one port ──> Caddy gateway on the Mac ──> Ollama (127.0.0.1)

Router VM ── the boundary: internet yes; the Ollama gateway yes; the Mac, your LAN, any private range no
 Hermes VM ── no shared folders/clipboard/drag-drop; hardened Ubuntu; its own nftables firewall
  └─ rootless Docker ── user 'hermes': no sudo, no password, no SSH; no root Docker daemon
      └─ Hermes container ── capabilities dropped, no-new-privileges, resource limits, digest-pinned image
Your Mac ── pf firewall on the router's uplink: only the gateway port; Caddy allowlists 6 Ollama paths
```

Why a router VM rather than firewall rules on the Mac: VMware Fusion's NAT runs as a userspace helper
(`vmnet-natd`) that makes the VM's outbound connections itself, so to the Mac's pf they look like the Mac's own
traffic and per-VM "no local networks" rules never see them. The router VM filters Hermes's traffic before it
reaches Fusion's NAT, and root inside Hermes can't change the router's rules.

## Requirements

- An Apple Silicon Mac, macOS 14 or later
- [VMware Fusion](https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion) 13 or later (free for personal use)
- [Homebrew](https://brew.sh). The script offers to install Packer, Caddy, OpenSSL 3 and GnuPG.
- [Ollama](https://ollama.com) with at least one model pulled (e.g. `ollama pull qwen3:14b`)
- About 70 GB of free disk space, and 3 GB of downloads for the Ubuntu ISO

## What it asks you

Up front, you see the full set of settings below, with these defaults. Press **Enter** to accept them, or **e** to
step through and change any of them (Enter keeps each value). If a default can't work on your Mac (for example, no
Ollama model is pulled yet, or the subnet is already in use), it says why and takes you straight to editing.
After that, you only choose a password and an SSH key passphrase.

| Question | Default |
| --- | --- |
| VM name, vCPUs, memory, disk | `hermes-vm`, 2, 4 GB (3 GB minimum; the container gets 1 GB less), 60 GB |
| Admin username inside the VM | `vmadmin` |
| Timezone | detected from your Mac |
| Ubuntu version / existing ISO | `26.04.1`, or download it |
| Hermes network (isolated) | first free `vmnetN`, `172.16.42.0/24` (router `.1`, Hermes `.10`) |
| Router uplink (Fusion NAT) | next free `vmnetN`, `172.16.43.0/24` (Mac `.1`, router `.10`) |
| Ollama gateway port | `11435` |
| Model | first model in `ollama list` |
| VM admin password | **you choose it**: stored in your macOS Keychain |
| SSH key passphrase | **you choose it**: stored in your macOS Keychain |

Run `./hermes-vm.sh configure` any time to review or change them.

## Where things are stored

| What | Where | Protection |
| --- | --- | --- |
| VM admin password | macOS login Keychain, service `hermes-vm` | Keychain; never written to disk by these scripts |
| SSH key | `~/.ssh/hermes_vm_ed25519` | Passphrase-protected; passphrase in Keychain |
| Settings (no secrets) | `~/.config/hermes-vm/config.env` | Mode 600, directory 700 |
| Generated Packer vars, ISO, known_hosts | `~/.config/hermes-vm/` | Same directory |
| The VM | `~/Virtual Machines.localized/<name>.vmwarevm` | Open it in Fusion like any VM |
| Gateway log | `~/Library/Logs/hermes-vm-gateway.log` | Shows every model request the VM makes |

During the build:

- **The password never appears on a command line**, either on the Mac or in the VM. It reaches Packer as an
  environment variable, and the VM gets it through Packer's temporary environment file. sudo is told exactly
  which variables to keep, and drops the password before any script runs. Nothing needs it to shut down:
  the last step powers off as root.
- **Packer logs in with a throwaway SSH key** made for that build only. In its last step, the build swaps
  in your real (passphrase-protected) key. The throwaway key is deleted from the Mac however the build ends.

These patterns come from [konstruktoid/hardened-images](https://github.com/konstruktoid/hardened-images).

## What it changes on your Mac (and why it needs sudo)

The build needs no sudo. Lockdown says what it's about to do before it asks for your password, and needs it for exactly these:

1. **Two VMware Fusion networks:** an isolated one for Hermes and the router (no Mac adapter, no DHCP, no NAT),
   and a NAT network for the router's uplink.
2. **A pf firewall anchor**, `com.apple/hermes-vm`, loaded alongside Fusion's own pf rules (it never replaces
   them), plus a small root LaunchDaemon (`local.hermes-vm.pf`). Every 30 seconds the daemon re-binds the rules
   to the router uplink's interface and reloads them if anything flushed them.
3. **Reading firewall counters** during `verify`.

Without sudo it also installs a per-user LaunchAgent (`local.hermes-vm.caddy`) running Caddy as the Ollama gateway.

`./hermes-vm.sh uninstall` removes all of it.

## Commands

| Command | What it does |
| --- | --- |
| `./hermes-vm.sh` | Whatever is next: setup, continue an unfinished stage, or start both VMs headless |
| `./hermes-vm.sh build` | Stage 1: base Ubuntu install with Packer (asks before rebuilding an existing VM) |
| `./hermes-vm.sh provision [hermes\|router]` | Stage 2: hardening, Docker, Hermes; resumes from the last finished step |
| `./hermes-vm.sh lockdown` | Stage 3: wire Hermes behind the router, snapshot both, run `verify` |
| `./hermes-vm.sh start` / `stop` / `status` | Run both VMs headless (router first); status of VMs, firewall and gateway. `start` then lists the models in `ollama list` and asks which one Hermes should use (Enter, or 30 s of no answer, keeps the current one; `HERMES_VM_MODEL=<name>` answers it up front) |
| `./hermes-vm.sh model [NAME]` | Switch Hermes's model while it runs; restarts the Hermes container |
| `./hermes-vm.sh update [TAG]` | Update the Hermes image in the VM: shows old and new versions, backs up Hermes's data (last 3 kept in `/var/backups/hermes-vm` in the VM), re-pins the image by digest, and switches back by itself if Hermes doesn't start healthy |
| `./hermes-vm.sh update --rollback` | Go back to the image used before the last update, optionally restoring the data backup taken then |
| `./hermes-vm.sh ssh` | SSH into Hermes as the admin user, through the router (extra args go to ssh) |
| `./hermes-vm.sh ssh-router` | SSH into the router VM |
| `./hermes-vm.sh setup-hermes` | Run Hermes's setup wizard in the VM, then start it |
| `./hermes-vm.sh verify` | Isolation tests from inside the VM (see below) |
| `./hermes-vm.sh logs` | Follow the gateway log on the Mac |
| `./hermes-vm.sh configure` / `host` | Re-run the questions / only the Mac side of lockdown |
| `./hermes-vm.sh uninstall` | Remove everything (asks before deleting the VM, key and Keychain entry) |

## After lockdown

```bash
./hermes-vm.sh setup-hermes    # choose a custom/OpenAI-compatible endpoint; the script prints the values
```

Each VM has a `base` snapshot (Ubuntu installed) and a `provisioned` one (hardened, before lockdown). After
lockdown, Hermes also has `clean-no-secrets` and the router `clean` (locked down and verified, no keys). To change
Hermes's size later, run `./hermes-vm.sh configure`; it applies at the next start, container limits included. If you ever suspect Hermes, don't investigate in place: revert to
`clean-no-secrets` (Fusion > Snapshots) and rotate any keys Hermes held.

## Network policy

Traffic from Hermes, as enforced by the router VM (Hermes's only network link):

| Destination | Result |
| --- | --- |
| The internet (IPv4) | Allowed |
| The Ollama gateway, at the router's address (`172.16.42.1:11435`), forwarded to the Mac | Allowed: 6 paths; model management (`/api/pull`, `/api/create`, `/api/blobs`, ...) returns 403 |
| The router itself (SSH, ping, anything) | Blocked |
| Your Mac, anything else (Ollama directly, AirPlay, SSH, ...) | Blocked |
| The network your Mac is on right now (home, office, hotspot, any address range) | Blocked |
| All private and special ranges: RFC 1918, CGNAT/Tailscale, link-local, multicast | Blocked |
| IPv6 | Blocked (and disabled in the VM) |

Hermes's own nftables firewall enforces the same policy a second time. It's defence in depth: root in Hermes
could switch it off, but not the router's. The router only lets Hermes's reserved address out, its SSH accepts
connections only from the Mac and may forward only to Hermes's SSH port, and the Mac's pf rules on the uplink
admit only the gateway port.

## Verifying it yourself

`./hermes-vm.sh verify` copies a test script into the VM and runs it **as root**, the worst case:

- **Pass 1, Hermes firewall on:** the internet and gateway work; `/api/pull` is refused; the router VM, the Mac (on every address), your home router and Tailscale are unreachable. It also checks IPv6, that `hermes` has no sudo, and that Docker is rootless.
- **Pass 2, Hermes firewall flushed:** the same network tests again, with only the router VM in the way. Hermes's firewall is restored afterwards.

It finishes by showing the pf block counters on the Mac. Run it again after macOS, Fusion or Hermes updates,
and on each kind of network you use (home, office, phone hotspot).

## What's hardened inside the VM

| Area | Controls |
| --- | --- |
| VMware | Shared folders, clipboard, drag-and-drop, device connect/edit, VNC and host-info all disabled |
| Install | Ubuntu Server minimal; unattended; key-only SSH; security updates during install |
| Kernel | `kptr_restrict`, `dmesg_restrict`, unprivileged BPF off, kexec off, ptrace scope 2, IPv6 off, `init_on_alloc/free`, `slab_nomerge`; rare filesystems, protocols and USB storage blocked |
| Filesystem | `/tmp` tmpfs `nosuid,nodev`; `/dev/shm` `noexec`; umask 027; core dumps off |
| Accounts | root locked; `su` limited to the sudo group; sudo needs a password, uses a pty and is logged |
| SSH | Admin user only; Ed25519 keys; post-quantum hybrid key exchange; no agent, X11 or remote forwarding |
| Firewall | nftables: inbound SSH only via the router; outbound internet + gateway; no local destinations |
| Router VM | Same hardened base, no Docker; nftables forwarding policy; DHCP with a single address (Hermes's); SSH from the Mac only, forwarding only to Hermes's SSH |
| Containers | Rootless Docker, no rootful socket, `no-new-privileges`, capped local logs |
| Monitoring | auditd rules (identity, privilege, firewall, Docker, kernel modules); persistent journal |
| Patching | unattended-upgrades with a 04:00 reboot; snapd removed and pinned out; cloud-init disabled after build |

The build saves a [Lynis](https://cisofy.com/lynis/) report to `lynis-baseline.txt` in the VM folder.

## Limits (read these)

- **Hermes can read its own `.env`.** It runs commands inside its container (terminal backend `local`), so
  give it only scoped, revocable credentials made for it.
- **The internet is open.** That's what makes the agent useful. Anything the VM holds can be sent out, so it
  holds nothing valuable. Every gateway request is logged.
- **Ollama's chat endpoint is still reachable.** A bug there is reachable from the VM. Keep Ollama updated.
- **A hypervisor escape** in VMware Fusion would bypass the VM layer. Keep Fusion updated.
- **Shared admin account:** both VMs use the same admin username, password and SSH key. Only the Mac can log in
  to either (key-only SSH, filtered by both VMs' firewalls).
- **Container capabilities:** the six `cap_add` entries in `guest/files/hermes/compose.yaml.tpl` are a safe
  start for the image's init. Try removing them one at a time.

## Troubleshooting

**Installer goes interactive (language screen) or the kernel panics at boot.** The GRUB keystrokes in
`packer/hermes.pkr.hcl` (`boot_command`) type `linux /casper/vmlinuz autoinstall ---`, `initrd /casper/initrd`
and `boot` at GRUB's command line. If a future ISO moves the kernel, open the ISO's `/casper` folder, update
the two paths, and run `./hermes-vm.sh build` again. If keystrokes arrive before GRUB is ready, raise
`boot_wait` in `packer/variables.pkr.hcl`.

**`unable to find vmnetdhcp conf file`** during the build: Fusion's default NAT network (`vmnet8`) is missing.
Restore defaults in Fusion > Settings > Network. During lockdown, it means the dedicated network wasn't created:
quit Fusion (it overwrites network settings while open) and run `./hermes-vm.sh host`.

**Build fails downloading packages** (`returned non-zero exit status 100`): the VM has no internet on
Fusion's default network. Check that a Mac firewall app (Little Snitch, LuLu) isn't blocking VMware's NAT.

**Lockdown stops with "connecting from X, not VM_GW".** The Mac's address on the VM network isn't
`.1` of your subnet. Check with `ifconfig | grep -B3 <subnet prefix>`, then set the subnet to match with
`./hermes-vm.sh configure`.

**Gateway log stays empty while Hermes answers.** Hermes is using another provider. Re-run
`./hermes-vm.sh setup-hermes` and choose the custom endpoint it prints.

**Packer says the build failed after you pressed `r` to retry a step.** Packer marks a build failed if any step
failed once, even if the retry worked. Just run `./hermes-vm.sh`: it asks whether to keep that install or redo it,
then carries on.

**A provisioning step failed.** Answer `y` to retry it, or fix the cause and run `./hermes-vm.sh` later: finished
steps are skipped. To start a VM's provisioning from scratch, revert it to its `base` snapshot in Fusion.

**Creating the Fusion networks by hand.** If the script can't set them up, open Fusion > Settings > Network and
add two custom networks: the Hermes network (e.g. `vmnet2`) with "Connect Macs to this network", NAT and DHCP all
**off**, subnet `172.16.42.0` / `255.255.255.0`; and the router uplink (e.g. `vmnet3`) with all three **on**,
subnet `172.16.43.0` / `255.255.255.0`. Then re-run `./hermes-vm.sh lockdown`.

**Never run `sudo pfctl -d`.** It switches pf off for Fusion's NAT as well. To remove only these rules:
`sudo pfctl -a com.apple/hermes-vm -F all`, or `./hermes-vm.sh uninstall`.

## Layout

```
hermes-vm.sh                 entry point
lib/                         preflight, configure, build, lockdown, host, manage (bash 3.2 compatible)
host/                        templates: pf anchor + loader, LaunchDaemon, Caddyfile, LaunchAgent
packer/                      vmware-iso build + Ubuntu autoinstall template
guest/scripts/               provisioning: base, harden, firewall, rootless Docker, Hermes, finalise
guest/router/                router VM: forwarding/NAT firewall, networking, SSH restriction (applied by lockdown)
guest/files/                 sysctl, modprobe, sshd, auditd, nftables, Docker, Hermes compose
guest/verify-guest.sh        isolation test suite (run by ./hermes-vm.sh verify)
```

## Contributing

Every push and pull request runs the checks in `.github/workflows/lint.yml`: `bash -n`, shellcheck,
a bash 3.2 compatibility scan (macOS still ships bash 3.2), `packer fmt` and `packer validate`, and a
template render check. Run `packer fmt packer/` before committing HCL changes.

## Licence

MIT. See [LICENSE](LICENSE).
