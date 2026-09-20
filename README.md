# SiLabs Multiprotocol Container (Zigbee + Thread)

Debian Bookworm based container for the Silicon Labs Multiprotocol solution
(**Zigbee** via `zigbeed` + **Thread** via `otbr-agent`), supervised by
[S6-Overlay](https://github.com/just-containers/s6-overlay), targeting the
Sonoff Dongle Lite MG21 / EFR32MG21 (and other EFR32MG2x co-processors).

- **Dockerfile version:** 0.9.2
- **Silicon Labs SDK (sisdk-release):** `v2026.6.1`
- **S6-Overlay:** `3.2.3.1`
- **Base image:** `debian:bookworm-slim`

---

## Table of Contents

1. [Overview](#overview)
2. [Upstream Sources](#upstream-sources)
3. [Limitations of the Silabs `ot-br-posix` Package](#limitations-of-the-silabs-ot-br-posix-package)
4. [Supported Architectures](#supported-architectures)
5. [Service Tree (S6)](#service-tree-s6)
6. [Configuration](#configuration)
7. [Ports](#ports)
8. [Volumes and Persistence](#volumes-and-persistence)
9. [Healthcheck](#healthcheck)
10. [Building](#building)
11. [Running](#running)
12. [Licensing and Trademark Notice](#licensing-and-trademark-notice)
13. [References](#references)

---

## Overview

The container bundles the Silicon Labs Multiprotocol host stack as Debian
packages taken from the official `sisdk-release` GitHub releases. One radio
co-processor (RCP/NCP, e.g. an EFR32MG21 with a Multiprotocol/Switchable-PAN
firmware) is shared between:

- **Zigbee** — `zigbeed` terminates the EZSP protocol on the CPC bus and
  exposes the radio to Zigbee applications (e.g. Zigbee2MQTT) through
  a PTY pair bridged to TCP port `9627`.
- **Thread** — `otbr-agent` runs the OpenThread Border Router against the
  same radio via CPC, providing a Thread network with border routing.

All processes are supervised by S6-Overlay, which handles startup ordering,
dependency resolution, process restarts and clean shutdown.

### Signal flow

```
                 ┌──────────────────────────────────────────────┐
   EFR32MG21 ──► │ cpcd (CPC daemon over /dev/ttyUSB0 or similar)│
   (RCP/NCP)     └───────────────┬──────────────────┬───────────┘
   via UART/SPI                  │ CPC bus          │ CPC bus
                                 ▼                  ▼
                          ┌────────────┐    ┌──────────────┐
                          │  zigbeed   │    │ otbr-agent   │
                          └─────┬──────┘    └──────┬───────┘
                                │ EZSP             │ wpan0 (Thread)
                                ▼                  ▼
                        /dev/ttyZigbeeNCP   Thread Border Router
                        (PTY bridge via    (border routing, NAT64*)
                         socat, exposed
                         on TCP 9627)
```

\* NAT64 is only available if the `otbr-agent` build enables it — see
[Limitations](#limitations-of-the-silabs-ot-br-posix-package).

---

## Upstream Sources

Everything in this container is built from official, published upstream
artifacts. No code is compiled at image build time; only Debian packages and
release tarballs are downloaded and installed.

### Silicon Labs `sisdk-release` v2026.6.1

Source: <https://github.com/SiliconLabsSoftware/sisdk-release/releases/tag/v2026.6.1>
(asset `debian-bookworm.zip`, ~9.4 MB)

The Dockerfile downloads `debian-bookworm.zip` from this release and installs
the following packages (exact versions shipped in that asset):

| Package        | Version  | Purpose                                                      |
|----------------|----------|--------------------------------------------------------------|
| `libcpc3`      | 4.8.0    | CPC (Co-Processor Communication) client library              |
| `cpcd`         | 4.8.0    | CPC daemon — multiplexes the co-processor bus between clients |
| `ot-br-posix`  | 3.1.1.0  | OpenThread Border Router (`otbr-agent`, `ot-ctl`, `otbr-web`) |
| `zigbeed`      | 9.1.1    | Zigbee daemon — EZSP endpoint over CPC                        |

Upstream projects behind these packages:

- **cpcd / libcpc3:** <https://github.com/SiliconLabsSoftware/cpc-daemon>
- **ot-br-posix:** Silicon Labs maintains a fork of the upstream project
  <https://github.com/openthread/ot-br-posix>; it is hosted inside the
  Silicon Labs SDK under `openthread_stack/util/third_party/ot-br-posix`
  and built against the Silicon Labs OpenThread PAL
  (`protocol/openthread/platform-abstraction/posix/`). Per the Silicon Labs
  OpenThread release notes, the fork is based on upstream `ot-br-posix`
  through ancestor commit `717abf0dc` (OpenThread 3.1.1).
- **zigbeed:** built from the Zigbee stack of the Silicon Labs Simplicity SDK
  (<https://github.com/SiliconLabs/simplicity_sdk>).
- **Package install guide:** <https://docs.silabs.com/openthread/latest/multiprotocol-solution-linux/running-multiprotocol-with-packages>

### S6-Overlay v3.2.3.1

Source: <https://github.com/just-containers/s6-overlay/releases/tag/v3.2.3.1>
(`s6-overlay-noarch.tar.xz` + `s6-overlay-<arch>.tar.xz`)

### Base image

- `debian:bookworm-slim` — <https://hub.docker.com/_/debian>

### Notes on the upstream packages

- The `ot-br-posix` package declares heavy systemd-oriented dependencies
  (`bind9`, `dnsutils`, `iproute2`, `iptables`, `ipset`, `iputils-ping`,
  `nodejs`, `rsyslog`, `radvd`, `sudo`, …). Installing the `.deb` with
  `apt-get install` pulls these in automatically. They are **not used** at
  runtime under S6 (the container runs its own minimal firewall setup and
  does not run systemd, named, rsyslog or radvd), but they are kept in the
  image because `apt-get` resolves the package dependencies.
- The `ot-br-posix` `postinst` hook runs `/usr/share/otbr/script/setup`,
  which requires `lsb_release` — this is why `lsb-release` is installed
  explicitly even though it is not needed at runtime.
- `policy-rc.d` (`exit 101`) is written **before** any package installation
  so that Debian maintainer scripts cannot start systemd services inside
  the build. Under S6 the upstream systemd units (`otbr-agent.service`,
  `otbr-web.service`) are ignored; the container defines its own S6
  services instead.
- The `ot-br-posix` package ships `/usr/share/otbr/script/_firewall`,
  `_nat64`, `_ipforward`, … helper scripts used by the upstream systemd
  packaging. This container intentionally does **not** call them; it
  re-implements the required IPv6 forwarding firewall rules idempotently in
  [`otbr-firewall-up.sh`](#service-tree-s6) instead, so no host state leaks
  into the image assumptions.

---

## Limitations of the Silabs `ot-br-posix` Package

### ⚠️ The REST API is NOT included

The most important limitation of the Silicon Labs `ot-br-posix` Debian
package (and of the Silabs OTBR build in general):

> **The `otbr-agent` binary shipped by Silicon Labs is built WITHOUT the
> OpenThread REST API.** There is no `otbr-rest` service, no `/v1/*`
> HTTP endpoints, and no OpenAPI diagnostics interface.

Details and evidence:

- Upstream `ot-br-posix` can build a REST API server into `otbr-agent`
  (build flag `OTBR_REST=ON`), which serves the standardized
  `http://<host>:8080/v1/*` endpoints (node diagnostics, network info,
  OpenAPI schema at `/v1/openapi.json`), as used for example by the
  Home Assistant OpenThread Border Router REST integration.
- The Silabs `ot-br-agent` binary still contains the **command-line
  options** `--rest-listen-address` (default `127.0.0.1`) and
  `--rest-listen-port` (default `8081`) — they appear in `--help` — but
  **no REST server code is compiled in**: the binary contains no
  `/v1/` endpoint handlers at all. Passing these options is accepted but
  nothing will ever listen on that port.
- Consequently the `OT_REST_LISTEN_ADDR` / `OT_REST_LISTEN_PORT`
  environment variables present in this Dockerfile are **inert
  placeholders**. They are documented for forward-compatibility only, in
  case a future Silabs SDK release enables the REST API. No process in
  this container consumes them today.
- The package does ship `otbr-web` (the Border Router Web GUI,
  `/usr/sbin/otbr-web` with its Angular frontend in
  `/usr/share/otbr-web/frontend`). `otbr-web` serves its **own** small HTTP
  interface (`/available_network`, `/join_network`, `/form_network`,
  `/get_properties`, `/get_qrcode`, `/add_prefix`, `/delete_prefix`).
  These are **not** the standardized OTBR REST API endpoints and are not
  API-stable. This container does not run `otbr-web`; the S6 service tree
  only starts `otbr-agent`.

**Workaround / alternatives for programmatic control:**

- Use the `ot-ctl` CLI inside the container:
  `docker exec <container> ot-ctl state`
- Use the D-Bus interface of `otbr-agent` (the container runs a system
  D-Bus daemon; `otbr-agent` registers
  `io.openthread.BorderRouter` objects on the system bus).
- If you need the REST API specifically (e.g. for Home Assistant's
  `openthread_border_router` REST integration), you must build
  `ot-br-posix` yourself with `OTBR_REST=ON` following the Silicon Labs
  guide
  ([Building OTBR locally](https://docs.silabs.com/openthread/latest/multiprotocol-solution-linux/building-otbr-locally))
  — the official Silabs `.deb` packages cannot be used for that.

### Other limitations of the package set

- **systemd-centric packaging.** The `.deb` files install systemd units and
  run a system-mutating `postinst` (`/usr/share/otbr/script/setup`). This
  container works around that with `policy-rc.d` and by ignoring the
  systemd units; S6 services replace them.
- **No `otbr-rest` / OpenAPI** — see above.
- **armhf `dhcpcd` requirement.** On 32-bit `armhf`, the `ot-br-posix`
  package requires `dhcpcd-base` ≥ 9.5.1 (bookworm ships 9.4.1-24, which
  has a known startup issue). The Dockerfile therefore pins
  `dhcpcd-base` from `bookworm-backports` (10.1.0) for `arm` builds only.
- **Web GUI not started.** `otbr-web` is installed by the package but not
  supervised by this container. Thread commissioning must be done through
  `ot-ctl` (e.g. the `otbr-init` oneshot already forms/commits a dataset
  automatically) or D-Bus.
- **DNS upstream.** The Silabs `otbr-agent` binary logs
  `DNS upstream ... ignored; build with OTBR_NCP_DNS_UPSTREAM=ON` when
  used in NCP mode without upstream DNS forwarding — DNS64/NAT64 behavior
  depends on the build flags Silicon Labs chose; verify on your target
  before relying on NAT64 in the Thread network.
- **Evaluation status.** Silicon Labs describes the Debian packages as
  evaluation host application packages; qualify them for your use case
  before production deployment.

---

## Supported Architectures

| `TARGETARCH` | `TARGETVARIANT` | S6 arch  | SDK `.deb` arch |
|--------------|-----------------|----------|-----------------|
| `amd64`      | —               | `x86_64` | `amd64`         |
| `arm64`      | —               | `aarch64`| `arm64`          |
| `arm`        | `v7`            | `armhf`  | `armhf`         |
| `arm`        | `v6` (or none)  | `arm`    | `armhf`         |

The build fails for any other platform combination.

---

## Service Tree (S6)

```
container-init (oneshot)          – runtime dirs, config checks, /var/lib/thread symlink
├── base
├── dbus (longrun)                – system D-Bus (stale pid/socket cleanup each start)
│   └── avahi-daemon (longrun)    – mDNS (waits for D-Bus socket)
├── cpcd (longrun)                – CPC daemon, /etc/cpcd.conf
│   └── cpcd-ready (oneshot)      – waits until cpcd process is up
│       ├── zigbeed-socat (longrun) – PTY pair /dev/ttyZigbeeNCP ↔ /tmp/ttyZigbeeNCP
│       │   └── zigbeed (longrun)  – EZSP daemon, /usr/local/etc/zigbeed.conf
│       │       └── zigbee2mqtt-tcp-bridge (longrun) – TCP 9627 → /dev/ttyZigbeeNCP
│       └── otbr-agent (longrun)  – OTBR agent, /etc/default/otbr-agent
│           └── otbr-init (oneshot) – dataset/ifconfig/thread start (idempotent)
└── otbr-firewall (oneshot)       – ip6tables/ipset rules (up on start, down on stop)
```

Startup-ordering highlights:

- `cpcd-ready` gates everything that talks to the radio.
- `zigbeed` requires the socat PTY bridge to exist first.
- `otbr-agent` additionally depends on the firewall oneshot and on
  `avahi-daemon` (for mDNS/Browser support).
- `otbr-init` runs **after** `otbr-agent` is up: it waits for
  `ot-ctl`, checks (and only if needed creates) the active dataset,
  brings `wpan0` up and starts Thread. It is idempotent — on restart with
  an existing dataset (persisted in `/data/thread`) nothing is re-created.

---

## Configuration

The container expects **three config files to be mounted read-only**. It
refuses to start (via `container-init`) if any of them is missing:

| Container path                    | Purpose                                     |
|-----------------------------------|---------------------------------------------|
| `/etc/cpcd.conf`                  | CPCd configuration (UART device, baud, …)   |
| `/usr/local/etc/zigbeed.conf`    | zigbeed configuration (EZSP channel, …)     |
| `/etc/default/otbr-agent`         | `OTBR_AGENT_OPTS` radio-URL and flags       |

Example `/etc/default/otbr-agent` (matches the upstream package default,
adjusted for CPC):

```
OTBR_AGENT_OPTS="-I wpan0 -B eth0 spinel+cpc://adapter0 trel://eth0"
```

Refer to the Silicon Labs Multiprotocol documentation for the exact
radio-URL of your setup.

### Environment variables

| Variable               | Default    | Description                                   |
|------------------------|------------|-----------------------------------------------|
| `ZIGBEE_TCP_PORT`      | `9627`     | TCP port of the Zigbee serial bridge          |
| `OT_THREAD_IF`          | `wpan0`    | Thread interface name                         |
| `OT_INFRA_IF`          | `eth0`     | Infrastructure (backbone) interface          |
| `OT_REST_LISTEN_ADDR`  | `0.0.0.0`  | ⚠️ inert — REST API not built in (see above)  |
| `OT_REST_LISTEN_PORT`  | `8081`     | ⚠️ inert — REST API not built in (see above)  |
| `OTBR_INIT_TIMEOUT`    | `60`       | Seconds `otbr-init` waits for `ot-ctl`       |
| `CPC_READY_TIMEOUT`    | `60`       | Seconds `cpcd-ready` waits for the CPC daemon|

---

## Ports

| Port   | Protocol | Purpose                                        |
|--------|----------|------------------------------------------------|
| `9627` | TCP      | Zigbee EZSP serial bridge (for Zigbee2MQTT etc.)|

Thread itself operates on `wpan0` inside the container and requires the
container to run with `--privileged` or appropriate capabilities
(`NET_ADMIN`, `NET_RAW`) plus `--sysctl` settings for IPv6 forwarding,
since border routing modifies interface and route state.

> There is deliberately **no REST API port** (upstream OTBR usually uses
> `8080`/`8081`) because the Silabs `otbr-agent` build does not include
> the REST server — see
> [Limitations](#limitations-of-the-silabs-ot-br-posix-package).

---

## Volumes and Persistence

| Volume         | Purpose                                                        |
|----------------|----------------------------------------------------------------|
| `/data/thread` | OTBR persistent state (active Thread dataset, etc.)            |

At startup `container-init` symlinks `/var/lib/thread → /data/thread` so
the OTBR dataset survives container recreation. If `/var/lib/thread`
exists as a non-empty directory it is moved to `/var/lib/thread.orig`
before the symlink is created.

---

## Healthcheck

`/usr/local/bin/healthcheck.sh` runs every 30 s (120 s start period,
3 retries) and verifies:

- `cpcd`, `zigbeed` and `otbr-agent` processes are running
- both EZSP PTY links exist (`/dev/ttyZigbeeNCP`, `/tmp/ttyZigbeeNCP`)
- the Thread interface (`wpan0`) exists
- the Zigbee TCP bridge accepts connections on `127.0.0.1:9627`
- the Thread state is `leader`/`router`/`child`/`detached`

---

## Building

```bash
docker build --platform linux/arm64 -t silabs-multiprotocol:v2026.6.1 .
```

Build arguments (override with `--build-arg`):

| Arg                    | Default     | Description                     |
|------------------------|-------------|---------------------------------|
| `SISDK_VERSION`        | `v2026.6.1` | sisdk-release tag               |
| `S6_OVERLAY_VERSION`   | `3.2.3.1`   | S6-Overlay release              |

`TARGETARCH`/`TARGETVARIANT` are provided automatically by BuildKit.

---

## Running

Minimal example (arm64 host, radio on `/dev/ttyUSB0`):

```bash
docker run -d \
  --name silabs-multiprotocol \
  --privileged \
  --network host \
  --device /dev/ttyUSB0:/dev/ttyUSB0 \
  -v silabs-thread-data:/data/thread \
  -v ./cpcd.conf:/etc/cpcd.conf:ro \
  -v ./zigbeed.conf:/usr/local/etc/zigbeed.conf:ro \
  -v ./otbr-agent:/etc/default/otbr-agent:ro \
  silabs-multiprotocol:v2026.6.1
```

Then point Zigbee2MQTT at `tcp://<host>:9627` and manage Thread via
`docker exec silabs-multiprotocol ot-ctl …`.

---

## Licensing and Trademark Notice

### No affiliation

This project is **not affiliated with, endorsed by, or sponsored by
Silicon Laboratories Inc.** "Silicon Labs", "SiLabs", "Simplicity SDK",
"Gecko SDK", EFR32 and related names are trademarks of Silicon Laboratories
Inc. All product names and trademarks are the property of their respective
owners and are used here for identification purposes only.

### License situation of the redistributed packages

This repository contains **only build instructions** (a Dockerfile) and
documentation. **No Silicon Labs binaries or source code are stored in this
repository.** All third-party software is downloaded at image build time from
the official upstream sources listed in
[Upstream Sources](#upstream-sources).

The packages installed by the Dockerfile carry **different licenses** — the
important distinction is between the build recipe and the built image:

| Component                        | License            | Notes                          |
|----------------------------------|--------------------|--------------------------------|
| This repository (Dockerfile, docs)| yours to choose    | No third-party code included   |
| `debian:bookworm-slim` + apt pkgs | DFSG-free (GPL, etc.) | via official Debian repos  |
| `s6-overlay`                    | BSD-3-Clause       | permissive                      |
| `libcpc3` / `cpcd` 4.8.0         | Silicon Labs MSLA  | **not** open source             |
| `ot-br-posix` 3.1.1.0            | Silicon Labs MSLA  | **not** open source             |
| `zigbeed` 9.1.1                  | Silicon Labs MSLA  | **not** open source             |

The **Silicon Labs Master Software License Agreement (MSLA)**
(<https://www.silabs.com/about-us/legal/master-software-license-agreement>)
is a proprietary source-available/license agreement, *not* an open-source
license. By downloading the packages at build time, **each builder accepts
the MSLA directly with Silicon Labs** — that is exactly why this project
distributes a Dockerfile rather than pre-built images.

Key MSLA conditions relevant to this container (summarized, non-authoritative;
read the full agreement yourself):

- Software is licensed for use **in conjunction with Silicon Labs Devices**
  (Authorized Applications), not on a standalone basis.
- Object code may only be distributed to end-user customers **incorporated
  into Authorized Applications** (§4.1.6) — not as a freely downloadable
  standalone artifact.
- Sublicensing/transfer to third parties is prohibited (§5.1.1); end-user
  restrictions must be passed down (§5.4).
- Redistributing the packages **under an open-source license is prohibited**
  (§5.1.3, §7.3.1). This Dockerfile and this repository therefore deliberately
  carry **no open-source license header claim over the downloaded packages**
  and must not be represented as making them open source.
- Copyright/proprietary notices shipped in the packages must not be removed
  (§5.1.6) — this image installs the `.deb` files unmodified and strips no
  notice files.
- The MSLA excludes "Unauthorized Use" (aerospace, medical Class III,
  implantable, life-support, automotive) — do not deploy this container in
  such contexts.

### ⚠️ Do not publish pre-built images without permission

Because of the MSLA terms above:

> **Do not push the built container image to a public registry.**
> Building the image is intended for **personal/internal use with your own
> Silicon Labs hardware**. Public redistribution of a ready-made image is
> outside what the MSLA clearly permits for a third party and would require
> written permission from Silicon Labs.

If you need image distribution beyond your own systems, contact Silicon Labs
support first. (Note that Silicon Labs themselves previously offered an
official `silabsinc/multiprotocol` container and have since deprecated it in
favor of the self-built Debian packages this project uses — that is the
distribution model intended by Silicon Labs.)

### Disclaimer

THE DOCKERFILE, SCRIPTS AND DOCUMENTATION IN THIS REPOSITORY ARE PROVIDED
"AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED. THE AUTHOR(S) ARE
NOT LIABLE FOR ANY DAMAGES ARISING FROM THE USE OF THIS SOFTWARE OR THE
RESULTING CONTAINER IMAGE. THE SILICON LABS PACKAGES ARE PROVIDED "AS IS"
UNDER THE MSLA. THIS PROJECT IS NOT LEGAL ADVICE; CONSULT A LAWYER REGARDING
YOUR PARTICULAR REDISTRIBUTION OR DEPLOYMENT SCENARIO.

---

## References

- Silicon Labs Multiprotocol on Linux (packages guide):
  <https://docs.silabs.com/openthread/latest/multiprotocol-solution-linux/running-multiprotocol-with-packages>
- Silicon Labs Multiprotocol on Linux (building OTBR locally, incl. `OTBR_REST`):
  <https://docs.silabs.com/openthread/latest/multiprotocol-solution-linux/building-otbr-locally>
- Silicon Labs OpenThread release notes:
  <https://docs.silabs.com/openthread/latest/sisdk-ot-release-notes/>
- `sisdk-release` (package source):
  <https://github.com/SiliconLabsSoftware/sisdk-release>
- `cpc-daemon`:
  <https://github.com/SiliconLabsSoftware/cpc-daemon>
- Upstream `ot-br-posix`:
  <https://github.com/openthread/ot-br-posix>
- S6-Overlay:
  <https://github.com/just-containers/s6-overlay>
