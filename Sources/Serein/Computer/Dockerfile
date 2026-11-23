# Serein's computer: a small Linux desktop an assistant works in. Built locally by Serein from
# this file (ComputerHost.buildImage); nothing pre-built is downloaded. The base image is the
# official Debian slim image, pinned by the digest of its multi-architecture manifest, so the
# same bytes are used on Apple silicon and Intel Macs. A hosted computer on E2B is made from a
# template the person builds once from this same file with E2B's own tool
# (e2b template create serein-computer -c /opt/serein/start.sh); Serein never builds or uploads it.
FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
# Every layer and container carries this label, so a cancelled build's leftovers can be removed
# without touching anything else on the engine.
LABEL serein.computer=image
# The SHA-256 of the helper and start script copied below, as this Serein pins them (ComputerPins):
# Serein checks both files inside at every start, and a desktop on the person's own machine is
# built again when its image carries other pins.
LABEL serein.computer.pins="helper=7d3144d1f81707af18b0df59cb2885f0742cbb06ac2f4ec7389e18a3f5deadc1 start=ea826bb5a5e58d221ae1072a5c3dbf10e448b0e0e7c9d96603a4602385138b36"
ENV DEBIAN_FRONTEND=noninteractive
# The desktop (XFCE on a virtual X display), the browser, and what the helper needs: the
# accessibility bus and its Python binding, xdotool for the pointer and keys, scrot for the
# screen, wmctrl for the window list. Packages come from Debian's snapshot archive at one fixed
# moment (signed by Debian's keys as ever), each named one at its version there, the same for
# arm64 and amd64; what they pull in is held by the snapshot. Not pinned by version: those pulled-in
# packages one by one, and security fixes newer than the snapshot until Serein moves it. The
# snapshot and these versions move with each Serein release (Debian keeps dated builds about a
# year); Settings asks Docker users to Rebuild after an update.
RUN key=/usr/share/keyrings/debian-archive-keyring.pgp; [ -f "$key" ] || key=/usr/share/keyrings/debian-archive-keyring.gpg; \
  printf 'Types: deb\nURIs: http://snapshot.debian.org/archive/debian/20261001T000000Z/\nSuites: bookworm bookworm-updates\nComponents: main\nSigned-By: %s\n\nTypes: deb\nURIs: http://snapshot.debian.org/archive/debian-security/20261001T000000Z/\nSuites: bookworm-security\nComponents: main\nSigned-By: %s\n' "$key" "$key" > /etc/apt/sources.list.d/debian.sources \
  && rm -f /etc/apt/sources.list \
  && apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Retries=5 update \
  && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
    xvfb=2:21.1.7-3+deb12u13 xfce4-session=4.18.1-1 xfwm4=4.18.0-1 xfce4-panel=4.18.2-1 xfdesktop4=4.18.1-1 \
    xfce4-terminal=1.0.4-1 dbus-x11=1.14.10-1~deb12u1 at-spi2-core=2.46.0-5 chromium=154.0.8037.57-1~deb12u1 \
    fonts-dejavu=2.37-6 ca-certificates=20250419~deb12u1 python3=3.11.2-1+b1 python3-pyatspi=2.46.0-2 \
    xdotool=1:3.20160805.1-5 scrot=1.8.1-1 wmctrl=1.07-7+b1 procps=2:4.0.2-3 \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && dbus-uuidgen > /etc/machine-id \
  && mkdir -p /mnt/shared \
  && useradd --create-home --uid 1000 --shell /bin/bash serein \
  && useradd --no-create-home --uid 1001 --gid serein --home-dir /home/serein/work --shell /bin/bash shell
