# linux-config-ip

Set a **static IP or DHCP** on a Linux machine with a single command, without wondering whether you should use `nmtui`, `/etc/network/interfaces` or something else.

The script detects which network manager controls the interface, writes the configuration in the right place and applies it immediately.

```
=== linux-config-ip 1.2.0 ===
[i] System: Debian GNU/Linux 13 (trixie)
[i] Interface: ens18 (current address: 192.168.10.37/24)
[i] Detected manager: ifupdown (/etc/network/interfaces)

What do you want to do?  (current mode: DHCP)
  1) Static IP address
  2) Automatic address (DHCP)
Choice [1]:

Enter the address with its mask (e.g. 192.168.10.1/24)
or just the address (e.g. 192.168.10.1): the mask will be asked next.
IP address: 192.168.10.1/24
Gateway (type "none" for no gateway) [192.168.10.254]:
DNS servers (space separated) [1.1.1.1 9.9.9.9]:

Summary
  Interface : ens18
  Mode      : static IP
  Address   : 192.168.10.1/24  (mask 255.255.255.0)
  Gateway   : 192.168.10.254
  DNS       : 1.1.1.1 9.9.9.9
  Manager   : ifupdown (/etc/network/interfaces)

Apply now? (Y/n) [Y]:
[OK] Address 192.168.10.1 is set on ens18.
[OK] Gateway 192.168.10.254 is reachable.
[OK] Configuration applied and persistent across reboots.
```

## Supported distributions

| Distribution | Status |
|---|---|
| Debian 11, 12, 13 | ✅ Supported |
| Ubuntu | 🔜 Coming soon |
| Other distributions | 🔜 Coming soon |

## Quick start

Run these commands **as root** on the machine to configure (use `su -` first if `sudo` is not installed).

### Option 1 — Download with curl (recommended)

```bash
apt install -y curl
curl -fsSL https://raw.githubusercontent.com/Remilulz91/linux-config-ip/main/linux-config-ip.sh -o linux-config-ip.sh
chmod +x linux-config-ip.sh
./linux-config-ip.sh
```

### Option 2 — Download with wget

`wget` is usually already installed on Debian.

```bash
wget -O linux-config-ip.sh https://raw.githubusercontent.com/Remilulz91/linux-config-ip/main/linux-config-ip.sh
chmod +x linux-config-ip.sh
./linux-config-ip.sh
```

### Option 3 — Clone the repository with git

```bash
apt install -y git
git clone https://github.com/Remilulz91/linux-config-ip.git
cd linux-config-ip
chmod +x linux-config-ip.sh
./linux-config-ip.sh
```

### Option 4 — Machine without Internet access (local copy)

This is the usual case when the network is not configured yet.

1. On a computer with Internet access, download the script:
   - from GitHub: open `linux-config-ip.sh` → **Download raw file**, or **Code → Download ZIP**,
   - or with the command:
     ```bash
     curl -fsSL https://raw.githubusercontent.com/Remilulz91/linux-config-ip/main/linux-config-ip.sh -o linux-config-ip.sh
     ```
2. Copy it to the target machine, over SSH:
   ```bash
   scp linux-config-ip.sh root@TARGET_IP:/root/
   ```
   or from a USB stick (on the target machine):
   ```bash
   mount /dev/sdb1 /mnt
   cp /mnt/linux-config-ip.sh /root/
   umount /mnt
   ```
3. Run it on the target machine:
   ```bash
   cd /root
   chmod +x linux-config-ip.sh
   ./linux-config-ip.sh
   ```

If `chmod` is not possible (read-only medium, for example), run it with `bash` instead:

```bash
bash linux-config-ip.sh
```

> **Windows users:** if you copied or edited the script on Windows and get `/bin/bash^M: bad interpreter`, fix the line endings with:
> ```bash
> sed -i 's/\r$//' linux-config-ip.sh
> ```

## Why sometimes `nmtui` and sometimes `/etc/network/interfaces`?

It is **not the Debian version** that decides, it is **how the machine was installed**:

