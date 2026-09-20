# syntax=docker/dockerfile:1

# =============================================================================
# SiLabs Multiprotocol Container (Zigbee + Thread) mit S6-Overlay
# Basis: Debian Bookworm + S6-Overlay v3.2.3.1
# Ziel: Sonoff Dongle Lite MG21 / EFR32MG21
#
# Version: 0.9.2
# =============================================================================

FROM debian:bookworm-slim

# -----------------------------------------------------------------------------
# Metadata
# -----------------------------------------------------------------------------

LABEL maintainer="Atlas192"
LABEL description="SiLabs Multiprotocol Container (OTBR + Zigbeed) für MG21 mit S6-Overlay"
LABEL notes="Build: docker build --platform linux/arm64 -t silabs-multiprotocol:v2026.6.1 ."

# -----------------------------------------------------------------------------
# Persistente Daten
# -----------------------------------------------------------------------------
#
# Thread-Daten werden unter /data/thread gehalten. Der Container symlinkt
# /var/lib/thread -> /data/thread, damit OTBR das Dataset dort ablegt.
#
# Konfigurationsdateien werden NICHT als VOLUME definiert.
# Sie werden extern als :ro Mount eingebunden:
#
#   /etc/cpcd.conf
#   /usr/local/etc/zigbeed.conf
#   /etc/default/otbr-agent
#

VOLUME /data/thread

# -----------------------------------------------------------------------------
# Ports
# -----------------------------------------------------------------------------

EXPOSE 9627

# -----------------------------------------------------------------------------
# Build-Argumente
# -----------------------------------------------------------------------------

ENV DOCKER=1

ARG DEBIAN_FRONTEND=noninteractive
ARG SISDK_VERSION=v2026.6.1
ARG S6_OVERLAY_VERSION=3.2.3.1
ARG TARGETARCH
ARG TARGETVARIANT

# -----------------------------------------------------------------------------
# Runtime Defaults
# -----------------------------------------------------------------------------

ENV ZIGBEE_TCP_PORT=9627

ENV OT_THREAD_IF=wpan0
ENV OT_INFRA_IF=eth0
ENV OT_REST_LISTEN_ADDR=0.0.0.0
ENV OT_REST_LISTEN_PORT=8081

# Timeout für otbr-init (Sekunden)
ENV OTBR_INIT_TIMEOUT=60
# Timeout für cpcd-ready (Sekunden)
ENV CPC_READY_TIMEOUT=60

# -----------------------------------------------------------------------------
# Basis-System
#
# lsb-release wird vom ot-br-posix postinst-Script zwingend benötigt,
# obwohl es zur Laufzeit nicht gebraucht wird.
# -----------------------------------------------------------------------------

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        jq \
        unzip \
        xz-utils \
        iproute2 \
        iptables \
        ipset \
        socat \
        dbus \
        avahi-daemon \
        libnss-mdns \
        procps \
        lsb-release \
        util-linux \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Bookworm Backports nur für armhf
# -----------------------------------------------------------------------------

