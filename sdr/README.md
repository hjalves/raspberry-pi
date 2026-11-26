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
| `modprobe.d/blacklist-rtlsdr-dvb.conf` | `/etc/modprobe.d/blacklist-rtlsdr-dvb.conf` |

```
sudo install -m755 sdr-mode dvb-aim /usr/local/bin/
sudo install -m644 modprobe.d/blacklist-rtlsdr-dvb.conf /etc/modprobe.d/
```

### sdr-mode

Only one program can use the dongle at a time. `sdr-mode` switches it between readsb and the
kernel DVB-T driver (for `dvbv5-scan` and friends):

```
sdr-mode dvb      # stop readsb, load dvb_usb_rtl28xxu, wait for /dev/dvb/adapter0
sdr-mode adsb     # unload the DVB-T driver, start readsb
sdr-mode status
```

readsb stays enabled and the DVB modules stay blacklisted, so a reboot always comes back in
ADS-B mode. The adsb.fi services, tar1090 and lighttpd keep running in DVB mode; they only read
readsb's output and reconnect when it's back.

### dvb-aim

Live DVB-T channel levels for pointing an antenna (`/usr/local/bin/dvb-aim`, Python stdlib only,
needs `rtl-sdr` and `dvb-tools`):

```
dvb-aim                    # channels 43,45,48; lock check every 5 passes
dvb-aim -c 40,43 --lock-every 0 -i 2
```

Each ~2 s pass prints every channel's level in dB above the noise floor, measured with
`rtl_power`. That works without a DVB lock, which matters because this dongle's DVB driver
reports no signal statistics at all until it locks. Every N passes it loads the DVB-T driver and
asks `dvbv5-zap` for lock, signal and C/N (about 5 s per channel). readsb is stopped while it
runs and restarted on exit, Ctrl-C included. As a rough guide, DVB-T 64-QAM needs about
18–20 dB C/N to decode cleanly.

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