| Installation | Network manager | Where the IP is configured |
|---|---|---|
| With a desktop environment (GNOME, KDE, Xfce…) | NetworkManager | `nmtui` / `nmcli` |
| Server / netinst without desktop | ifupdown | `/etc/network/interfaces` |
| Cloud images, some minimal installs | systemd-networkd | `/etc/systemd/network/*.network` |

Important: on Debian, **NetworkManager ignores any interface declared in `/etc/network/interfaces`**. That is why editing the "wrong" place seems to do nothing.

Debian 11, 12 and 13 all behave the same way here, so a single script covers all of them. Since NetworkManager and systemd-networkd are also used by other distributions, the same script is the foundation for supporting them.

## Usage

### Choosing the mode

On startup, the script offers:

1. **Static IP address**: asks for the address, gateway and DNS servers.
2. **Automatic address (DHCP)**: switches the interface back to DHCP, no further questions.

### Entering the address (static mode)

Both formats are accepted:

```
IP address: 192.168.10.1/24
```

```
IP address: 192.168.10.1
Mask (e.g. 255.255.255.0 or 24): 255.255.255.0
```

The script checks that the address is valid, that the mask is correct, that the address is neither the network nor the broadcast address, and that the gateway is in the same network.

### Non-interactive mode

```bash
./linux-config-ip.sh -i ens18 -a 192.168.10.1/24 -g 192.168.10.254 -d "1.1.1.1 9.9.9.9" -y
./linux-config-ip.sh -i ens18 -a 192.168.10.1 -m 255.255.255.0 -g none -d 192.168.10.53 -y
./linux-config-ip.sh -i ens18 --dhcp -y
```

| Option | Description |
|---|---|
| `-i`, `--interface` | Interface to configure |
| `-s`, `--static` | Static IP mode (implied by `-a`) |
| `-D`, `--dhcp` | Switch the interface back to DHCP |
| `-a`, `--address` | Address, with or without `/CIDR` |
| `-m`, `--mask` | Mask (`255.255.255.0` or `24`) if not given in `-a` |
| `-g`, `--gateway` | Gateway (`none` for no gateway) |
| `-d`, `--dns` | DNS servers separated by spaces or commas |
| `-b`, `--backend` | Force `networkmanager`, `ifupdown` or `networkd` |
| `-y`, `--yes` | Do not ask for confirmation |
| `-n`, `--dry-run` | Show what would be done without changing anything |
| `-h`, `--help` | Help |
| `-V`, `--version` | Version |

Tip: run with `-n` first to see exactly which files will be written.

```bash
./linux-config-ip.sh -n
```

## What the script does

| Manager | Action |
|---|---|
| NetworkManager | Updates the interface's active profile with `nmcli` (or creates one) in `manual` or `auto` mode, then reactivates it. The result is visible in `nmtui`. |
| ifupdown | Replaces the interface's IPv4 stanza **in place** with an `inet static` or `inet dhcp` stanza. Comments, IPv6 and other interfaces are kept. Then restarts the interface. |
| systemd-networkd | Writes `/etc/systemd/network/05-linux-config-ip-<if>.network` (`DHCP=no` + address, or `DHCP=ipv4`), disables other files targeting the interface, then runs `networkctl reload` + `reconfigure`. |

In static mode, DNS servers are written in the right place: NetworkManager profile, `systemd-resolved`, `resolvconf` or `/etc/resolv.conf` (`search` / `domain` lines are kept). In DHCP mode, DNS servers forced by the script are removed and the DHCP server takes over.

## Safety

- **Backup** of every modified file in `/var/backups/linux-config-ip/<date>/`.
- **Automatic rollback** if bringing the interface up fails.
- **Log** in `/var/log/linux-config-ip.log`.
- The script **keeps running if the SSH session drops** while the address changes. Reconnect to the new IP afterwards.
- Only IPv4 is changed.
- When switching to DHCP over SSH, the new address is not known in advance: keep console access or check the DHCP server leases.

Restore a backup manually (ifupdown example):

```bash
cp -a /var/backups/linux-config-ip/20260916-121407/etc/network/interfaces /etc/network/interfaces
systemctl restart networking
```

## Limitations

- IPv4 only, one address per interface.
- Wi-Fi: only with NetworkManager and an existing profile.
- Bonding, VLANs and bridges are not handled.

## License

MIT — see [LICENSE](LICENSE).
