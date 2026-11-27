# RTL-SDR on the Pi: ADS-B receiver

A Raspberry Pi 1 (Raspbian 13 "trixie", armv6) with an RTL2832U/R820T dongle runs as a
full-time ADS-B receiver:

- **readsb** decodes 1090 MHz and writes JSON to `/run/readsb/`
  (network outputs: 30002 raw, 30003 SBS, 30005 Beast).
- **tar1090** shows the map at `http://<pi>/tar1090/` (lighttpd).
- **adsb.fi** feed and MLAT (`adsbfi-feed`, `adsbfi-mlat`), reading readsb's port 30005.

## Files

| File | Installed as |
|---|---|
| `sdr-mode` | `/usr/local/bin/sdr-mode` |
| `dvb-aim` | `/usr/local/bin/dvb-aim` |
| `ws2900` | `/usr/local/bin/ws2900` (needs `python3-numpy`) |
| `modprobe.d/blacklist-rtlsdr-dvb.conf` | `/etc/modprobe.d/blacklist-rtlsdr-dvb.conf` |

```
sudo install -m755 sdr-mode dvb-aim ws2900 /usr/local/bin/
sudo install -m644 modprobe.d/blacklist-rtlsdr-dvb.conf /etc/modprobe.d/
```

### sdr-mode

Only one program can use the dongle at a time. `sdr-mode` switches it between readsb and the
kernel DVB-T driver (for `dvbv5-scan` and friends):

```
sdr-mode dvb      # stop readsb, load dvb_usb_rtl28xxu, wait until /dev/dvb/adapter0 is usable
sdr-mode adsb     # unload the DVB-T driver, start readsb
sdr-mode status
```

readsb stays enabled and the DVB modules stay blacklisted, so a reboot always comes back in
ADS-B mode. The adsb.fi services, tar1090 and lighttpd keep running in DVB mode; they only read
readsb's output and reconnect when it's back.

The DVB device nodes start out root-only and udev opens them to the `plugdev` group a few seconds
later; `sdr-mode dvb` waits for that (`udevadm settle`), so members of `plugdev` can use
`dvbv5-scan` and friends without sudo.

### dvb-aim

Live DVB-T channel levels for pointing an antenna (`/usr/local/bin/dvb-aim`, Python stdlib only,
needs `rtl-sdr` and `dvb-tools`):

```
dvb-aim                    # channel 43; lock check every 5 passes
dvb-aim -c 40,43 --lock-every 0 -i 2
```

Each ~2 s pass prints every channel's level in dB above the noise floor, measured with
`rtl_power`. That works without a DVB lock, which matters because this dongle's DVB driver
reports no signal statistics at all until it locks. Every N passes it loads the DVB-T driver and
asks `dvbv5-zap` for lock, signal and C/N (about 5 s per channel). readsb is stopped while it
runs and restarted on exit, Ctrl-C included. As a rough guide, DVB-T 64-QAM needs about
18–20 dB C/N to decode cleanly.

### ws2900

Decodes the WS2900 weather station's outdoor sensor (a Fine Offset WH65, 868 MHz FSK, one packet
every 16 s) with its own demodulator: burst detection, FM discriminator, bit-clock recovery,
`aa 2d d4` sync, CRC-8 + byte-sum check, then the WH24/WH65 fields (layout as documented in
rtl_433's `fineoffset.c`), with the UV index worked out from the raw UV value using rtl_433's
thresholds.

```
ws2900                     # live, until Ctrl-C (pauses readsb, restarts it on exit)
ws2900 --minutes 2 --json  # one JSON object per reading
ws2900 --raw               # also packet bytes and bursts that didn't decode
ws2900 --file rec.cu8 --rate 1024000 --centre 868000000   # decode a recording
```

Live it runs `rtl_sdr` at 868.2 MHz / 300 kHz (the sensor's tones sit near 868.25 and 868.32 MHz),
about 60% CPU on a Pi 1. It uses Raspbian's `python3-numpy`, since uv-managed Pythons don't support
the Pi 1's ARMv6. Checked against rtl_433 on the same recording: identical readings.

### DVB driver blacklist

The kernel's DVB-T driver claims the dongle at boot; the blacklist keeps it free for readsb.
`modprobe dvb_usb_rtl28xxu` still loads it on demand (which is what `sdr-mode dvb` does).

## Setup notes

Location, altitude and the adsb.fi UUID are left out of this repo on purpose.

**readsb.** Raspbian's `readsb` package is built without RTL-SDR support (it only accepts
network/file input), so build wiedehopf's fork as a .deb on the Pi (about 20 minutes on a Pi 1):

```
sudo apt install --no-install-recommends git build-essential debhelper help2man \
    libusb-1.0-0-dev librtlsdr-dev librtlsdr0 pkg-config libncurses-dev zlib1g-dev libzstd-dev
git clone --depth 1 https://github.com/wiedehopf/readsb.git && cd readsb
dpkg-buildpackage -b -Prtlsdr -ui -uc -us
sudo apt install ../readsb_*_armhf.deb
```

Then add `--lat <lat> --lon <lon>` to `DECODER_OPTIONS` in `/etc/default/readsb`.

**tar1090.** `sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/wiedehopf/tar1090/master/install.sh)"`
(install lighttpd first). It serves `/tar1090/` on port 80 and the map at `/` on port 8504.

**adsb.fi.** Scripts from https://github.com/adsbfi/adsb-fi-scripts. Their wizard only writes
`/etc/default/adsbfi` (name, lat, lon, altitude like `415m`); with that file in place,
`sudo bash /usr/local/share/adsbfi/git/update.sh` installs non-interactively. Check the feed with
`curl https://api.adsb.fi/v1/myip` from the Pi.

**Pi 1 limits.** Over `rtl_tcp` the Pi 1 sustains only about 2.0 Msps, so at 2.048 Msps the
stream falls behind and lags retunes by seconds. Use 1.8 Msps or less for anything that retunes.
Decoding on the Pi itself, as here, avoids the problem.

**rtl_tcp over Wi-Fi.** The Wi-Fi link carries about 20 Mbit/s (`network/README.md`), and
`rtl_tcp` sends 2 bytes per sample, so the ceiling is about 1.2 Msps. Measured with readsb stopped,
30 s per run, the client on a wired LAN host:

| Requested | Delivered |
|---|---|
| 0.900 Msps | 0.875–0.900 Msps (97–100%) |
| 1.024 Msps | 1.005–1.013 Msps (98–99%) |
| 1.200 Msps | 1.170–1.198 Msps (97.5–99.8%) |
| 1.4–2.4 Msps | 1.1–1.4 Msps, link saturated |

USB is not the problem: `rtl_test -s 2400000` on the Pi loses next to nothing. Use 1.024 Msps
over Wi-Fi (1.2 works with no headroom); even then expect an occasional short stall. ADS-B over
`rtl_tcp` (2–2.4 Msps) needs a wired link. `rtl_tcp` takes a few seconds to release the dongle
after it's stopped; wait for the process to exit before starting another one.