RUN set -eux; \
    case "${TARGETARCH}" in \
        arm) \
            echo "[BUILD] Adding bookworm-backports for armhf..."; \
            printf '%s\n' \
                'deb http://deb.debian.org/debian bookworm-backports main' \
                > /etc/apt/sources.list.d/bookworm-backports.list; \
            printf '%s\n' \
                'Package: dhcpcd-base' \
                'Pin: release n=bookworm-backports' \
                'Pin-Priority: 1001' \
                > /etc/apt/preferences.d/bookworm-backports; \
            apt-get update; \
            apt-get install -y --no-install-recommends \
                dhcpcd-base; \
            apt-get clean; \
            rm -rf /var/lib/apt/lists/*; \
            ;; \
        *) \
            echo "[BUILD] Skipping bookworm-backports for TARGETARCH=${TARGETARCH}"; \
            ;; \
    esac

# -----------------------------------------------------------------------------
# S6-Overlay installieren
# -----------------------------------------------------------------------------

RUN set -eux; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
        amd64)      S6_ARCH=x86_64 ;; \
        arm64)      S6_ARCH=aarch64 ;; \
        armv7)      S6_ARCH=armhf ;; \
        armv6|arm)  S6_ARCH=arm ;; \
        *) \
            echo "ERROR: Unsupported TARGETARCH=${TARGETARCH} TARGETVARIANT=${TARGETVARIANT}" >&2; \
            exit 1 \
            ;; \
    esac; \
    \
    echo "[BUILD] TARGETARCH=${TARGETARCH} TARGETVARIANT=${TARGETVARIANT} -> S6_ARCH=${S6_ARCH}"; \
    \
    mkdir -p /tmp/s6-overlay; \
    \
    curl -fL --retry 5 --retry-delay 5 \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
        -o /tmp/s6-overlay/noarch.tar.xz; \
    \
    tar -xJf /tmp/s6-overlay/noarch.tar.xz -C /; \
    \
    curl -fL --retry 5 --retry-delay 5 \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
        -o "/tmp/s6-overlay/${S6_ARCH}.tar.xz"; \
    \
    tar -xJf "/tmp/s6-overlay/${S6_ARCH}.tar.xz" -C /; \
    \
    rm -rf /tmp/s6-overlay; \
    \
    echo "[BUILD] S6-Overlay v${S6_OVERLAY_VERSION} installed"

# -----------------------------------------------------------------------------
# policy-rc.d vor jeglicher Paketinstallation setzen
# -----------------------------------------------------------------------------

RUN printf '%s\n' \
        '#!/bin/sh' \
        'exit 101' \
        > /usr/sbin/policy-rc.d && \
    chmod 755 /usr/sbin/policy-rc.d

# -----------------------------------------------------------------------------
# Silicon Labs SDK herunterladen
# -----------------------------------------------------------------------------

RUN set -eux; \
    mkdir -p /opt/silabs/sisdk; \
    \
    API_URL="https://api.github.com/repos/SiliconLabsSoftware/sisdk-release/releases/tags/${SISDK_VERSION}"; \
    \
    echo "[BUILD] Querying Silicon Labs SDK ${SISDK_VERSION}"; \
    RELEASE_JSON="$(curl -fsSL --retry 5 --retry-delay 5 "${API_URL}")"; \
    \
    DOWNLOAD_URL="$(printf '%s' "${RELEASE_JSON}" \
        | jq -r '.assets[] | select(.name == "debian-bookworm.zip") | .browser_download_url' \
        | head -n 1)"; \
    \
    test -n "${DOWNLOAD_URL}" || { \
        echo "ERROR: debian-bookworm.zip für Silicon Labs SDK ${SISDK_VERSION} nicht gefunden" >&2; \
        exit 1; \
    }; \
    \
    echo "[BUILD] Downloading Silicon Labs SDK ${SISDK_VERSION}"; \
    \
    curl -fL --retry 5 --retry-delay 5 \
        "${DOWNLOAD_URL}" \
        -o /tmp/debian-bookworm.zip; \
    \
    unzip -q /tmp/debian-bookworm.zip \
        -d /opt/silabs/sisdk; \
    \
    rm -f /tmp/debian-bookworm.zip; \
    \
    test -d /opt/silabs/sisdk/debian-bookworm/deb || { \
        echo "ERROR: SDK Debian package directory not found" >&2; \
        find /opt/silabs/sisdk -maxdepth 4 -type d -print; \
        exit 1; \
    }

# -----------------------------------------------------------------------------
# Silicon Labs Pakete installieren und SDK-Verzeichnis entfernen
# -----------------------------------------------------------------------------

RUN set -eux; \
    DEB_DIR="/opt/silabs/sisdk/debian-bookworm/deb"; \
    \
    case "${TARGETARCH}" in \
        amd64) ARCH=amd64 ;; \
        arm64) ARCH=arm64 ;; \
        arm)   ARCH=armhf ;; \
        *) \
            echo "ERROR: Unsupported TARGETARCH=${TARGETARCH}" >&2; \
            exit 1 \
            ;; \
    esac; \
    \
    echo "[BUILD] Searching Silicon Labs SDK ${SISDK_VERSION} packages for ARCH=${ARCH}"; \
    \
    CPC_LIB="$(find "${DEB_DIR}" -maxdepth 1 -type f \
        -name "libcpc3_*_${ARCH}.deb" -print | sort -V | tail -n 1)"; \
    \
    CPCD_PKG="$(find "${DEB_DIR}" -maxdepth 1 -type f \
        -name "cpcd_*_${ARCH}.deb" -print | sort -V | tail -n 1)"; \
    \
    OTBR_PKG="$(find "${DEB_DIR}" -maxdepth 1 -type f \
        -name "ot-br-posix_*_${ARCH}.deb" -print | sort -V | tail -n 1)"; \
    \
    ZIGBEE_PKG="$(find "${DEB_DIR}" -maxdepth 1 -type f \
        -name "zigbeed_*_${ARCH}.deb" -print | sort -V | tail -n 1)"; \
    \
    test -n "${CPC_LIB}"   || { echo "ERROR: libcpc3 package not found" >&2; exit 1; }; \
    test -n "${CPCD_PKG}"  || { echo "ERROR: cpcd package not found" >&2; exit 1; }; \
    test -n "${OTBR_PKG}"  || { echo "ERROR: ot-br-posix package not found" >&2; exit 1; }; \
    test -n "${ZIGBEE_PKG}"|| { echo "ERROR: zigbeed package not found" >&2; exit 1; }; \
    \
    echo "[BUILD] Installing SDK ${SISDK_VERSION} packages:"; \
    echo "  ${CPC_LIB}"; \
    echo "  ${CPCD_PKG}"; \
    echo "  ${OTBR_PKG}"; \
    echo "  ${ZIGBEE_PKG}"; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "${CPC_LIB}" \
        "${CPCD_PKG}" \
        "${OTBR_PKG}" \
        "${ZIGBEE_PKG}"; \
    \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    rm -rf /opt/silabs/sisdk; \
    \
    command -v cpcd; \
    command -v zigbeed; \
    command -v otbr-agent; \
    command -v ot-ctl

# -----------------------------------------------------------------------------
# Runtime-Verzeichnisse
# -----------------------------------------------------------------------------

RUN mkdir -p \
    /usr/local/bin \
    /usr/local/etc \
    /data/thread \
    /var/log/cpcd \
    /var/log/zigbeed \
    /var/log/otbr-agent \
    /dev/shm/cpcd \
    /run/s6-linux-init-container-results

# -----------------------------------------------------------------------------
# Container Initialization
# -----------------------------------------------------------------------------

RUN cat > /usr/local/bin/container-init.sh <<'EOF'
#!/bin/bash
set -eu

mkdir -p \
    /run/dbus \
    /run/avahi-daemon \
    /dev/shm/cpcd \
    /var/log/cpcd \
    /var/log/zigbeed \
    /var/log/otbr-agent \
    /data/thread \
    /run/s6-linux-init-container-results

chmod 755 /run/dbus
chmod 755 /run/avahi-daemon
chmod 755 /dev/shm/cpcd

# Beim Container-Neustart können stale D-Bus-Dateien zurückbleiben.
# Diese führen dazu, dass dbus-daemon mit
#   "The pid file '/run/dbus/pid' exists ..."
# abbricht. Daher vor jedem Start entfernen.
rm -f /run/dbus/pid
rm -f /run/dbus/system_bus_socket

echo "[INIT] cpcd.conf    : /etc/cpcd.conf"
echo "[INIT] zigbeed.conf : /usr/local/etc/zigbeed.conf"
echo "[INIT] otbr-agent   : /etc/default/otbr-agent"

test -f /etc/cpcd.conf || {
    echo "ERROR: /etc/cpcd.conf fehlt." >&2
    exit 1
}

test -f /usr/local/etc/zigbeed.conf || {
    echo "ERROR: /usr/local/etc/zigbeed.conf fehlt." >&2
    exit 1
}

test -f /etc/default/otbr-agent || {
    echo "ERROR: /etc/default/otbr-agent fehlt." >&2
    exit 1
}

# Persistente OTBR-Daten
mkdir -p /data/thread

# /var/lib/thread nur dann ersetzen, wenn es sich nicht bereits um
# den erwarteten Symlink auf /data/thread handelt.
if [ -L /var/lib/thread ]; then
    current_target="$(readlink /var/lib/thread || true)"
    if [ "${current_target}" != "/data/thread" ]; then
        rm -f /var/lib/thread
        ln -s /data/thread /var/lib/thread
    fi
elif [ -e /var/lib/thread ]; then
    if [ -z "$(ls -A /var/lib/thread 2>/dev/null)" ]; then
        rmdir /var/lib/thread
        ln -s /data/thread /var/lib/thread
    else
        echo "[INIT] WARN: /var/lib/thread enthält Daten, wird nach /var/lib/thread.orig verschoben"
        mv /var/lib/thread /var/lib/thread.orig
        ln -s /data/thread /var/lib/thread
    fi
else
    ln -s /data/thread /var/lib/thread
fi

echo "[INIT] Runtime initialization complete"
EOF

RUN chmod 755 /usr/local/bin/container-init.sh

# -----------------------------------------------------------------------------
# CPCd Readiness
# -----------------------------------------------------------------------------

RUN cat > /usr/local/bin/wait-for-cpcd.sh <<'EOF'
#!/bin/bash
set -eu

TIMEOUT="${CPC_READY_TIMEOUT:-60}"

echo "[CPCD-READY] Waiting for CPCd ..."

elapsed=0

while [ "${elapsed}" -lt "${TIMEOUT}" ]; do
    if pidof cpcd >/dev/null 2>&1; then
        echo "[CPCD-READY] CPCd process is running"
        exit 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
done

echo "[CPCD-READY] ERROR: CPCd did not start within ${TIMEOUT}s" >&2
exit 1
EOF

RUN chmod 755 /usr/local/bin/wait-for-cpcd.sh

# -----------------------------------------------------------------------------
# OTBR Thread Initialization
#
# Führt die CNTR-Sequenz idempotent aus:
#
#   1. Warten bis ot-ctl mit otbr-agent kommunizieren kann
#   2. Aktives Dataset prüfen, nur bei Bedarf neu anlegen
#   3. Interface (wpan0) hochfahren, falls down
#   4. Thread starten, falls disabled
#
# Wichtig:
#   - ot-ctl liefert CRLF-terminierte Ausgaben. Das \r muss entfernt
#     werden, sonst schlagen Stringvergleiche fehl.
#   - ot-ctl liefert Exit-Code 0 auch bei logischen Fehlern wie
#     "Error 23: NotFound". Fehler müssen in der Ausgabe geprüft werden.
# -----------------------------------------------------------------------------

RUN cat > /usr/local/bin/otbr-init.sh <<'EOF'
#!/bin/bash
set -eu

TIMEOUT="${OTBR_INIT_TIMEOUT:-60}"
THREAD_IF="${OT_THREAD_IF:-wpan0}"

# ---------------------------------------------------------------------------
# Helper: ot-ctl Ausgabe bereinigen (CR entfernen)
# ---------------------------------------------------------------------------

ot_ctl_clean() {
    ot-ctl "$@" 2>/dev/null | tr -d '\r' || true
}

ot_ctl_first_line() {
    ot_ctl_clean "$@" | head -n 1
}

# ---------------------------------------------------------------------------
# 1. Auf otbr-agent warten
# ---------------------------------------------------------------------------

echo "[OTBR-INIT] Waiting for ot-ctl / otbr-agent ..."

elapsed=0
while ! ot-ctl state >/dev/null 2>&1; do
    if [ "${elapsed}" -ge "${TIMEOUT}" ]; then
        echo "[OTBR-INIT] ERROR: ot-ctl not reachable within ${TIMEOUT}s" >&2
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

# ---------------------------------------------------------------------------
# 2. Aktuellen Zustand erfassen (bereinigt)
# ---------------------------------------------------------------------------

STATE="$(ot_ctl_first_line state)"
IFCONFIG="$(ot_ctl_first_line ifconfig)"

STATE="${STATE:-disabled}"
IFCONFIG="${IFCONFIG:-down}"

echo "[OTBR-INIT] Current state: '${STATE}', ifconfig: '${IFCONFIG}'"

# ---------------------------------------------------------------------------
# 3. Dataset sicherstellen
#
#    ot-ctl gibt bei fehlendem Dataset NICHT Exit-Code != 0 zurueck,
#    sondern schreibt "Error 23: NotFound" in die Ausgabe. Daher
#    Ausgabe pruefen.
# ---------------------------------------------------------------------------

DATASET_PROBE="$(ot_ctl_clean dataset active)"

if echo "${DATASET_PROBE}" | grep -q "Error"; then
    echo "[OTBR-INIT] No active dataset found - creating new one"
    ot-ctl dataset init new
    ot-ctl dataset commit active
    echo "[OTBR-INIT] New dataset committed"
else
    echo "[OTBR-INIT] Active dataset present - keeping it"
fi

# ---------------------------------------------------------------------------
# 4. Interface hochfahren
# ---------------------------------------------------------------------------

if [ "${IFCONFIG}" != "up" ]; then
    echo "[OTBR-INIT] Bringing up ${THREAD_IF}"
    ot-ctl ifconfig up
else
    echo "[OTBR-INIT] ${THREAD_IF} already up"
fi

# ---------------------------------------------------------------------------
# 5. Thread starten
# ---------------------------------------------------------------------------

if [ "${STATE}" = "disabled" ]; then
    echo "[OTBR-INIT] Starting Thread"
    ot-ctl thread start
else
    echo "[OTBR-INIT] Thread already started (state='${STATE}')"
fi

# ---------------------------------------------------------------------------
# 6. Endzustand pruefen
# ---------------------------------------------------------------------------

sleep 3

FINAL_STATE="$(ot_ctl_first_line state)"
FINAL_STATE="${FINAL_STATE:-unknown}"

echo "[OTBR-INIT] Final state: '${FINAL_STATE}'"

case "${FINAL_STATE}" in
    leader|router|child|detached)
        echo "[OTBR-INIT] Thread initialization complete"
        ;;
    disabled)
        echo "[OTBR-INIT] ERROR: Thread failed to start (state=disabled)" >&2
        exit 1
        ;;
    *)
        echo "[OTBR-INIT] ERROR: Unexpected state: '${FINAL_STATE}'" >&2
        exit 1
        ;;
esac
EOF

RUN chmod 755 /usr/local/bin/otbr-init.sh

# -----------------------------------------------------------------------------
# OTBR Firewall (up)
# -----------------------------------------------------------------------------

RUN cat > /usr/local/bin/otbr-firewall-up.sh <<'EOF'
#!/bin/bash
set -eu

THREAD_IF="${OT_THREAD_IF:-wpan0}"

echo "[OTBR-FIREWALL] Starting firewall for ${THREAD_IF}"

ipset create -exist otbr-ingress-deny-src       hash:net family inet6
ipset create -exist otbr-ingress-deny-src-swap  hash:net family inet6
ipset create -exist otbr-ingress-allow-dst      hash:net family inet6
ipset create -exist otbr-ingress-allow-dst-swap hash:net family inet6

if ! ip6tables -w -L OTBR_FORWARD_INGRESS -n >/dev/null 2>&1; then
    ip6tables -w -N OTBR_FORWARD_INGRESS
fi

if ! ip6tables -w -C FORWARD -o "${THREAD_IF}" -j OTBR_FORWARD_INGRESS 2>/dev/null; then
    ip6tables -w -I FORWARD 1 -o "${THREAD_IF}" -j OTBR_FORWARD_INGRESS
fi

if ! ip6tables -w -L OTBR_FORWARD_EGRESS -n >/dev/null 2>&1; then
    ip6tables -w -N OTBR_FORWARD_EGRESS
fi

if ! ip6tables -w -C FORWARD -i "${THREAD_IF}" -j OTBR_FORWARD_EGRESS 2>/dev/null; then
    ip6tables -w -I FORWARD 1 -i "${THREAD_IF}" -j OTBR_FORWARD_EGRESS
fi

if ! ip6tables -w -C OTBR_FORWARD_EGRESS -j ACCEPT 2>/dev/null; then
    ip6tables -w -A OTBR_FORWARD_EGRESS -j ACCEPT
fi

if ! ip6tables -w -C OTBR_FORWARD_INGRESS \
        -m set --match-set otbr-ingress-deny-src src -j DROP 2>/dev/null; then
    ip6tables -w -A OTBR_FORWARD_INGRESS \
        -m set --match-set otbr-ingress-deny-src src -j DROP
fi

if ! ip6tables -w -C OTBR_FORWARD_INGRESS \
        -m set --match-set otbr-ingress-allow-dst dst -j ACCEPT 2>/dev/null; then
    ip6tables -w -A OTBR_FORWARD_INGRESS \
        -m set --match-set otbr-ingress-allow-dst dst -j ACCEPT
fi

if ! ip6tables -w -C OTBR_FORWARD_INGRESS -j ACCEPT 2>/dev/null; then
    ip6tables -w -A OTBR_FORWARD_INGRESS -j ACCEPT
fi

echo "[OTBR-FIREWALL] Firewall initialized"
EOF

RUN chmod 755 /usr/local/bin/otbr-firewall-up.sh

# -----------------------------------------------------------------------------
# OTBR Firewall (down)
# -----------------------------------------------------------------------------

RUN cat > /usr/local/bin/otbr-firewall-down.sh <<'EOF'
#!/bin/bash
set +e

THREAD_IF="${OT_THREAD_IF:-wpan0}"

while ip6tables -w -C FORWARD -o "${THREAD_IF}" -j OTBR_FORWARD_INGRESS 2>/dev/null; do
    ip6tables -w -D FORWARD -o "${THREAD_IF}" -j OTBR_FORWARD_INGRESS
done

while ip6tables -w -C FORWARD -i "${THREAD_IF}" -j OTBR_FORWARD_EGRESS 2>/dev/null; do
    ip6tables -w -D FORWARD -i "${THREAD_IF}" -j OTBR_FORWARD_EGRESS
done

if ip6tables -w -L OTBR_FORWARD_INGRESS -n >/dev/null 2>&1; then
    ip6tables -w -F OTBR_FORWARD_INGRESS
    ip6tables -w -X OTBR_FORWARD_INGRESS
fi

if ip6tables -w -L OTBR_FORWARD_EGRESS -n >/dev/null 2>&1; then
    ip6tables -w -F OTBR_FORWARD_EGRESS
    ip6tables -w -X OTBR_FORWARD_EGRESS
fi

ipset destroy otbr-ingress-deny-src       2>/dev/null || true
ipset destroy otbr-ingress-deny-src-swap  2>/dev/null || true
ipset destroy otbr-ingress-allow-dst      2>/dev/null || true
ipset destroy otbr-ingress-allow-dst-swap 2>/dev/null || true
EOF

RUN chmod 755 /usr/local/bin/otbr-firewall-down.sh

# -----------------------------------------------------------------------------
# Healthcheck (als Bash-Script, damit /dev/tcp funktioniert)
# -----------------------------------------------------------------------------

RUN cat > /usr/local/bin/healthcheck.sh <<'EOF'
#!/bin/bash
set -u

fail() {
    echo "[HEALTH] FAIL: $*" >&2
    exit 1
}

pidof cpcd       >/dev/null 2>&1 || fail "cpcd not running"
pidof zigbeed    >/dev/null 2>&1 || fail "zigbeed not running"
pidof otbr-agent >/dev/null 2>&1 || fail "otbr-agent not running"

test -e /dev/ttyZigbeeNCP || fail "/dev/ttyZigbeeNCP missing"
test -e /tmp/ttyZigbeeNCP || fail "/tmp/ttyZigbeeNCP missing"

ip link show "${OT_THREAD_IF:-wpan0}" >/dev/null 2>&1 \
    || fail "${OT_THREAD_IF:-wpan0} not present"

(echo >/dev/tcp/127.0.0.1/"${ZIGBEE_TCP_PORT:-9627}") >/dev/null 2>&1 \
    || fail "zigbee tcp bridge not reachable"

if command -v ot-ctl >/dev/null 2>&1; then
    state="$(ot-ctl state 2>/dev/null | tr -d '\r' | head -n 1 || echo 'disabled')"
    case "${state}" in
        leader|router|child|detached) ;;
        *) fail "thread state=${state}" ;;
    esac
fi

echo "[HEALTH] OK"
exit 0
EOF

RUN chmod 755 /usr/local/bin/healthcheck.sh

# -----------------------------------------------------------------------------
# S6-Overlay User Bundle
# -----------------------------------------------------------------------------

RUN mkdir -p \
    /etc/s6-overlay/s6-rc.d \
    /etc/s6-overlay/user-bundles.d/user/contents.d

# -----------------------------------------------------------------------------
# SERVICE: container-init
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/container-init/dependencies.d && \
    printf '%s\n' oneshot \
        > /etc/s6-overlay/s6-rc.d/container-init/type && \
    printf '%s\n' /usr/local/bin/container-init.sh \
        > /etc/s6-overlay/s6-rc.d/container-init/up && \
    touch /etc/s6-overlay/s6-rc.d/container-init/dependencies.d/base && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/container-init

# -----------------------------------------------------------------------------
# SERVICE: dbus
#
# Entfernt vor jedem Start die stale PID-Datei und den Socket.
# Ohne das schlägt dbus-daemon nach einem Container-Neustart fehl mit:
#
#   "The pid file '/run/dbus/pid' exists, if the message bus is not
#    running, remove this file"
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/dbus/dependencies.d && \
    printf '%s\n' longrun \
        > /etc/s6-overlay/s6-rc.d/dbus/type && \
    cat > /etc/s6-overlay/s6-rc.d/dbus/run <<'EOF'
#!/command/with-contenv bash
set -eu

rm -f /run/dbus/system_bus_socket
rm -f /run/dbus/pid

exec dbus-daemon --system --nofork
EOF

RUN chmod 755 /etc/s6-overlay/s6-rc.d/dbus/run && \
    touch /etc/s6-overlay/s6-rc.d/dbus/dependencies.d/container-init && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/dbus

# -----------------------------------------------------------------------------
# SERVICE: avahi-daemon
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/avahi-daemon/dependencies.d && \
    printf '%s\n' longrun \
        > /etc/s6-overlay/s6-rc.d/avahi-daemon/type && \
    cat > /etc/s6-overlay/s6-rc.d/avahi-daemon/run <<'EOF'
#!/command/with-contenv bash
set -eu

echo "[AVAHI] Waiting for D-Bus ..."

elapsed=0
timeout=30

while [ ! -S /run/dbus/system_bus_socket ]; do
    if [ "${elapsed}" -ge "${timeout}" ]; then
        echo "[AVAHI] ERROR: D-Bus system socket did not appear" >&2
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

echo "[AVAHI] D-Bus is ready"

exec avahi-daemon --no-drop-root
EOF

RUN chmod 755 /etc/s6-overlay/s6-rc.d/avahi-daemon/run && \
    touch /etc/s6-overlay/s6-rc.d/avahi-daemon/dependencies.d/container-init && \
    touch /etc/s6-overlay/s6-rc.d/avahi-daemon/dependencies.d/dbus && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/avahi-daemon

# -----------------------------------------------------------------------------
# SERVICE: cpcd
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/cpcd/dependencies.d && \
    printf '%s\n' longrun \
        > /etc/s6-overlay/s6-rc.d/cpcd/type && \
    cat > /etc/s6-overlay/s6-rc.d/cpcd/run <<'EOF'
#!/command/with-contenv bash
set -eu

echo "[CPCD] Starting cpcd with /etc/cpcd.conf"

exec cpcd -c /etc/cpcd.conf
EOF

RUN chmod 755 /etc/s6-overlay/s6-rc.d/cpcd/run && \
    touch /etc/s6-overlay/s6-rc.d/cpcd/dependencies.d/container-init && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/cpcd

# -----------------------------------------------------------------------------
# SERVICE: cpcd-ready
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/cpcd-ready/dependencies.d && \
    printf '%s\n' oneshot \
        > /etc/s6-overlay/s6-rc.d/cpcd-ready/type && \
    printf '%s\n' /usr/local/bin/wait-for-cpcd.sh \
        > /etc/s6-overlay/s6-rc.d/cpcd-ready/up && \
    touch /etc/s6-overlay/s6-rc.d/cpcd-ready/dependencies.d/cpcd && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/cpcd-ready

# -----------------------------------------------------------------------------
# SERVICE: zigbeed-socat
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/zigbeed-socat/dependencies.d && \
    printf '%s\n' longrun \
        > /etc/s6-overlay/s6-rc.d/zigbeed-socat/type && \
    cat > /etc/s6-overlay/s6-rc.d/zigbeed-socat/run <<'EOF'
#!/command/with-contenv bash
set -eu

rm -f /dev/ttyZigbeeNCP /tmp/ttyZigbeeNCP

echo "[ZIGBEE-SOCAT] Creating EZSP PTYs"

exec socat \
    PTY,link=/dev/ttyZigbeeNCP,raw,echo=0 \
    PTY,link=/tmp/ttyZigbeeNCP,raw,echo=0
EOF

RUN chmod 755 /etc/s6-overlay/s6-rc.d/zigbeed-socat/run && \
    cat > /etc/s6-overlay/s6-rc.d/zigbeed-socat/finish <<'EOF'
#!/command/with-contenv bash
set +e

rm -f /dev/ttyZigbeeNCP /tmp/ttyZigbeeNCP
EOF

RUN chmod 755 /etc/s6-overlay/s6-rc.d/zigbeed-socat/finish && \
    touch /etc/s6-overlay/s6-rc.d/zigbeed-socat/dependencies.d/cpcd-ready && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/zigbeed-socat

# -----------------------------------------------------------------------------
# SERVICE: zigbeed
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/zigbeed/dependencies.d && \
    printf '%s\n' longrun \
        > /etc/s6-overlay/s6-rc.d/zigbeed/type && \
    cat > /etc/s6-overlay/s6-rc.d/zigbeed/run <<'EOF'
#!/command/with-contenv bash
set -eu

echo "[ZIGBEED] Starting zigbeed"
echo "[ZIGBEED] Config: /usr/local/etc/zigbeed.conf"

exec zigbeed -c /usr/local/etc/zigbeed.conf
EOF

RUN chmod 755 /etc/s6-overlay/s6-rc.d/zigbeed/run && \
    touch /etc/s6-overlay/s6-rc.d/zigbeed/dependencies.d/cpcd-ready && \
    touch /etc/s6-overlay/s6-rc.d/zigbeed/dependencies.d/zigbeed-socat && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/zigbeed

# -----------------------------------------------------------------------------
# SERVICE: zigbee2mqtt-tcp-bridge
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/zigbee2mqtt-tcp-bridge/dependencies.d && \
    printf '%s\n' longrun \
        > /etc/s6-overlay/s6-rc.d/zigbee2mqtt-tcp-bridge/type && \
    cat > /etc/s6-overlay/s6-rc.d/zigbee2mqtt-tcp-bridge/run <<'EOF'
#!/command/with-contenv bash
set -eu

ZIGBEE_TCP_PORT="${ZIGBEE_TCP_PORT:-9627}"

echo "[ZIGBEE-TCP] Starting TCP bridge"
echo "[ZIGBEE-TCP] Listen port: ${ZIGBEE_TCP_PORT}"
echo "[ZIGBEE-TCP] Backend: /dev/ttyZigbeeNCP"

exec socat \
    "TCP-LISTEN:${ZIGBEE_TCP_PORT},reuseaddr,fork" \
    /dev/ttyZigbeeNCP,raw,echo=0
EOF

RUN chmod 755 /etc/s6-overlay/s6-rc.d/zigbee2mqtt-tcp-bridge/run && \
    touch /etc/s6-overlay/s6-rc.d/zigbee2mqtt-tcp-bridge/dependencies.d/zigbeed && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/zigbee2mqtt-tcp-bridge

# -----------------------------------------------------------------------------
# SERVICE: otbr-firewall
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/otbr-firewall/dependencies.d && \
    printf '%s\n' oneshot \
        > /etc/s6-overlay/s6-rc.d/otbr-firewall/type && \
    printf '%s\n' /usr/local/bin/otbr-firewall-up.sh \
        > /etc/s6-overlay/s6-rc.d/otbr-firewall/up && \
    printf '%s\n' /usr/local/bin/otbr-firewall-down.sh \
        > /etc/s6-overlay/s6-rc.d/otbr-firewall/down && \
    touch /etc/s6-overlay/s6-rc.d/otbr-firewall/dependencies.d/container-init && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/otbr-firewall

# -----------------------------------------------------------------------------
# SERVICE: otbr-agent
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/otbr-agent/dependencies.d && \
    printf '%s\n' longrun \
        > /etc/s6-overlay/s6-rc.d/otbr-agent/type && \
    cat > /etc/s6-overlay/s6-rc.d/otbr-agent/run <<'EOF'
#!/command/with-contenv bash
set -eu

CONFIG="/etc/default/otbr-agent"

echo "[OTBR] Starting otbr-agent"
echo "[OTBR] Config: ${CONFIG}"

if [ ! -f "${CONFIG}" ]; then
    echo "[OTBR] ERROR: ${CONFIG} not found" >&2
    exit 1
fi

# shellcheck disable=SC1091
. "${CONFIG}"

if [ -z "${OTBR_AGENT_OPTS:-}" ]; then
    echo "[OTBR] ERROR: OTBR_AGENT_OPTS is empty" >&2
    exit 1
fi

echo "[OTBR] OTBR_AGENT_OPTS=${OTBR_AGENT_OPTS}"

echo "[OTBR] Network interfaces:"
ip -br link || true

echo "[OTBR] Starting binary with configured arguments..."

exec /usr/sbin/otbr-agent ${OTBR_AGENT_OPTS}
EOF

RUN chmod 755 /etc/s6-overlay/s6-rc.d/otbr-agent/run && \
    touch /etc/s6-overlay/s6-rc.d/otbr-agent/dependencies.d/cpcd-ready && \
    touch /etc/s6-overlay/s6-rc.d/otbr-agent/dependencies.d/otbr-firewall && \
    touch /etc/s6-overlay/s6-rc.d/otbr-agent/dependencies.d/avahi-daemon && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/otbr-agent

# -----------------------------------------------------------------------------
# SERVICE: otbr-init
#
# Oneshot-Service, der die zuvor manuell ausgeführten ot-ctl-Befehle
# übernimmt. Läuft NACH otbr-agent (longrun) und NACH otbr-firewall.
#
# Idempotent: Bei jedem Container-Start wird geprüft, ob bereits ein
# aktives Dataset existiert (persistiert im Volume), und nur dann ein
# neues erzeugt, wenn keines vorhanden ist.
# -----------------------------------------------------------------------------

RUN mkdir -p /etc/s6-overlay/s6-rc.d/otbr-init/dependencies.d && \
    printf '%s\n' oneshot \
        > /etc/s6-overlay/s6-rc.d/otbr-init/type && \
    printf '%s\n' /usr/local/bin/otbr-init.sh \
        > /etc/s6-overlay/s6-rc.d/otbr-init/up && \
    touch /etc/s6-overlay/s6-rc.d/otbr-init/dependencies.d/otbr-agent && \
    touch /etc/s6-overlay/s6-rc.d/otbr-init/dependencies.d/otbr-firewall && \
    touch /etc/s6-overlay/user-bundles.d/user/contents.d/otbr-init

# -----------------------------------------------------------------------------
# Healthcheck
# -----------------------------------------------------------------------------

HEALTHCHECK \
    --interval=30s \
    --timeout=10s \
    --start-period=120s \
    --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

# -----------------------------------------------------------------------------
# Runtime
# -----------------------------------------------------------------------------

USER root

WORKDIR /workspace

ENTRYPOINT ["/init"]
