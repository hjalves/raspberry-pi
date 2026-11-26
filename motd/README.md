# Login MOTD

`01-rpi` is the login summary, installed as `/etc/update-motd.d/01-rpi`. It has the same layout as
atom's `01-atom`:

- **Header and System:** host, OS, kernel, uptime, board model, load, memory and temperature.
- **Power:** the firmware's throttling flags from `vcgencmd get_throttled` (under-voltage,
  frequency cap, throttling, soft temperature limit), both now and since boot.
- **Disks, Network:** usage bars for `/` and `/boot/firmware`, and eth0's address.
- **SDR:** ADS-B mode with aircraft count, msg/s, range and adsb.fi connection; or DVB-T mode,
  antenna aiming (`dvb-aim`), or idle.
- **Services, failed units, reboot-required.**

Debian's PAM (`pam_motd` in `/etc/pam.d/sshd` and `login`) runs `/etc/update-motd.d/*` on every
login. On a Pi 1 each `systemctl` call costs about 0.35 s, so the script asks once and reuses the
answer; it takes about 1.8 s.

Install:

```
sudo install -m755 01-rpi /etc/update-motd.d/01-rpi
sudo chmod -x /etc/update-motd.d/10-uname                  # stock "uname -snrvm" line
sudo cp -p /etc/motd /etc/motd.debian && sudo truncate -s 0 /etc/motd   # Debian licence text
```

`99-rpi-usb-gadget` (Raspberry Pi OS) is left alone: it only prints while USB gadget mode is
enabled. A `base-files` upgrade may restore `/etc/motd`.
