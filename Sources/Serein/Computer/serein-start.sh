#!/bin/sh
# Serein's computer, first process: a virtual X display, the session bus the accessibility
# tree lives on, and the desktop. Serein's helper is started on top of this with docker exec
# (ComputerHost) and reads the bus address from /tmp/serein. The root file system is read-only;
# /tmp and /run are small tmpfs mounts, and /home/serein is the computer's own volume.
# Commands (computer_run) run as the `shell` user in ~/work (helper.py --shell). The display
# admits only holders of this start's key in /tmp/serein/xauth, and the accessibility bus lives in
# /tmp/serein/run (both outside the home, so a Reset or a restored checkpoint keeps them). Its
# socket and both buses admit only this user, so a command cannot type, press keys, read fields
# or see the screen. What the desktop side writes outside the home is private to it (/tmp/serein
# is 0711), and X has no shared memory segments (MIT-SHM off). A desktop terminal's shell is
# /opt/serein/term ($SHELL, the user's login shell, and the command of every xfce4-terminal tab,
# see helper.py --terminal), which runs it as `shell` through computer_run's helper. The desktop
# runs no command line from its home: the session starts from the image's own xinitrc and bus
# services only, and helper.py --scrub and --guard leave inert every file there that would name
# one (see OFF in helper.py). The session starts only with a live guard, which is restarted if it ends.
set -e
# A start as root (a hosted template's start command may run as root) becomes the desktop's user,
# leaving no root process behind.
if [ "$(id -u)" = 0 ]; then exec setpriv --reuid=serein --regid=serein --init-groups --reset-env /opt/serein/start.sh; fi
umask 077
mkdir -p /tmp/serein
[ -d /tmp/serein ] && [ ! -L /tmp/serein ] && [ -O /tmp/serein ] || { echo "/tmp/serein is not this user's own" >&2; exit 1; }
chmod 0711 /tmp/serein
mkdir -p /tmp/serein/jobs
chmod 1733 /tmp/serein/jobs
mkdir -p /tmp/serein/run
# The image's own controls (Dockerfile) are in place, or the desktop does not start and the helper's
# ping says why: the wrappers in front of exo-open, xfce4-terminal and the login shell, the
# terminal's locked custom command, the default apps, the browser's start script and policy, the
# session bus's service folders, the panel entries that run what they are handed, the sealed folder.
refuse() {
  echo "Serein's computer is missing a control its image should have ($1). Rebuild it in Settings › Serein's computer; on E2B, build the template again from the folder Show Recipe opens, then Reset." >/tmp/serein/refused
  exec sleep infinity
}
sha256sum -c --quiet --strict >/dev/null 2>&1 <<'EOF' || refuse "a wrapper, the terminal's lock, the default apps or the browser's policy"
f931212422d1e4f1e6fe254da024a8c8f614052522230706b2fa2a533dcb39d6  /usr/bin/exo-open
97e63f5296386e44e5a7bf2900a3e60017e675be71be9d10a8de1138720a66dd  /usr/bin/xfce4-terminal
adf89323df2212948a898b180b807681caa926aa80dc574b56e07897e08dc198  /opt/serein/term
5c9c79a6853e81ce548f25e9edbb692eeed2ae45eb982b2379a856f6997ab59d  /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-terminal.xml
c7a4080af065c4f7551066bcbec0c7381aa0a8b7f83ce209fe70dd13637289f8  /etc/xdg/mimeapps.list
b006ded9e1db3f9f9b7170bc64724b52a2e2f5206216d9bcaa88112855bafc4b  /etc/chromium.d/serein-sandbox
a7f426177776cf849d513724025f3e49e2305e144ac56dc508f0a7d98e993fdc  /etc/chromium/policies/managed/serein.json
EOF
[ "$(getent passwd serein | cut -d: -f7)" = /opt/serein/term ] || refuse "the login shell"
grep -q '<servicedir>/usr/share/dbus-1/services</servicedir>' /usr/share/dbus-1/serein-session.conf \
  && ! grep -q standard_session_servicedirs /usr/share/dbus-1/serein-session.conf || refuse "the session bus's services"