COPY serein-helper.py /opt/serein/helper.py
# Cua Driver (MIT, Cua AI, Inc.) when this Serein ships it: Serein puts the pinned binary for the
# engine's arch (x86_64 in the recipe folder for E2B and Daytona), its LICENSE and notices into the
# build context (CuaDriverRelease); the patterns match nothing in a context without them, and the
# start script anchors the copy. The binary is root's, 0755, so `serein` runs it (CuaDriverRelease.boxCommand) and cannot change it.
COPY serein-start.sh cua-drive[r] cua-driver-license.tx[t] cua-driver-notices.m[d] cua-driver-crates.m[d] /opt/serein/
# The desktop runs no command line a model could choose (serein-start.sh): every terminal, however
# it is started (the panel, exo's helpers, x-terminal-emulator, a Terminal=true entry), is
# xfce4-terminal through helper.py --terminal, and its command runs as `shell` through
# /opt/serein/term, the desktop user's login shell too; its custom command setting is locked off
# (xfconf honours a lock that names the user, not "*");
# exo-open, which runs a desktop entry it is handed, goes through helper.py --exo-open; the entries
# that run any file they are handed (the panel's "add this launcher", the folder menu) are gone;
# settings windows open on their own, never inside the settings manager, so the screen floor knows
# each by its class; the session bus offers the image's own services only; the home's folders that
# the desktop never writes are links to an empty folder of root's (helper.py SEALED), the panel's
# to one of empty launcher folders, as the launcher plugin needs its own folder to exist (shortcut:
# 200 of them, a launcher with a higher plugin id crashes the panel when given an item; raise the
# count if a layout ever gets there); a text file
# or a folder opens in the browser, which starts without its own sandbox only where the machine
# gives it none (as computer_open_url does), from / (never a folder `shell` writes), and without
# Mesa's shader cache (its files hold machine code); the browser saves into ~/Downloads, keeps no
# password or card a task typed (a later task could fill it in), and runs no native helper from
# the home.
RUN mv /opt/serein/serein-start.sh /opt/serein/start.sh \
  && printf '#!/bin/sh\nexec python3 -I /opt/serein/helper.py --term-client "$@"\n' > /opt/serein/term \
  && chmod 0755 /opt/serein/start.sh /opt/serein/helper.py /opt/serein/term \
  && usermod --shell /opt/serein/term serein \
  && dpkg-divert --local --rename --divert /usr/bin/exo-open.distrib --add /usr/bin/exo-open \
  && printf '#!/bin/sh\nexec python3 -I /opt/serein/helper.py --exo-open "$@"\n' > /usr/bin/exo-open \
  && dpkg-divert --local --rename --divert /usr/bin/xfce4-terminal.distrib --add /usr/bin/xfce4-terminal \
  && printf '#!/bin/sh\nexec python3 -I /opt/serein/helper.py --terminal "$@"\n' > /usr/bin/xfce4-terminal \
  && chmod 0755 /usr/bin/exo-open /usr/bin/xfce4-terminal \
  && printf '<?xml version="1.0" encoding="UTF-8"?>\n<channel name="xfce4-terminal" version="1.0">\n  <property name="run-custom-command" type="bool" value="false" locked="serein"/>\n  <property name="custom-command" type="string" value="" locked="serein"/>\n</channel>\n' \
    > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-terminal.xml \
  && mkdir -p /usr/share/serein/sealed $(seq -f /usr/share/serein/panel/launcher-%g 1 200) \
  && printf '[Default Applications]\ntext/plain=chromium.desktop;\ninode/directory=chromium.desktop;\n' > /etc/xdg/mimeapps.list \
  && printf 'cd /\nexport MESA_SHADER_CACHE_DISABLE=true\nunshare --user --map-root-user true 2>/dev/null || CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox"\n' > /etc/chromium.d/serein-sandbox \
  && rm -f /usr/share/applications/panel-desktop-handler.desktop \
    /usr/lib/*/xfce4/panel/plugins/libdirectorymenu.so /usr/share/xfce4/panel/plugins/directorymenu.desktop \
  && sed -i '/value="directorymenu"/d; /<value type="int" value="22"\/>/d; /value="xfce4-appfinder.desktop"/d; s#value="\(xfce4-[a-z-]*\.desktop\)"#value="file:///usr/share/applications/\1"#' \
    /etc/xdg/xfce4/panel/default.xml \
  && sed -i '/^X-XfcePluggable=/d' /usr/share/applications/*.desktop \
  && sed 's|<standard_session_servicedirs */>|<servicedir>/usr/share/dbus-1/services</servicedir>|' \
    /usr/share/dbus-1/session.conf > /usr/share/dbus-1/serein-session.conf \
  && mkdir -p /etc/chromium/policies/managed \
  && printf '{"DownloadDirectory": "/home/serein/Downloads", "PromptForDownloadLocation": false, "NativeMessagingUserLevelHosts": false, "PasswordManagerEnabled": false, "AutofillCreditCardEnabled": false}\n' \
    > /etc/chromium/policies/managed/serein.json \
  && if [ -f /opt/serein/cua-driver ]; then chmod 0755 /opt/serein/cua-driver \
    && mkdir -p /usr/share/doc/cua-driver \
    && mv /opt/serein/cua-driver-license.txt /usr/share/doc/cua-driver/LICENSE \
    && mv /opt/serein/cua-driver-notices.md /usr/share/doc/cua-driver/THIRD_PARTY_NOTICES.md \
    && mv /opt/serein/cua-driver-crates.md /usr/share/doc/cua-driver/CRATE_NOTICES.md; fi
# The only way out is Serein's proxy, reached on the computer's own loopback where the helper's
# shim listens (serein-helper.py --proxy); the container itself has no network.
ENV DISPLAY=:0 SHELL=/opt/serein/term \
  http_proxy=http://127.0.0.1:3128 https_proxy=http://127.0.0.1:3128 \
  HTTP_PROXY=http://127.0.0.1:3128 HTTPS_PROXY=http://127.0.0.1:3128 \
  GTK_MODULES=gail:atk-bridge NO_AT_BRIDGE=0
USER serein
WORKDIR /home/serein
ENTRYPOINT ["/opt/serein/start.sh"]
