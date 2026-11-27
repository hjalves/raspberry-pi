# Login MOTD

`01-rpi` is the login summary, installed as `/etc/update-motd.d/01-rpi`. It has the same sections
as atom's `01-atom`:

- **Header and System:** host, OS, kernel, uptime, board model, load, memory and temperature.
- **Power:** the firmware's throttling flags from `vcgencmd get_throttled` (under-voltage,
  frequency cap, throttling, soft temperature limit), both now and since boot.
- **Disks, Network:** usage bars for `/` and `/boot/firmware` (shown as `/boot/fw`); eth0's
  address; and, when a Wi-Fi adapter is present, its address, network name, signal (green above
  -67 dBm, yellow down to -75, red below), band and channel, transmit rate, and the adapter model
  and driver. A radio blocked by RF-kill shows in red (see `network/README.md`).
- **SDR:** ADS-B mode with aircraft count, msg/s, range and adsb.fi connection; or DVB-T mode,
  antenna aiming (`dvb-aim`), or idle.
- **Services, failed units, reboot-required.**

Every line fits in 58 columns (`W=58` at the top), so it reads well in a phone SSH client:

```
  rpi · Raspbian GNU/Linux 13 (trixie)
  kernel 6.18.60+rpt-rpi-v6 · up 11 minutes
  Raspberry Pi Model B Rev 2

  System   load 1.95 2.55 1.91 (1 core)
           memory 141.7M / 474.3M · 42°C
  Power    ok · (0x0)
  Disks    /        ━━━━──────────────  27%  3.9G/15G
           /boot/fw ━━────────────────  16%  80M/505M
  Network  eth0  down
           wlan1 192.168.0.222 · wifi2 · -55 dBm
                 2.4 GHz ch 11 · 72 Mbit/s
                 Archer T2U Nano, rtw88_8821au
  SDR      ADS-B (readsb) · 3 aircraft (3 with position)
           9 msg/s · range 63 km · adsb.fi connected
  Services ● readsb  ● tar1090  ● lighttpd  ● landing
           ● adsbfi-feed  ● adsbfi-mlat  ● ssh
           ● systemd-timesyncd
```

`wrap` joins a section's items with ` · ` and starts an aligned continuation line before any item
that would pass column `W`. It measures widths in bash with colour codes stripped (no extra
processes), under `LC_ALL=C.UTF-8` so `━`, `●` and `°` count as one column even when `pam_motd`
runs the script without a locale. A single item can't be split, so the free-form ones are kept
short (the Wi-Fi adapter name is cut to 24 characters).

Debian's PAM (`pam_motd` in `/etc/pam.d/sshd` and `login`) runs `/etc/update-motd.d/*` on every
login. On a Pi 1 each `systemctl` call costs about 0.35 s, so the script asks once and reuses the
answer; it takes about 1.8 s. The Wi-Fi line adds about 0.3–0.5 s: one `iwctl station wlan0
show` (0.1 s), parsed in bash, and the adapter model read straight from udev's database in
`/run/udev/data/` rather than through `udevadm` (0.2 s).

Install:

```
sudo install -m755 01-rpi /etc/update-motd.d/01-rpi
sudo chmod -x /etc/update-motd.d/10-uname                  # stock "uname -snrvm" line
sudo cp -p /etc/motd /etc/motd.debian && sudo truncate -s 0 /etc/motd   # Debian licence text
```

`99-rpi-usb-gadget` (Raspberry Pi OS) is left alone: it only prints while USB gadget mode is
enabled. A `base-files` upgrade may restore `/etc/motd`.