for f in /usr/share/applications/panel-desktop-handler.desktop /usr/lib/*/xfce4/panel/plugins/libdirectorymenu.so \
  /usr/share/xfce4/panel/plugins/directorymenu.desktop; do [ ! -e "$f" ] || refuse "$f is back"; done
! grep -qs -e 'value="directorymenu"' -e 'value="xfce4-appfinder.desktop"' /etc/xdg/xfce4/panel/default.xml \
  && ! grep -qs '^X-XfcePluggable=' /usr/share/applications/*.desktop || refuse "the panel's entries"
[ -d /usr/share/serein/sealed ] && [ -z "$(ls -A /usr/share/serein/sealed)" ] && [ -d /usr/share/serein/panel/launcher-200 ] \
  || refuse "the sealed folders"
export XDG_RUNTIME_DIR=/tmp/serein/run
[ ! -L "$HOME/work" ] || rm -f "$HOME/work"
python3 -I /opt/serein/helper.py --scrub
rm -f /tmp/serein/guard
# `|| :`: under set -e, a guard's exit would end the loop that restarts it.
(while :; do python3 -I /opt/serein/helper.py --guard || :; sleep 1; done) 2>>/tmp/serein/guard.log &
loop=$!
echo "$loop" > /tmp/serein/guard-loop
i=0
while [ ! -s /tmp/serein/guard ] && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
kill -0 "$(cat /tmp/serein/guard 2>/dev/null)" 2>/dev/null || { echo "the home's guard did not start" >&2; exit 1; }
python3 -I -c 'import os, struct, sys
f = lambda b: struct.pack(">H", len(b)) + b
if os.path.lexists(sys.argv[1]): os.unlink(sys.argv[1])
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
os.write(fd, struct.pack(">H", 0xFFFF) + f(b"") + f(b"0") + f(b"MIT-MAGIC-COOKIE-1") + f(os.urandom(16)))' /tmp/serein/xauth
export DISPLAY=:0 XAUTHORITY=/tmp/serein/xauth
Xvfb :0 -screen 0 1280x800x24 -nolisten tcp -nolisten local -extension MIT-SHM -auth "$XAUTHORITY" >/tmp/serein/xvfb.log 2>&1 &
i=0
while [ ! -S /tmp/.X11-unix/X0 ] && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
chmod 0700 /tmp/.X11-unix
eval "$(dbus-launch --sh-syntax --config-file=/usr/share/dbus-1/serein-session.conf)"
bus=${DBUS_SESSION_BUS_ADDRESS#unix:path=}
chmod 0600 "${bus%%,*}"
echo "$DBUS_SESSION_BUS_ADDRESS" > /tmp/serein/dbus-address
: >/tmp/serein/xfce.log
# A desktop terminal's shell runs as `shell`, through computer_run's helper (helper.py --term-client).
export SHELL=/opt/serein/term XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_CONFIG_DIRS=/etc/xdg
umask 022
chmod 0710 "$HOME"
mkdir -p "$HOME/work"
chmod 2770 "$HOME/work"
/bin/sh /etc/xdg/xfce4/xinitrc >>/tmp/serein/xfce.log 2>&1 &
# The session manager's ICE socket only for this user, as the X socket: libICE makes its folder 1777
# when it listens. Both of its sockets admit only holders of the session's key (/tmp/serein/run).
i=0
while [ -z "$(ls -A /tmp/.ICE-unix 2>/dev/null)" ] && [ "$i" -lt 300 ]; do i=$((i + 1)); sleep 0.1; done
if [ -e /tmp/.ICE-unix ]; then
  [ -O /tmp/.ICE-unix ] && [ ! -L /tmp/.ICE-unix ] || { echo "/tmp/.ICE-unix is not this user's own" >&2; exit 1; }
  chmod 0700 /tmp/.ICE-unix
fi
kill -0 "$(cat /tmp/serein/guard)" 2>/dev/null || { echo "the home's guard ended" >&2; exit 1; }
echo ready > /tmp/serein/ready
# The desktop lasts as long as the loop that keeps its guard: on Docker the container then stops,
# and the next step starts it again; elsewhere the helper's ping refuses it (helper.py op_ping).
wait "$loop" || :
echo "the loop that keeps the home's guard ended" >&2
exit 1
