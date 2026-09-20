# Deployment with Docker Compose

This guide shows a complete example of hosting the SiLabs Multiprotocol
container together with a full Zigbee/Matter stack:

| Service               | Image                                   | Purpose                                        |
|-----------------------|-----------------------------------------|------------------------------------------------|
| `silabs-multiprotocol` | built from the `Dockerfile` in this repo | Zigbee + Thread multiprotocol host (CPCd, zigbeed, OTBR) |
| `matterjs-server`     | `ghcr.io/matter-js/matterjs-server:1.4` | Matter bridge / server (shares network namespace with the multiprotocol container) |
| `mqtt-server`         | `eclipse-mosquitto:2.0.22`              | MQTT broker for Zigbee2MQTT                   |
| `zigbee2mqtt`         | `koenkk/zigbee2mqtt:2.13`               | Zigbee gateway → MQTT                         |

All host-specific values (device path, config file locations, timezone,
IP subnet) are exposed as **environment variables** so you can adapt the
stack to your environment without editing the compose file.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Variables to set](#variables-to-set)
3. [docker-compose.yml](#docker-composeyml)
4. [Example `.env` file](#example-env-file)
5. [Post-deployment configuration](#post-deployment-configuration)
6. [Notes and caveats](#notes-and-caveats)

---

## Prerequisites

- Docker with the Compose plugin
- A built image of this project:

  ```bash
  docker build --platform linux/arm64 -t silabs-multiprotocol:v2026.6.1 .
  ```

  (`pull_policy: never` below assumes a **locally built** image — nothing is
  pulled from a registry.)
- The radio co-processor (e.g. SONOFF Dongle Lite MG21) plugged in,
  flashed with a Multiprotocol (Switchable-PAN / RCP) firmware.
- The three config files for the multiprotocol container
  (`cpcd.conf`, `zigbeed.conf`, `otbr-agent`) prepared on the host —
  see the [main README](../README.md#configuration).
- An `ipvlan` L2 network is used; on most setups `ipvlan` requires the
  host interface to be in a mode that supports it (verify with
  `docker network create -d ipvlan ...` first if unsure).

## Variables to set

| Variable           | Default (if unset)          | Meaning                                                       |
|--------------------|-----------------------------|---------------------------------------------------------------|
| `TZ`               | `Europe/Berlin`             | Timezone for all containers                                   |
| `SILABS_IMAGE_TAG` | `v2026.6.1`                 | Tag of the locally built multiprotocol image                  |
| `USB_DEVICE_ID`    | **required, no default**    | `/dev/serial/by-id/` identifier of your dongle (stable across reboots) |
| `CPCD_CONF`        | `./multipan/cpcd.conf`     | Host path of the CPCd configuration                           |
| `ZIGBEED_CONF`     | `./multipan/zigbeed.conf`   | Host path of the zigbeed configuration                         |
| `OTBR_CONF`        | `./multipan/otbr-agent`     | Host path of the OTBR agent defaults (`OTBR_AGENT_OPTS`)       |
| `IPV4_SUBNET`      | `172.30.0.0/24`            | IPv4 subnet of the internal `ipvlan` network                  |
| `IPV6_SUBNET`      | `fd00:1e::/64`             | IPv6 subnet of the internal `ipvlan` network                   |
| `MQTT_IP`          | `172.30.0.20`              | Static IPv4 of the MQTT broker                                 |
| `ZIGBEE2MQTT_IP`   | `172.30.0.21`              | Static IPv4 of Zigbee2MQTT                                     |
| `SILABS_IP`        | `172.30.0.22`              | Static IPv4 of the multiprotocol container                     |

> If you change the subnet, keep the fixed container IPs inside it and
> update the Zigbee2MQTT serial port accordingly (see
> [Post-deployment configuration](#post-deployment-configuration)).

## docker-compose.yml

```yaml
#----------------------------------------------------------------------------------------------#
# Services
#----------------------------------------------------------------------------------------------#
services:

  #--------------------------------------------------------------------------------------------#
  # Matter
  #--------------------------------------------------------------------------------------------#
  matterjs-server:
    image: ghcr.io/matter-js/matterjs-server:1.4
    restart: unless-stopped
    network_mode: "service:silabs-multiprotocol"  # share namespace with multipan
    environment:
      - TZ=${TZ:-Europe/Berlin}
      - BLE_PROXY=true
    volumes:
      - matter-data:/data

  #--------------------------------------------------------------------------------------------#
  # Zigbee / MQTT
  #--------------------------------------------------------------------------------------------#
  mqtt-server:
    container_name: HomeAssistant-MqttServer
    image: eclipse-mosquitto:2.0.22
    restart: unless-stopped
    volumes:
      - mqtt-data:/mosquitto/data
      - mqtt-log:/mosquitto/log
    command: "mosquitto -c /mosquitto-no-auth.conf"
    networks:
      internal:
        interface_name: eth0
        ipv4_address: ${MQTT_IP:-172.30.0.20}

  zigbee2mqtt:
    container_name: HomeAssistant-Zigbee2Mqtt
    image: koenkk/zigbee2mqtt:2.13
    restart: unless-stopped
    environment:
      - TZ=${TZ:-Europe/Berlin}
    volumes:
      - zigbee2mqtt-data:/app/data
      - /run/udev:/run/udev:ro
    depends_on:
      - mqtt-server
      - silabs-multiprotocol
    networks:
      internal:
        interface_name: eth0
        ipv4_address: ${ZIGBEE2MQTT_IP:-172.30.0.21}

  #--------------------------------------------------------------------------------------------#
  # MultiPan - SONOFF Dongle Lite MG21
  #--------------------------------------------------------------------------------------------#
  silabs-multiprotocol:
    image: silabs-multiprotocol:${SILABS_IMAGE_TAG:-v2026.6.1}
    pull_policy: never
    restart: unless-stopped
    environment:
      - TZ=${TZ:-Europe/Berlin}
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ${CPCD_CONF:-./multipan/cpcd.conf}:/etc/cpcd.conf:ro
      - ${ZIGBEED_CONF:-./multipan/zigbeed.conf}:/usr/local/etc/zigbeed.conf:ro
      - ${OTBR_CONF:-./multipan/otbr-agent}:/etc/default/otbr-agent:ro
      - thread-data:/data/thread
    devices:
      - /dev/net/tun:/dev/net/tun
      - /dev/serial/by-id/${USB_DEVICE_ID:?Set USB_DEVICE_ID in your .env, e.g. usb-Silicon_Labs_...-if00-port0}:/dev/ttyACM0
    sysctls:
      - net.ipv6.conf.all.forwarding=1
    networks:
      internal:
        interface_name: eth0
        ipv4_address: ${SILABS_IP:-172.30.0.22}

#----------------------------------------------------------------------------------------------#
# Volumes
#----------------------------------------------------------------------------------------------#
volumes:
  matter-data:
  thread-data:
  zigbee2mqtt-data:
  mqtt-data:
  mqtt-log:

#----------------------------------------------------------------------------------------------#
# Networks
#----------------------------------------------------------------------------------------------#
networks:
  internal:
    driver: ipvlan
    enable_ipv6: true
    internal: true
    ipam:
      config:
        - subnet: ${IPV4_SUBNET:-172.30.0.0/24}
        - subnet: ${IPV6_SUBNET:-fd00:1e::/64}
```

## Example `.env` file

Place next to `docker-compose.yml`:

```dotenv
# --- General ----------------------------------------------------------------
TZ=Europe/Berlin

# --- Multiprotocol image ------------------------------------------------------
SILABS_IMAGE_TAG=v2026.6.1

# --- USB dongle (find yours with: ls /dev/serial/by-id/) ----------------------
USB_DEVICE_ID=usb-Silicon_Labs_Sonoff_ZBDongle...-if00-port0

# --- Config files (host paths, mounted read-only) -----------------------------
CPCD_CONF=./multipan/cpcd.conf
ZIGBEED_CONF=./multipan/zigbeed.conf
OTBR_CONF=./multipan/otbr-agent

# --- Internal ipvlan network --------------------------------------------------
IPV4_SUBNET=172.30.0.0/24
IPV6_SUBNET=fd00:1e::/64
MQTT_IP=172.30.0.20
ZIGBEE2MQTT_IP=172.30.0.21
SILABS_IP=172.30.0.22
```

Then start the stack:

```bash
docker compose up -d
```

## Post-deployment configuration

### Zigbee2MQTT → multiprotocol container

Zigbee2MQTT must connect to the serial bridge over TCP. Because `ipvlan`
provides no Docker-embedded DNS between containers, use the **static IP**
of the multiprotocol container. In the Zigbee2MQTT configuration
(`zigbee2mqtt-data` volume → `configuration.yaml`):

```yaml
serial:
  port: tcp://172.30.0.22:9627   # = SILABS_IP:ZIGBEE_TCP_PORT (default 9627)
adapter:
  type: ezsp
  baudrate: 115200
```

### Zigbee2MQTT → MQTT

Point Zigbee2MQTT at the broker (e.g. `mqtt://172.30.0.20:1883`) in the
same `configuration.yaml`. The example uses Mosquitto's no-auth config
(`/mosquitto-no-auth.conf`) — for anything beyond an isolated internal
network, configure authentication instead.

### Matter server

`matterjs-server` shares the **network namespace** of
`silabs-multiprotocol` (`network_mode: "service:silabs-multiprotocol"`),
so it reaches the Thread network of the OTBR directly through the
multiprotocol container. Configure the Matter.js server to use the local
OpenThread Border Router; the Thread dataset persists in the
`thread-data` volume (`/data/thread`).

### Verify

```bash
docker compose ps
docker compose exec silabs-multiprotocol ot-ctl state   # leader/router/child/detached
docker compose exec silabs-multiprotocol ps aux           # cpcd, zigbeed, otbr-agent, ...
docker compose logs -f silabs-multiprotocol               # follow startup
```

## Notes and caveats

- **`USB_DEVICE_ID` is mandatory.** The `:?` syntax makes Compose abort
  with a clear error if it is unset, instead of mounting a broken device.
  Using the `/dev/serial/by-id/` path keeps the mapping stable across
  reboots and USB re-enumerations.
- **Device path inside the container is `/dev/ttyACM0`.** Your `cpcd.conf`
  must reference `/dev/ttyACM0` (not the by-id path).
- **`pull_policy: never`** — the `silabs-multiprotocol` image is expected
  to be built locally from this repository. Adjust the image tag with
  `SILABS_IMAGE_TAG` if you built it under a different name.
- **Config mounts are `:ro`** — the container refuses to start
  (`container-init`) if any of the three files is missing.
- **`internal: true` on the network** means containers on the `ipvlan` have
  no external (internet) access; they can only reach each other. The
  `matterjs-server` inherits connectivity through the shared namespace of
  the multiprotocol container — if the Matter server needs internet
  access, remove `internal: true` or give the multiprotocol container
  access to another network.
- **`ipvlan` vs. host setup.** `ipvlan` networks do not allow the host to
  communicate directly with the containers on that interface (L2
  limitation). If you need host → container access (e.g. for Home
  Assistant on the same machine), use a `macvlan` network or a bridge
  network with published ports instead, and adapt the IPs.
- **Stale `thread-data`.** The OTBR dataset is persisted in the
  `thread-data` volume. To reset the Thread network completely
  (new network name, new dataset), remove the volume:
  `docker compose down && docker volume rm <project>_thread-data`.
