# ifspeedtest.sh — link quality + throughput tester (iperf3 + mtr)

A cross-platform (portable) `/bin/sh` script to compare **real-world network quality**, not just raw “speed”.  
It runs **iperf3** (upload + download) and **mtr** (latency/loss/jitter/hops), then prints per-target results plus a **Scorecard** so you can quickly pick the best route/egress/target.

Works on **macOS**, **Linux**, **OpenWrt**, and most Unix-like systems with the required tools installed.

![alt network-testing-shell-script](https://github.com/russellgrapes/bash-ifspeedtest/blob/main/placeholder.png)

---

## What it measures

- **Throughput**: iperf3 upload + download (reverse mode)
- **Latency / Loss / Jitter / Hops**: mtr (ICMP/UDP/TCP probes)
- **Under-load quality** (bufferbloat indicator):
  - ping + jitter while iperf is running
  - **ΔPing** and **ΔJitter** vs idle baseline

---

## Features

- **IPv4 + IPv6**
  - test IPv4 / IPv6 literals directly
  - test domains with `--ipv4` / `--ipv6` (A/AAAA)
- **Port spec for iperf3**: single port, **ranges**, or comma lists  
  Example: `-p 5201-5210` or `-p 5201,5203,5205-5207`  
  The script will **fallback** across ports until it gets a valid result and will report which port was used.
- **Multiple targets** via `--ips <file>`
  - one per line
  - supports inline `# notes` that show up in output and Scorecard
- **Multiple egress interfaces**
  - `-I eth0 -I eth1` or `-I "eth0,eth1"`
  - if multiple interfaces are set, each target is tested across **all** of them
- **Scorecard** (when testing more than 1 target)
  - best upload, best download, best ping, minimum hops (ties supported)
- **Logging**: `--log [dir]` writes a single consolidated log
- **Optional auto-install**: `--install-missing` (brew/apt/yum/dnf/pacman/opkg where available)

---

## Quick start

### 1) Download

```sh
curl -O https://raw.githubusercontent.com/russellgrapes/bash-ifspeedtest/main/ifspeedtest.sh
chmod +x ifspeedtest.sh
````

### 2) Run

If you don’t specify `--mtr` or `--iperf3`, it runs **both** by default.

```sh
./ifspeedtest.sh -i 1.1.1.1
./ifspeedtest.sh -i 2606:4700:4700::1111
./ifspeedtest.sh -i example.com --mtr --iperf3 30
```

---

## Usage

```sh
./ifspeedtest.sh [options]
```

### Options

* `-i, --ip <IPv4|IPv6|domain>`: target to test
* `--ips <file>`: file with targets (one per line; supports `# comments`)
* `--ipv4`: for domain targets, resolve/use IPv4 only (A)
* `--ipv6`: for domain targets, resolve/use IPv6 only (AAAA)
* `-I <iface>[,<iface>...]`: egress interface/device to use (repeatable)
* `--mtr [count]`: run mtr (default: `MTR_COUNT` or 10)
* `--iperf3 [time]`: run iperf3 (default: `IPERF3_TIME` or 10 seconds)
* `-P, --iperf3-parallel <n>`: iperf3 parallel streams (default: `IPERF3_PARALLEL` or 10)
* `-p, --iperf3-port <spec>`: iperf3 server port or range/list
  Examples: `5201`, `5201-5210`, `5201,5202-5204`
* `--mtr-probe <icmp|udp|tcp>`: mtr probe type (default: `icmp`)
* `--mtr-port <port>`: destination port for `tcp`/`udp` probes
* `--mtr-interval <seconds>`: seconds between probes (default: `1`)
* `--log [directory]`: write a log file (default: OS-specific; OpenWrt uses `/tmp`)
* `--install-missing`: attempt to install missing tools
* `--sudo`: force sudo for mtr (prompt once up front where supported)
* `--no-sudo`: never use sudo for mtr (mtr may be skipped if it needs privileges)
* `-h, --help`: help

---

## Examples

Single target (defaults: mtr + iperf3):

```sh
./ifspeedtest.sh -i 10.1.1.1
```

Domain + force IPv6 + longer tests:

```sh
./ifspeedtest.sh -i example.com --ipv6 --mtr 30 --iperf3 30
```

Test the same target across two egress interfaces:

```sh
./ifspeedtest.sh -i example.com -I "enp0s3,enp0s8" --mtr --iperf3 20
```

Use iperf3 port range fallback:

```sh
./ifspeedtest.sh -i iperf.example.com --iperf3 20 -p 5201-5210
```

Targets from file + notes + logs:

```sh
./ifspeedtest.sh --ips ips.txt --mtr 30 --iperf3 30 --log ./logs
```

---

## `--ips` file format (with inline notes)

* One target per line: IPv4, IPv6, or domain
* Empty lines ignored
* Lines starting with `#` ignored
* Inline notes after `#` are preserved and shown in the output + Scorecard

Example `ips.txt`:

```txt
1.1.1.1              # route A (ISP1)
2606:4700:4700::1111 # route A (IPv6)
example.com          # route B (ISP2)
9.9.9.9
```

---

## iperf3 server requirements

This script is a **client**. Your targets must have an iperf3 server reachable.

Default server (port 5201):

```sh
iperf3 -s
```

Custom port (must match `-p` on the client):

```sh
iperf3 -s -p 5202
```

If you use a **port range/list** on the client, you need servers/listeners available on those ports (or a load balancer / port-forwarding that makes them work).

---

## Configuration (environment variables)

All defaults can be overridden with env vars:

* `MTR_COUNT` (default 10)
* `MTR_PROBE` (`icmp|udp|tcp`, default `icmp`)
* `MTR_INTERVAL` (default 1)
* `MTR_LOAD_COUNT` (optional; probes during iperf load; if unset it auto-derives from iperf time)
* `MTR_PORT` (for tcp/udp probes; tcp defaults to 443 if unset)
* `IPERF3_TIME` (default 10)
* `IPERF3_PARALLEL` (default 10)
* `IPERF3_PORTS` (same format as `--iperf3-port`)
* `CONNECT_TIMEOUT` (ms; only used if your iperf3 supports `--connect-timeout`)
* `ADDR_FAMILY` (`auto|4|6`; affects domain resolution only)
* `NO_COLOR=1` disables colored output

Example:

```sh
NO_COLOR=1 ./ifspeedtest.sh -i example.com
```

---

## Installation

You can install dependencies manually, or run with `--install-missing` and let the script try.

### macOS (Homebrew)

```sh
brew install mtr iperf3
# if you test domains and don’t already have dig/host/nslookup:
brew install bind
```

### Debian / Ubuntu

```sh
sudo apt update
sudo apt install -y iperf3 mtr-tiny dnsutils
# optional (enables XML parsing when supported by your mtr):
sudo apt install -y libxml2-utils
```

### RHEL / CentOS / Fedora

```sh
sudo dnf install -y iperf3 mtr bind-utils
# optional:
sudo dnf install -y libxml2
```

### Arch

```sh
sudo pacman -S --needed iperf3 mtr bind libxml2
```

### Alpine

```sh
sudo apk add iperf3 mtr bind-tools libxml2-utils
```

### OpenWrt

```sh
opkg update
opkg install iperf3 mtr
# if you test domains and BusyBox nslookup isn’t available/usable:
opkg install bind-dig   # or: opkg install bind-host
```

---

## Notes / troubleshooting

* **mtr on macOS often needs sudo** for ICMP. Use `--sudo`, or switch to TCP probes:

  ```sh
  ./ifspeedtest.sh -i example.com --mtr --mtr-probe tcp --mtr-port 443
  ```
* If a network blocks ICMP, try `--mtr-probe tcp` or `udp`.
* iperf3 can saturate links (especially with high `-P`). Don’t run this on production links without knowing the impact.

---

## Contributing

Contributions are what make the open-source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".

Don't forget to give the project a star! Thanks again!

## License

Distributed under the MIT License. See `LICENSE` for more information.

## Author

I write loops to skip out on life's hoops.

Russell Grapes - [www.grapes.team](https://grapes.team)

Project Link: [https://github.com/russellgrapes/bash-ifspeedtest](https://github.com/russellgrapes/bash-ifspeedtest)
