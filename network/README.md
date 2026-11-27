# Network: systemd-networkd + iwd

The Pi 1 runs systemd-networkd for addressing and iwd for Wi-Fi (no NetworkManager, dhcpcd or
wpa_supplicant). systemd-resolved handles DNS (`/etc/resolv.conf` → its stub).

- **eth0:** the onboard 100 Mbit/s Ethernet (SMSC LAN9512, behind the same USB 2.0 bus as
  everything else).
- **wlan0:** a USB TP-Link Archer T2U Nano (Realtek RTL8811AU, `rtw88_8821au` driver), dual band
  802.11ac, one stream.

Both get DHCPv4 addresses. Ethernet is preferred when it's plugged in (route metric 1024, Wi-Fi
2048), so Wi-Fi works as the fallback or as the only link.

## Files

| File | Installed as |
|---|---|
| `20-wired.network` | `/etc/systemd/network/20-wired.network` |
| `25-wireless.network` | `/etc/systemd/network/25-wireless.network` |
| `systemd-networkd-wait-online.service.d/any.conf` | `/etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf` |

```
sudo apt install iwd
sudo install -m644 20-wired.network 25-wireless.network /etc/systemd/network/
sudo install -Dm644 systemd-networkd-wait-online.service.d/any.conf \
    /etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf
sudo systemctl daemon-reload
sudo systemctl enable --now systemd-networkd systemd-resolved iwd
```

iwd keeps its own address configuration off (`EnableNetworkConfiguration` stays unset in
`/etc/iwd/main.conf`): iwd only associates, networkd does DHCP. `25-wireless.network` matches any
station-mode Wi-Fi interface, so a different adapter works without editing it.

Add a network (the passphrase ends up in `/var/lib/iwd/<ssid>.psk`, root-only, not in this repo):

```
iwctl station wlan0 scan
iwctl station wlan0 get-networks
iwctl station wlan0 connect <ssid>
```

## Wait-online

By default `systemd-networkd-wait-online` waits for **every** link networkd manages. With the
Ethernet cable unplugged, eth0 sits in `configuring` and boot stalls until the timeout (about
2–3 minutes), then the unit fails even though Wi-Fi came up within seconds. Only cloud-init
orders itself after `network-online.target` here, so the cost was boot time and a red
`failed:` line in the MOTD. `any.conf` runs it with `--any`: online as soon as either link is.

## RF-kill: a new Wi-Fi adapter starts blocked

If iwd logs `Error bringing interface ... up: Operation not possible due to RF-kill` and
`iwctl device list` shows `Powered off`, the radio is soft-blocked. On Raspberry Pi OS this
happens to any Wi-Fi radio that shows up after the country was set:

1. `raspberrypi-sys-mods` installs `/etc/modprobe.d/rfkill_default.conf`
   (`options rfkill default_state=0`), so the kernel soft-blocks every new radio until a Wi-Fi
   country is set.
2. Setting the country (Imager/cloud-init or raspi-config) runs `rfkill unblock wifi` and writes
   `0` to the saved states in `/var/lib/systemd/rfkill/*:wlan`, but only for radios that exist
   at that moment. The Pi 1 has no built-in Wi-Fi, so at first boot the glob matched nothing and
   left a file literally named `*:wlan`.
3. When the USB adapter is plugged in later, the kernel blocks it, `systemd-rfkill` saves that
   state for its USB port, and restores the block on every boot.

The login hint from `/etc/profile.d/wifi-check.sh` stays quiet because the country is set on the
kernel command line (`cfg80211.ieee80211_regdom=PT`).

Fix (the state file is per USB port, so a different port starts blocked again):

```
R=$(dirname $(grep -l phy0 /sys/class/rfkill/*/name))
echo 0 | sudo tee $R/soft
for f in /var/lib/systemd/rfkill/*usb*:wlan; do echo 0 | sudo tee "$f"; done
iwctl device wlan0 set-property Powered on
```

Since the country is already set on the command line, a permanent alternative is
`options rfkill default_state=1` in a modprobe.d file that sorts after `rfkill_default.conf`
(not installed here). The MOTD shows `wlan0 blocked by rfkill` in red when this happens.

## Throughput

Measured with iperf3 between the Pi and a wired host on the LAN, Wi-Fi on 2.4 GHz channel 11
(802.11n, 20 MHz, link rate 58–72 Mbit/s, about -55 dBm):

| Test | readsb running | readsb stopped |
|---|---|---|
| Send, TCP | 22.6 Mbit/s | 22.4 Mbit/s |
| Receive, TCP | 18.3 Mbit/s | 20.2 Mbit/s |
| Receive, 4 TCP streams | 20.9 Mbit/s | 20.0 Mbit/s |
| Receive, UDP | 10 Mbit/s (84% lost at 70M offered) | 20 Mbit/s (47% lost at 40M offered) |

So about 20 Mbit/s each way. It isn't the radio link and it isn't only the CPU: with readsb
stopped the CPU was about 35% idle during the receive test and throughput still levelled off.
The likely limit is the Pi 1's USB controller (`dwc_otg`) together with the USB Wi-Fi driver,
which every packet goes through. A 5 GHz network wouldn't change much. ADS-B feeding needs well
under 1 Mbit/s; for `rtl_tcp` over Wi-Fi see `sdr/README.md`.
