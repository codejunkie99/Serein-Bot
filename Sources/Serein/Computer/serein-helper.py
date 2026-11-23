#!/usr/bin/env python3
"""Serein's in-computer helper.

Runs inside Serein's computer as its unprivileged user, started by Serein over a command stream
(docker exec on this Mac, the provider's process stream on a hosted computer), and
speaks JSON lines: one request per line on stdin ({"id", "op", ...}), one answer per line on
stdout ({"id", ...} or {"id", "error"}). It offers the screen, the pointer and keys, the
accessibility tree, the browser, a shell, and files, all inside the computer. Nothing here reaches
the Mac: the computer has no network, and the only link is the stream Serein holds.

With --proxy it is the shim instead: it listens on the computer's loopback (127.0.0.1:3128) for
the browser's proxy connections and carries each one over stdin and stdout to Serein's proxy in
frames of 4 bytes id, 1 byte kind (1 open, 2 data, 3 close), 4 bytes length, payload.

With --armor -- <command...> it carries another command over a stream that holds only text (a
hosted computer's command log, Daytona): each line on stdin is base64 for the command's stdin ("."
alone ends it), each chunk of the command's stdout goes out as ":" and its base64 on one line (so
an echoed input line never reads as output), its stderr is
dropped, and the last line is "!" and its exit code (128 plus the signal when a signal ended it).

With --vsock it is the link of Serein's built-in computer, which has no network card: it listens
on the virtio socket (port 6100), which only the Mac running the computer can reach, and accepts
only that Mac. Each connection's first line names the command it carries ({"argv", "stdin",
"framed"}); the command runs as this unprivileged user with the connection as its stdin and
stdout, or, framed, with its output in 8-byte-headed frames (1 stdout, 2 stderr, 3 its exit code).

With --job <folder> it is one detached job (computer_run with detach), started by the helper in its
own session so it outlives the helper and the stream that asked for it: it runs the command in
the folder's `command` file as this user, keeps its output in `output.log` there (at most 1 MB, the
oldest half dropped when it would grow past that), stops it after four hours, and writes `exit`
(its code, or that it was stopped for time) when it ends. Serein polls that with job_status and
reports the end in the chat that started it. Jobs live under /tmp/serein/jobs, outside the home.

With --shell it is the helper of computer_run and its jobs, started as the computer's `shell` user
(serein-start.sh): no display and no session bus in its environment (neither would admit it), and
what it makes stays readable and writable by the desktop's user, who shares its group. It also
serves the desktop's terminals: each connection to the socket /tmp/serein/jobs/terminal (this user
and its group only) gets a login bash as this user in a pseudo-terminal of its own.

With --term-client it is a desktop terminal's shell (/opt/serein/term, $SHELL in the desktop's
session and the desktop user's login shell): it carries the terminal to that socket, so what is
typed there runs as `shell`, with no display, bus, or clipboard. Its first frame names the command
and folder (kind 2, JSON {"argv", "cwd"}; no command is a login bash), then keys go up in frames of
1 byte kind (0 keys, 1 size as rows and columns), 2 bytes length, payload; the shell's output comes
back as it is. `$SHELL -c` from the desktop's own programs stays an ordinary sh as the desktop's user.

With --terminal it is xfce4-terminal for every program on the desktop (the Dockerfile moves the
real one aside): the command of each tab (-x, -e, --command) runs inside /opt/serein/term, so as
`shell`, and an option it does not know is refused.

With --own it runs on the person's own Linux desktop or Mac, installed in their home folder as
~/.serein-helper/helper.py and started over their SSH session's stdin and stdout only. It opens no
port and leaves no file: each screenshot is written to a private temporary folder and deleted at
once. Screenshots are scaled to fit 1280 pixels; clicks and the tree are mapped back.
"""
import base64
import errno
import fcntl
import json
import os
import pty
import pwd
import select
import shutil
import signal
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty

HOME = os.path.expanduser("~")
TMP = "/tmp/serein"
OUTPUT_LIMIT = 24000
FILE_OUT_LIMIT = 50_000_000
COMMAND_TIMEOUT = 60
PROXY = "http://127.0.0.1:3128"
# A hosted computer the person gave its provider's own internet has no shim: its browser opens
# without the proxy (Serein sets this only there; everywhere else the proxy is the only way out).
DIRECT = os.environ.get("SEREIN_NETWORK") == "provider"
KEY_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+ ")
# xdotool's own command names: `xdotool key` stops at the first word that names one (in any case)
# and runs the rest as a chained command, `exec` among them. No key step may hold one, and every
# xdotool call carries one command with `--` before its words (OwnCard.xdotoolCommands, the same list).
XDOTOOL_COMMANDS = {
    "behave", "behave_screen_edge", "click", "exec", "get_desktop", "get_desktop_for_window", "get_desktop_viewport",
    "get_num_desktops", "getactivewindow", "getdisplaygeometry", "getmouselocation", "getwindowclassname",
    "getwindowfocus", "getwindowgeometry", "getwindowname", "getwindowpid", "help", "key", "keydown", "keyup",
    "mousedown", "mousemove", "mousemove_relative", "mouseup", "search", "selectwindow", "set_desktop",
    "set_desktop_for_window", "set_desktop_viewport", "set_num_desktops", "set_window", "sleep", "type", "version",
    "windowactivate", "windowclose", "windowfocus", "windowkill", "windowlower", "windowmap", "windowminimize",
    "windowmove", "windowquit", "windowraise", "windowreparent", "windowsize", "windowstate", "windowunmap",
}
MAX_CHORDS = 8
OWN = "--own" in sys.argv[1:]
MAC = OWN and sys.platform == "darwin"
SHELL_ONLY = "--shell" in sys.argv[1:]
# The `shell` user's share of the computer's tasks (threads count): half of Docker's PidsLimit 1024,
# so its commands cannot leave the desktop or Cua Driver unable to start one.
SHELL_TASKS = 512
if SHELL_ONLY:
    if pwd.getpwuid(os.getuid()).pw_name != "shell":
        sys.exit("The shell helper requires the isolated shell account.")
    os.umask(0o002)
    # Launchers hand it the desktop user's HOME and folder; this user's own is ~/work.
    HOME = os.environ["HOME"] = pwd.getpwuid(os.getuid()).pw_dir
    os.chdir(HOME)
    # On every backend, whatever started it, and passed to every child: nothing this user runs
    # gains privileges at exec (a setuid or setgid file, file capabilities), it holds at most
    # SHELL_TASKS tasks, and the kernel's out-of-memory killer takes its processes first.
    import ctypes
    import resource
    if ctypes.CDLL(None, use_errno=True).prctl(38, 1, 0, 0, 0) != 0:  # PR_SET_NO_NEW_PRIVS
        sys.exit("The shell user's helper could not set no_new_privs, so it runs no command.")
    hard = resource.getrlimit(resource.RLIMIT_NPROC)[1]
    tasks = SHELL_TASKS if hard == resource.RLIM_INFINITY else min(SHELL_TASKS, hard)
    resource.setrlimit(resource.RLIMIT_NPROC, (tasks, tasks))
    try:
        with open("/proc/self/oom_score_adj", "w") as adj:
            adj.write("1000")
    except OSError:
        pass
# The largest side of a screenshot of the person's own screen, in pixels.
BOX = 1280
# Detached jobs (ComputerJobs): their folders, the output cap, what job_status sends of the output's
# end, and how long one may run.
JOBS = os.path.join(TMP, "jobs")
JOB_LOG_LIMIT = 1_000_000
JOB_TAIL = 4000
JOB_TIME_LIMIT = 4 * 3600
TERMINAL = os.path.join(JOBS, "terminal")
TERM_CLIENT = "/opt/serein/term"
# What the terminal relay holds for a side that is not taking it yet.
RELAY_HELD = 1_000_000
TERMINAL_DRAIN_SECONDS = 5


def session_displays(uid):
    """The X displays this user's own login sessions name (loginctl), for a root-owned socket."""
    named = set()
    try:
        listed = subprocess.run(["loginctl", "list-sessions", "--no-legend"], capture_output=True, timeout=5).stdout
        for line in listed.decode("utf-8", "replace").splitlines():
            parts = line.split()
            if len(parts) < 2 or parts[1] != str(uid) or not parts[0].isalnum():
                continue
            shown = subprocess.run(["loginctl", "show-session", parts[0], "-p", "Display", "--value"],
                                   capture_output=True, timeout=5).stdout.decode().strip()
            if shown.startswith(":"):
                named.add(shown)
    except (OSError, subprocess.SubprocessError):
        pass
    return named


def own_linux_env(env):
    """The person's own X display, its key and session bus, found from the SSH session. A display
    this user owns comes first; one owned by root only when one of this user's sessions names it,
    so another person's display on a shared machine is never picked."""
    uid = os.getuid()
    if not env.get("DISPLAY"):
        mine, rooted = [], []
        try:
            for name in sorted(os.listdir("/tmp/.X11-unix")):
                path = os.path.join("/tmp/.X11-unix", name)
                if not (name.startswith("X") and name[1:].isdigit()):
                    continue
                owner = os.stat(path).st_uid
                if owner == uid:
                    mine.append(":" + name[1:])
                elif owner == 0:
                    rooted.append(":" + name[1:])
        except OSError:
            pass
        if not mine and rooted:
            named = session_displays(uid)
            mine = [display for display in rooted if display in named]
        env["DISPLAY"] = mine[0] if mine else ":0"
    if not env.get("XAUTHORITY"):
        for path in [os.path.join(HOME, ".Xauthority"), "/run/user/%d/gdm/Xauthority" % uid]:
            if os.path.exists(path):
                env["XAUTHORITY"] = path
                break
    if not env.get("DBUS_SESSION_BUS_ADDRESS") and os.path.exists("/run/user/%d/bus" % uid):
        env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/run/user/%d/bus" % uid
    return env


def session_env():
    env = dict(os.environ)
    if MAC:
        return env
    if OWN:
        return own_linux_env(env)
    if SHELL_ONLY:
        for key in ("DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(key, None)
        env["SHELL"] = "/bin/bash"
        return env
    env["DISPLAY"] = ":0"
    env["SHELL"] = TERM_CLIENT
    xauth = os.path.join(TMP, "xauth")
    if os.path.exists(xauth):
        env["XAUTHORITY"] = xauth
    else:
        env.pop("XAUTHORITY", None)
    try:
        with open(os.path.join(TMP, "dbus-address")) as f:
            address = f.read().strip()
    except OSError:
        address = ""
    if address:
        env["DBUS_SESSION_BUS_ADDRESS"] = address
    else:
        env.pop("DBUS_SESSION_BUS_ADDRESS", None)
    return env


def refresh_session_env():
    fresh = session_env()
    ENV.clear()
    ENV.update(fresh)
    for key in ("XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS"):
        if key in fresh:
            os.environ[key] = fresh[key]
        else:
            os.environ.pop(key, None)


ENV = session_env()
for key, value in ENV.items():
    os.environ[key] = value


def run(args, timeout=15, stdin=None):
    try:
        # From "/", never the home: xdotool runs a file in its working folder named as its first argument.
        done = subprocess.run(args, input=stdin, capture_output=True, timeout=timeout, env=ENV, cwd="/")
    except FileNotFoundError:
        raise RuntimeError("%s is not installed on this machine" % args[0])
    if done.returncode != 0:
        raise RuntimeError((done.stderr or done.stdout or b"").decode("utf-8", "replace").strip()[:400]
                           or "%s failed" % args[0])
    return done.stdout


def number(value, name):
    """A whole number of 0 or more: nothing that reaches a command's arguments can begin with -."""
    try:
        result = int(float(value))
    except (TypeError, ValueError, OverflowError):
        raise RuntimeError("%s must be a number" % name)
    if result < 0 or result > 2000000000:
        raise RuntimeError("%s must be a number of 0 or more" % name)
    return result


def op_ping(a):
    if MAC:
        return {"ready": True}
    if OWN:
        try:
            run(["xdotool", "getdisplaygeometry"])
        except Exception as error:
            return {"ready": False, "why": "The helper cannot see a desktop on this machine (%s). It needs an X11 desktop"
                    " session for this user, with xdotool and scrot installed." % str(error)[:200]}
        return {"ready": True}
    refused = os.path.join(TMP, "refused")
    if os.path.exists(refused):
        return {"ready": False, "why": read_small(refused).decode("utf-8", "replace").strip()[:400]}
    if not os.path.exists(os.path.join(TMP, "ready")):
        return {"ready": False}
    # Where start.sh started the desktop (its display key), the loop that keeps the home's guard
    # running must be alive.
    try:
        if os.path.exists(os.path.join(TMP, "xauth")):
            os.kill(int(read_small(os.path.join(TMP, "guard-loop"))), 0)
    except (OSError, ValueError):
        return {"ready": False, "why": "The guard of the home in Serein's computer is not running, so the computer is"
                " not used. Reset it in Settings › Serein's computer."}
    refresh_session_env()
    return {"ready": True}


# Screen units per screenshot pixel, from the latest screenshot of the person's own screen.
SCALE = None


def png_size(data):
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("The screenshot is not a PNG.")
    return struct.unpack(">II", data[16:24])


MAC_POINTS = """
ObjC.import("CoreGraphics");
function run(argv) { var b = $.CGDisplayBounds($.CGMainDisplayID()); return b.size.width + " " + b.size.height; }
"""


def own_shot():
    """The person's main screen, scaled to fit BOX, and the factors that map it back."""
    global SCALE
    folder = tempfile.mkdtemp(prefix="serein-")
    try:
        path = os.path.join(folder, "shot.png")
        if MAC:
            run(["screencapture", "-x", "-t", "png", path])
            run(["sips", "-Z", str(BOX), path])
            real = [float(v) for v in run(["osascript", "-l", "JavaScript", "-e", MAC_POINTS]).decode().split()]
        else:
            real = [float(v) for v in run(["xdotool", "getdisplaygeometry"]).decode().split()]
            percent = min(100, int(BOX * 100 // max(real)))
            if percent < 100:
                run(["scrot", "-o", "-t", str(percent), path])
                thumb = path[:-4] + "-thumb.png"
                if os.path.exists(thumb):
                    path = thumb
            else:
                run(["scrot", "-o", path])
        with open(path, "rb") as f:
            data = f.read()
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    width, height = png_size(data)
    SCALE = (real[0] / width, real[1] / height)
    return data, width, height


def to_screen(x, y):
    """A screenshot pixel on the person's own screen, in the screen's own units."""
    if not OWN:
        return x, y
    if SCALE is None:
        own_shot()
    return int(round(x * SCALE[0])), int(round(y * SCALE[1]))


def to_shot(x, y):
    if not OWN or SCALE is None:
        return x, y
    return int(round(x / SCALE[0])), int(round(y / SCALE[1]))


MAC_FRONT = """
tell application "System Events"
  set p to first process whose frontmost is true
  return (name of p) & linefeed & (bundle identifier of p)
end tell
"""


def active_window():
    """The active window's id on X11, or None."""
    shown = run(["xdotool", "getactivewindow"]).decode().strip()
    return shown if shown.isdigit() else None


def front_app():
    """The app in front on the person's own screen, so Serein can refuse to look at a password
    manager: on a Mac its name and bundle identifier, on X11 the active window's class or title.
    `front_known` is False when it could not be told, and Serein then does not look."""
    try:
        if MAC:
            lines = run(["osascript", "-e", MAC_FRONT]).decode("utf-8", "replace").splitlines()
            name = (lines[0] if lines else "").strip()[:200]
            bundle = (lines[1] if len(lines) > 1 else "").strip()[:200]
            return {"app": name, "bundle": bundle, "front_known": bool(name)}
        window = active_window()
        if window is not None:
            for command in ("getwindowclassname", "getwindowname"):
                try:
                    name = run(["xdotool", command, "--", window]).decode("utf-8", "replace").strip()[:200]
                except RuntimeError:
                    continue
                if name:
                    return {"app": name, "bundle": "", "front_known": True}
    except (RuntimeError, IndexError):
        pass
    return {"app": "", "bundle": "", "front_known": False}


def op_screenshot(a):
    if OWN:
        front = front_app()
        data, width, height = own_shot()
        answer = {"png": base64.b64encode(data).decode(), "width": width, "height": height}
        answer.update(front)
        return answer
    # A folder of its own (0700): the shell user may not watch or read the screen as it is written.
    folder = tempfile.mkdtemp(prefix="shot-", dir=TMP)
    try:
        path = os.path.join(folder, "shot.png")
        run(["scrot", "-o", path])
        with open(path, "rb") as f:
            data = f.read()
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    geometry = run(["xdotool", "getdisplaygeometry"]).decode().split()
    return {"png": base64.b64encode(data).decode(), "width": int(geometry[0]), "height": int(geometry[1])}


BUTTONS = {"left": "1", "middle": "2", "right": "3"}

# Synthetic pointer events on a Mac (CoreGraphics event types and fields by number: mouse moved 5,
# left 1/2, right 3/4, other 25/26; the click count is field 1; the HID tap is 0).
MAC_CLICK = """
ObjC.import("CoreGraphics");
function run(argv) {
  var point = $.CGPointMake(Number(argv[0]), Number(argv[1]));
  var kind = {left: [1, 2, 0], right: [3, 4, 1], middle: [25, 26, 2]}[argv[2]];
  $.CGEventPost(0, $.CGEventCreateMouseEvent(null, 5, point, 0));
  for (var i = 1; i <= Number(argv[3]); i++) {
    var down = $.CGEventCreateMouseEvent(null, kind[0], point, kind[2]);
    $.CGEventSetIntegerValueField(down, 1, i);
    $.CGEventPost(0, down);
    var up = $.CGEventCreateMouseEvent(null, kind[1], point, kind[2]);
    $.CGEventSetIntegerValueField(up, 1, i);
    $.CGEventPost(0, up);
    delay(0.08);
  }
  return "ok";
}
"""
MAC_SCROLL = """
ObjC.import("CoreGraphics");
function run(argv) {
  $.CGEventPost(0, $.CGEventCreateMouseEvent(null, 5, $.CGPointMake(Number(argv[0]), Number(argv[1])), 0));
  var step = argv[2] === "up" ? 1 : -1;
  for (var i = 0; i < Number(argv[3]); i++) {
    $.CGEventPost(0, $.CGEventCreateScrollWheelEvent2(null, 1, 1, step, 0, 0));
    delay(0.03);
  }
  return "ok";
}
"""


def op_click(a):
    x, y = to_screen(number(a.get("x"), "x"), number(a.get("y"), "y"))
    button = BUTTONS.get(str(a.get("button", "left")).lower())
    if button is None:
        raise RuntimeError("button is left, middle or right")
    if MAC:
        name = {"1": "left", "2": "middle", "3": "right"}[button]
        run(["osascript", "-l", "JavaScript", "-e", MAC_CLICK, str(x), str(y), name, "2" if a.get("double") is True else "1"])
        return {"clicked": [x, y]}
    # One xdotool command a call, its words after "--": nothing can chain another command.
    run(["xdotool", "mousemove", "--sync", "--", str(x), str(y)])
    run(["xdotool", "click"] + (["--repeat", "2", "--delay", "80"] if a.get("double") is True else []) + ["--", button])
    return {"clicked": [x, y]}


# Typing on a Mac: the text is the script's argument, never its source (an x in front keeps a
# leading dash from reading as an option).
MAC_TYPE = ["-e", "on run argv", "-e", "tell application \"System Events\" to keystroke (text 2 thru -1 of (item 1 of argv))",
            "-e", "end run"]
# Keys on a Mac in xdotool's words: ctrl and control are the control key, cmd, command and super the
# command key, so the key the card names is the key pressed.
MAC_KEYS = {"Return": 36, "Tab": 48, "space": 49, "BackSpace": 51, "Escape": 53, "Delete": 117, "Left": 123,
            "Right": 124, "Down": 125, "Up": 126, "Home": 115, "End": 119, "Prior": 116, "Next": 121,
            "KP_Enter": 76, "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
            "F9": 101, "F10": 109, "F11": 103, "F12": 111}
MAC_MODS = {"ctrl": "control down", "control": "control down", "cmd": "command down", "command": "command down",
            "super": "command down", "alt": "option down", "option": "option down", "shift": "shift down"}


def mac_chord(chord):
    parts = chord.split("+")
    mods = []
    for part in parts[:-1]:
        mod = MAC_MODS.get(part.lower())
        if mod is None:
            raise RuntimeError("%s is not a modifier (ctrl, alt, shift, cmd)" % part)
        mods.append(mod)
    key = parts[-1]
    using = (" using {%s}" % ", ".join(mods)) if mods else ""
    if key in MAC_KEYS:
        line = "tell application \"System Events\" to key code %d%s" % (MAC_KEYS[key], using)
        run(["osascript", "-e", line])
    elif len(key) == 1 and key.isalnum():
        line = "tell application \"System Events\" to keystroke (item 1 of argv)" + using
        run(["osascript", "-e", "on run argv", "-e", line, "-e", "end run", key.lower()])
    else:
        raise RuntimeError("%s is not a key Serein can press on a Mac" % key)


def op_type(a):
    text = a.get("text")
    if not isinstance(text, str) or not text:
        raise RuntimeError("text is required")
    if MAC:
        run(["osascript"] + MAC_TYPE + ["x" + text], timeout=120)
        return {"typed": len(text)}
    run(["xdotool", "type", "--delay", "12", "--file", "-", "--"], stdin=text.encode(), timeout=120)
    return {"typed": len(text)}


def op_key(a):
    key = str(a.get("key", "")).strip()
    if not key or len(key) > 40 or not set(key) <= KEY_CHARS:
        raise RuntimeError("key is a key name or chord like Return, Tab, ctrl+l")
    chords = key.split()
    if len(chords) > MAX_CHORDS:
        raise RuntimeError("press at most %d keys or chords in one step" % MAX_CHORDS)
    if any(chord.lower() in XDOTOOL_COMMANDS for chord in chords):
        raise RuntimeError("key names keys and chords only, like Return, Tab, ctrl+l")
    if MAC:
        for chord in chords:
            mac_chord(chord)
        return {"pressed": key}
    # Each chord in its own call, after "--": no word can ever follow a command name.
    for index, chord in enumerate(chords):
        if index:
            time.sleep(0.04)
        run(["xdotool", "key", "--", chord])
    return {"pressed": key}


def op_scroll(a):
    x, y = to_screen(number(a.get("x"), "x"), number(a.get("y"), "y"))
    amount = max(1, min(30, number(a.get("amount", 3), "amount")))
    up = str(a.get("direction", "down")).lower() == "up"
    if MAC:
        run(["osascript", "-l", "JavaScript", "-e", MAC_SCROLL, str(x), str(y), "up" if up else "down", str(amount)])
        return {"scrolled": amount}
    button = "4" if up else "5"
    run(["xdotool", "mousemove", "--sync", "--", str(x), str(y)])
    run(["xdotool", "click", "--repeat", str(amount), "--delay", "30", "--", button])
    return {"scrolled": amount}


_SANDBOX_OK = None


def chromium_sandbox_works():
    """True when this machine lets Chromium build its own sandbox: an unprivileged user
    namespace can be made. Serein's built-in computer allows it; a Docker container started
    without extra rights does not. Checked once per process."""
    global _SANDBOX_OK
    if _SANDBOX_OK is None:
        try:
            done = subprocess.run(["unshare", "--user", "--map-root-user", "true"], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=5, env=ENV)
            _SANDBOX_OK = done.returncode == 0
        except Exception:
            _SANDBOX_OK = False
    return _SANDBOX_OK


def op_open_url(a):
    url = str(a.get("url", "")).strip()
    if not (url.startswith("https://") or url.startswith("http://")) or any(c.isspace() for c in url):
        raise RuntimeError("url must start with https:// or http://")
    if OWN:
        # The machine's own default browser, as the person set it up.
        subprocess.Popen(["open" if MAC else "xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, env=ENV)
        return {"opened": url}
    # Chromium keeps its own sandbox where the machine allows it (Serein's built-in computer has
    # user namespaces). Only where it cannot build one (a Docker container without extra rights)
    # does the container stand in as the sandbox. Encrypted Client Hello is off, so the name of
    # the site each connection asks for stays visible to Serein's proxy, which checks it.
    # Accessibility is forced on so the tree lists the page.
    args = ["chromium", "--no-first-run", "--no-default-browser-check", "--disable-gpu",
            "--disable-features=EncryptedClientHello",
            "--force-renderer-accessibility", "--window-size=1280,760", "--window-position=0,0"]
    if not chromium_sandbox_works():
        args.insert(1, "--no-sandbox")
    if not DIRECT:
        args.append("--proxy-server=" + PROXY)
    # The address goes in a page only this user reads, never in an argument: every user here can
    # read a process's arguments, and an address may carry a token.
    folder = tempfile.mkdtemp(prefix="open-", dir=TMP)
    page = os.path.join(folder, "go.html")
    with open(os.open(page, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        f.write("<script>location.replace(%s)</script>" % json.dumps(url).replace("<", "\\u003c"))
    subprocess.Popen(args + ["file://" + page], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, env=ENV)
    cleanup = threading.Timer(30, shutil.rmtree, args=(folder, True))
    cleanup.daemon = True  # a link that ends sooner leaves it where only this user reads it
    cleanup.start()
    return {"opened": url}


def op_run(a):
    command = a.get("command")
    if not isinstance(command, str) or not command.strip():
        raise RuntimeError("command is required")
    try:
        done = subprocess.run(["/bin/sh", "-c", "--", command], capture_output=True, timeout=COMMAND_TIMEOUT,
                              env=ENV, cwd=HOME, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise RuntimeError("The command took longer than %d seconds and was stopped." % COMMAND_TIMEOUT)
    output = (done.stdout + done.stderr).decode("utf-8", "replace")
    return {"output": output[:OUTPUT_LIMIT], "cut": len(output) > OUTPUT_LIMIT, "code": done.returncode}


def job_folder(job_id):
    """A detached job's folder, from an id Serein made (a lower-case UUID): nothing else names a path."""
    if not isinstance(job_id, str) or len(job_id) != 36 or not set(job_id) <= set("0123456789abcdef-"):
        raise RuntimeError("job is not one Serein started")
    return os.path.join(JOBS, job_id)


def write_small(path, text):
    """A small file of the job's, written whole (0600)."""
    part = path + ".part"
    with os.fdopen(os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write(text)
    os.replace(part, path)


def stop_group(pid):
    """Ends a job's process group: TERM now, KILL five seconds later for anything left."""
    try:
        os.killpg(pid, signal.SIGTERM)
    except OSError:
        return

    def kill():
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass

    threading.Timer(5, kill).start()


def op_job_start(a):
    if OWN:
        raise RuntimeError("Detached jobs run only in Serein's own computers.")
    command = a.get("command")
    if not isinstance(command, str) or not command.strip():
        raise RuntimeError("command is required")
    folder = job_folder(a.get("job"))
    os.makedirs(JOBS, mode=0o700, exist_ok=True)
    os.mkdir(folder, 0o700)
    with os.fdopen(os.open(os.path.join(folder, "command"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w",
                   encoding="utf-8") as f:
        f.write(command)
    # Its own session: the job outlives this helper and the stream that started it.
    argv = [sys.executable, "-I", os.path.abspath(__file__), "--job", folder] + ["--shell"] * SHELL_ONLY
    subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, env=ENV, cwd=HOME)
    return {"started": True, "log": os.path.join(folder, "output.log")}


def job_tail(folder):
    try:
        with open(os.path.join(folder, "output.log"), "rb") as f:
            f.seek(0, 2)
            start = max(0, f.tell() - JOB_TAIL)
            f.seek(start)
            data = f.read(JOB_TAIL)
        # Started inside a line: that line's rest goes, so no piece of a secret is sent cut.
        if start > 0 and b"\n" in data:
            data = data[data.index(b"\n") + 1:]
        return data.decode("utf-8", "replace")
    except OSError:
        return ""


def job_alive(folder):
    """The runner or its command still runs (or the runner has not written its pids yet)."""
    try:
        with open(os.path.join(folder, "pid")) as f:
            pids = [int(p) for p in f.read().split()[:2]]
    except (OSError, ValueError):
        return True
    for pid in pids:
        if pid <= 1:
            continue
        try:
            os.kill(pid, 0)
            return True
        except PermissionError:
            return True
        except OSError:
            continue
    return False


def op_job_status(a):
    ids = a.get("ids")
    if not isinstance(ids, list) or len(ids) > 20:
        raise RuntimeError("ids is a list of at most 20 jobs")
    jobs = {}
    for job_id in ids:
        try:
            folder = job_folder(job_id)
        except RuntimeError:
            continue
        if not os.path.isdir(folder):
            jobs[job_id] = {"known": False}
            continue
        try:
            with open(os.path.join(folder, "exit")) as f:
                ended = json.load(f)
            jobs[job_id] = {"known": True, "running": False, "code": ended.get("code"),
                            "timed_out": ended.get("timed_out") is True, "tail": job_tail(folder)}
        except (OSError, ValueError, AttributeError):
            alive = job_alive(folder)
            jobs[job_id] = {"known": True, "running": alive}
            if not alive:
                jobs[job_id].update({"code": None, "tail": job_tail(folder)})
    return {"jobs": jobs}


def op_job_stop(a):
    folder = job_folder(a.get("job"))
    try:
        with open(os.path.join(folder, "pid")) as f:
            job = int(f.read().split()[1])
    except (OSError, ValueError, IndexError):
        return {"stopped": False}
    if job > 1:
        stop_group(job)
    return {"stopped": True}


def job_mode(folder):
    """One detached job (see the module's docstring), in its folder under JOBS."""
    with open(os.path.join(folder, "command"), encoding="utf-8") as f:
        command = f.read()
    log_path = os.path.join(folder, "output.log")
    log = os.fdopen(os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb", buffering=0)
    proc = subprocess.Popen(["/bin/sh", "-c", "--", command], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, cwd=HOME, env=ENV, start_new_session=True)
    write_small(os.path.join(folder, "pid"), "%d %d" % (os.getpid(), proc.pid))
    timed_out = threading.Event()

    def overtime():
        timed_out.set()
        stop_group(proc.pid)

    timer = threading.Timer(JOB_TIME_LIMIT, overtime)
    timer.daemon = True
    timer.start()
    size = 0
    while True:
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            break
        if size + len(chunk) > JOB_LOG_LIMIT:
            # The newest half stays: the end of the output is what its message shows.
            with open(log_path, "rb") as f:
                f.seek(max(0, size - JOB_LOG_LIMIT // 2))
                kept = f.read()
            log.seek(0)
            log.truncate()
            log.write(b"[Earlier output was cut.]\n" + kept)
            size = log.tell()
        log.write(chunk)
        size += len(chunk)
    code = proc.wait()
    timer.cancel()
    log.close()
    write_small(os.path.join(folder, "exit"), json.dumps({"code": code, "timed_out": timed_out.is_set()}))


MAC_WINDOWS = """
tell application "System Events"
  set out to ""
  repeat with p in (every process whose visible is true)
    try
      repeat with w in (every window of p)
        try
          set out to out & (name of p) & tab & (name of w) & linefeed
        end try
      end repeat
    end try
  end repeat
end tell
return out
"""


def op_windows(a):
    if MAC:
        windows = []
        for line in run(["osascript", "-e", MAC_WINDOWS], timeout=30).decode("utf-8", "replace").splitlines():
            parts = line.split("\t", 1)
            if len(parts) == 2:
                windows.append({"id": parts[0][:80], "title": parts[1][:200]})
        return {"windows": windows}
    lines = run(["wmctrl", "-l"]).decode("utf-8", "replace").splitlines()
    windows = []
    for line in lines:
        parts = line.split(None, 3)
        if len(parts) == 4:
            windows.append({"id": parts[0], "title": parts[3][:200]})
    return {"windows": windows}


# The accessibility tree on a Mac through System Events: the front app's windows, or every visible
# app's windows whose title holds `window`; positions are mapped to screenshot pixels by argv 2, 3.
MAC_TREE = """
function run(argv) {
  var wanted = argv[0].slice(1).toLowerCase(), depth = Number(argv[1]), sx = Number(argv[2]), sy = Number(argv[3]);
  var se = Application("System Events");
  // Distinct apps walked, at most 50: a 51st stops the walk (cut), so no window is read unlisted.
  var lines = [], apps = [], seen = {}, cut = false, treeCut = false;
  function walk(el, level) {
    if (level > depth || lines.length > 2000) { treeCut = true; return; }
    var role = "", name = "", box = "";
    try { role = el.role(); } catch (e) {}
    try { name = el.name() || el.description() || ""; } catch (e) {}
    try {
      var p = el.position(), s = el.size();
      box = Math.round(p[0] / sx) + "," + Math.round(p[1] / sy) + " " + Math.round(s[0] / sx) + "x" + Math.round(s[1] / sy);
    } catch (e) {}
    lines.push(Array(level + 1).join("  ") + role + " " + JSON.stringify(String(name).slice(0, 80)) + " " + box);
    var kids = [];
    try { kids = el.uiElements(); } catch (e) { treeCut = true; }
    if (kids.length > 200 || String(name).length > 80) treeCut = true;
    for (var i = 0; i < kids.length && i < 200; i++) walk(kids[i], level + 1);
  }
  var procs = wanted ? se.processes.whose({visible: true})() : se.processes.whose({frontmost: true})();
  for (var i = 0; i < procs.length && !cut; i++) {
    var wins = [];
    try { wins = procs[i].windows(); } catch (e) {}
    for (var j = 0; j < wins.length; j++) {
      var title = "";
      try { title = wins[j].name() || ""; } catch (e) {}
      if (wanted && title.toLowerCase().indexOf(wanted) < 0) continue;
      var app = "", bundle = "";
      try { app = String(procs[i].name() || "").slice(0, 200); } catch (e) {}
      try { bundle = String(procs[i].bundleIdentifier() || "").slice(0, 200); } catch (e) {}
      var pair = JSON.stringify([app, bundle]);
      if (!seen[pair]) {
        if (apps.length >= 50) { cut = true; break; }
        seen[pair] = true;
        apps.push({app: app, bundle: bundle});
      }
      lines.push("window " + JSON.stringify(title) + " (" + app + ")");
      walk(wins[j], 1);
    }
  }
  return JSON.stringify({tree: lines.join("\\n"), apps: apps, apps_cut: cut, tree_cut: treeCut});
}
"""


def op_tree(a):
    if MAC:
        wanted = str(a.get("window", "")).strip()
        depth = max(1, min(12, number(a.get("depth", 6), "depth")))
        if SCALE is None:
            own_shot()
        front = front_app()
        # An x in front: the window's name is never read as one of osascript's options.
        shown = run(["osascript", "-l", "JavaScript", "-e", MAC_TREE, "x" + wanted, str(depth), str(SCALE[0]), str(SCALE[1])],
                    timeout=40).decode("utf-8", "replace")
        try:
            walked = json.loads(shown)
            text, apps, apps_cut = str(walked["tree"]), list(walked["apps"]), walked["apps_cut"] is True
        except (ValueError, KeyError, TypeError):
            raise RuntimeError("The accessibility tree could not be read on this Mac.")
        # Every app whose window was walked, so Serein can refuse when one of them holds secrets.
        answer = {"tree": text[:OUTPUT_LIMIT], "cut": len(text) > OUTPUT_LIMIT, "apps": apps[:50],
                  "apps_cut": apps_cut or len(apps) > 50}
        answer["cut"] = answer["cut"] or apps_cut or walked.get("tree_cut") is not False
        answer["privacy_complete"] = not answer["cut"] and not wanted
        answer.update(front)
        return answer
    if OWN and SCALE is None:
        own_shot()
    try:
        import pyatspi
    except ImportError:
        raise RuntimeError("The accessibility tree is not available in this computer.")
    wanted = str(a.get("window", "")).strip().lower()
    depth = max(1, min(12, number(a.get("depth", 6), "depth")))
    lines = []
    tree_cut = False

    def walk(node, level):
        nonlocal tree_cut
        if level > depth or len(lines) > 2000:
            tree_cut = True
            return
        try:
            name = node.name or ""
            role = node.getRoleName()
            ext = node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
            left, top = to_shot(ext.x, ext.y)
            width, height = to_shot(ext.width, ext.height)
            box = "%d,%d %dx%d" % (left, top, width, height)
        except Exception:
            tree_cut = True
            name, role, box = "", "?", ""
        try:
            focused = node.getState().contains(pyatspi.STATE_FOCUSED)
        except Exception:
            focused = False
        lines.append("%s%s %r %s%s" % ("  " * level, role, name[:80], box, " [focused]" if focused else ""))
        try:
            children = list(node)
        except Exception:
            children = []
            tree_cut = True
        if len(children) > 200 or len(name) > 80:
            tree_cut = True
        for child in children[:200]:
            walk(child, level + 1)

    def active(app):
        for window in app:
            try:
                if window is not None and window.getState().contains(pyatspi.STATE_ACTIVE):
                    return True
            except Exception:
                continue
        return False

    desktop = pyatspi.Registry.getDesktop(0)
    # Distinct apps walked, at most 50: a 51st stops the walk (apps_cut), so no window is read unlisted.
    apps, seen, apps_cut = [], set(), False
    for app in desktop:
        if apps_cut:
            break
        if app is None:
            continue
        # On the person's own machine with no window named, only the app in front is walked.
        if OWN and not wanted and not active(app):
            continue
        for window in app:
            if window is None:
                continue
            title = (window.name or "").lower()
            if wanted and wanted not in title:
                continue
            pair = (str(app.name or "")[:200], "")
            if pair not in seen:
                if len(apps) >= 50:
                    apps_cut = True
                    break
                seen.add(pair)
                apps.append({"app": pair[0], "bundle": pair[1]})
            lines.append("window %r (%s)" % (window.name, app.name))
            walk(window, 1)
    text = "\n".join(lines)
    answer = {"tree": text[:OUTPUT_LIMIT], "cut": len(text) > OUTPUT_LIMIT}
    answer["cut"] = answer["cut"] or tree_cut or apps_cut
    answer["privacy_complete"] = not answer["cut"] and not wanted
    if OWN:
        answer["apps"] = apps
        answer["apps_cut"] = apps_cut
        answer.update(front_app())
    return answer


def op_read_file(a):
    path = str(a.get("path", ""))
    start = max(0, number(a.get("start", 0), "start"))
    if not path:
        raise RuntimeError("path is required")
    with open(os.path.expanduser(path), "rb") as f:
        f.seek(start)
        data = f.read(OUTPUT_LIMIT + 1)
    text = data[:OUTPUT_LIMIT].decode("utf-8", "replace")
    return {"text": text, "next_start": start + OUTPUT_LIMIT if len(data) > OUTPUT_LIMIT else None}


def op_file_out(a):
    path = os.path.expanduser(str(a.get("path", "")))
    if not path:
        raise RuntimeError("path is required")
    if os.path.islink(path) or not os.path.isfile(path):
        raise RuntimeError("That is not a regular file.")
    size = os.path.getsize(path)
    if size > FILE_OUT_LIMIT:
        raise RuntimeError("The file is larger than 50 MB, the most the Outbox takes.")
    with open(path, "rb") as f:
        data = f.read(FILE_OUT_LIMIT + 1)
    return {"name": os.path.basename(path), "size": len(data), "data": base64.b64encode(data).decode()}


DIRECT_HOST_CHARS = set("abcdefghijklmnopqrstuvwxyz0123456789.-")


def op_direct(a):
    # Whether the computer reaches the internet without Serein's proxy: on a computer whose own
    # internet the provider says is off, any direct connection means it is not; on one held to a
    # list, a connection to a host off the list (Serein names them in `hosts`) means the list is
    # not held. Only a completed TLS handshake counts: a blocked connect can look open from inside.
    hosts = a.get("hosts") or ["1.1.1.1", "github.com"]
    if not isinstance(hosts, list) or not 1 <= len(hosts) <= 8 or not all(
        isinstance(h, str) and 1 <= len(h) <= 253 and set(h) <= DIRECT_HOST_CHARS for h in hosts
    ):
        raise ValueError("hosts must be 1 to 8 host names")
    context = ssl.create_default_context()
    for host in hosts:
        try:
            with socket.create_connection((host, 443), 3) as raw:
                raw.settimeout(3)
                context.wrap_socket(raw, server_hostname=host).close()
            return {"open": True, "host": host, "checked": len(hosts)}
        except OSError:
            continue
    return {"open": False, "checked": len(hosts)}


def op_file_in(a):
    name = os.path.basename(str(a.get("name", ""))).strip() or "file"
    data = base64.b64decode(str(a.get("data", "")))
    folder = os.path.join(HOME, "Desktop")
    os.makedirs(folder, exist_ok=True)
    target = os.path.join(folder, name)
    base, ext = os.path.splitext(name)
    n = 1
    while os.path.exists(target):
        n += 1
        target = os.path.join(folder, "%s %d%s" % (base, n, ext))
    with open(target, "wb") as f:
        f.write(data)
    os.chmod(target, 0o640)
    return {"path": target, "size": len(data)}


OPS = {
    "ping": op_ping, "screenshot": op_screenshot, "click": op_click, "type": op_type, "key": op_key,
    "scroll": op_scroll, "open_url": op_open_url, "run": op_run, "windows": op_windows, "tree": op_tree,
    "read_file": op_read_file, "file_out": op_file_out, "file_in": op_file_in, "direct": op_direct,
    "job_start": op_job_start, "job_status": op_job_status, "job_stop": op_job_stop,
}


def terminal_serve():
    """The desktop terminals' shells (see --term-client), served while this --shell helper runs."""
    try:
        # Bound under a name of its own, then moved over the old one: a second --shell helper
        # never leaves the path missing or pointing at nothing.
        made = "%s.%d" % (TERMINAL, os.getpid())
        if os.path.lexists(made):
            os.unlink(made)
        server = socket.socket(socket.AF_UNIX)
        server.bind(made)
        os.chmod(made, 0o660)
        server.listen(8)
        os.rename(made, TERMINAL)
        while True:
            conn = server.accept()[0]
            threading.Thread(target=terminal_session, args=(conn,), daemon=True).start()
    except OSError as error:
        sys.stderr.write("The desktop's terminals have no shell: %s\n" % error)


def terminal_session(conn):
    # The client's first frame names the command and folder (see --term-client).
    held = b""
    try:
        conn.settimeout(10)
        while len(held) < 3 or len(held) < 3 + int.from_bytes(held[1:3], "big"):
            data = conn.recv(65536)
            if not data:
                raise OSError("closed")
            held += data
        end = 3 + int.from_bytes(held[1:3], "big")
        start = json.loads(held[3:end]) if held[0] == 2 else None
        argv, cwd = start["argv"], start["cwd"]
        if not (isinstance(argv, list) and all(isinstance(a, str) for a in argv) and isinstance(cwd, str)):
            raise ValueError("start")
        held = held[end:]
    except (OSError, ValueError, TypeError, KeyError):
        conn.close()
        return
    pid, master = pty.fork()
    if pid == 0:
        try:
            if os.access(cwd, os.R_OK | os.X_OK):
                os.chdir(cwd)
            env = dict(ENV, TERM="xterm-256color", SHELL="/bin/bash")
            if argv:
                os.execvpe(argv[0], argv, env)
            os.execve("/bin/bash", ["-bash"], env)
        except OSError as error:
            os.write(2, ("%s: %s\r\n" % (argv[0] if argv else "bash", error.strerror)).encode())
        finally:
            os._exit(127)
    # Neither side ever waits on a write: what a side cannot take yet is held (up to RELAY_HELD,
    # then that side's source is not read), so a shell pouring output while keys pour in never
    # leaves both ends blocked writing to each other.
    conn.setblocking(False)
    os.set_blocking(master, False)
    to_conn = to_pty = b""
    try:
        while True:
            while len(held) >= 3 and len(held) >= 3 + int.from_bytes(held[1:3], "big"):
                end = 3 + int.from_bytes(held[1:3], "big")
                kind, body, held = held[0], held[3:end], held[end:]
                if kind == 0:
                    to_pty += body
                elif kind == 1 and len(body) == 4:
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", *struct.unpack(">HH", body), 0, 0))
            reads = ([master] if len(to_conn) < RELAY_HELD else []) + ([conn] if len(to_pty) < RELAY_HELD else [])
            readable, writable = select.select(reads, ([conn] if to_conn else []) + ([master] if to_pty else []), [])[:2]
            try:
                if master in readable:
                    try:
                        data = os.read(master, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        data = b""  # Linux signals PTY EOF with EIO.
                    if not data:
                        break
                    to_conn += data
                if conn in readable:
                    data = conn.recv(65536)
                    if not data:
                        return
                    held += data
                if conn in writable:
                    to_conn = to_conn[conn.send(to_conn):]
                if master in writable:
                    to_pty = to_pty[os.write(master, to_pty):]
            except BlockingIOError:
                continue
        # A fast command can exit while its final bytes still await socket writability.
        # Only PTY EOF reaches here. A disconnected client goes straight to cleanup.
        if to_conn:
            conn.settimeout(TERMINAL_DRAIN_SECONDS)
            conn.sendall(to_conn)
    except OSError:
        pass
    finally:
        conn.close()
        os.close(master)
        stop_group(pid)
        os.waitpid(pid, 0)


def term_client(args):
    """A desktop terminal's shell (see the module's docstring), or its command after `--run --`. In a
    locked computer it never falls back to a shell of its own."""
    argv = args[2:] if args[:2] == ["--run", "--"] else None
    locked = os.path.exists(os.path.join(TMP, "xauth"))
    if argv is None and "-c" in args:
        # `$SHELL -c` from a program of the desktop: its own /bin/sh only where nothing is locked.
        if locked:
            sys.exit("Serein's computer runs no command as the desktop's user. Run it with computer_run, or in a "
                     "terminal from the panel.")
        os.execv("/bin/sh", ["/bin/sh"] + args)
    argv = argv or []
    if not locked:
        # Not a locked computer (a hosted desktop start.sh did not start): the desktop user's own.
        if argv:
            os.execvp(argv[0], argv)
        os.execv("/bin/bash", ["-bash"])
    try:
        here = os.getcwd()
    except OSError:
        here = ""
    start = json.dumps({"argv": argv, "cwd": here}).encode()
    if len(start) > 65535:
        sys.exit("This command is too long for a terminal; run it with computer_run.")
    conn = socket.socket(socket.AF_UNIX)
    try:
        conn.connect(TERMINAL)
    except OSError:
        sys.stdout.write("This terminal's shell comes through Serein, which is not linked to the computer now.\r\n"
                         "Ask Serein to use the computer, then open a new terminal. Press Enter to close.")
        sys.stdout.flush()
        sys.stdin.readline()
        sys.exit(1)

    def frame(kind, body):
        return bytes([kind]) + len(body).to_bytes(2, "big") + body

    def size():
        rows, cols = struct.unpack("HHHH", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\0" * 8))[:2]
        return frame(1, struct.pack(">HH", rows, cols))

    # A resize only wakes the loop, which sends it, so its frame never lands inside another.
    wake, woken = os.pipe()
    os.set_blocking(woken, False)
    signal.set_wakeup_fd(woken)
    signal.signal(signal.SIGWINCH, lambda *_: None)
    saved = termios.tcgetattr(0)
    tty.setraw(0)
    # The socket is never waited on to take keys (see terminal_session): the shell's output is
    # always read, and keys wait in `up` while the shell is not taking them.
    conn.setblocking(False)
    up = frame(2, start) + size()
    try:
        while True:
            reads = [conn, wake] + ([0] if len(up) < RELAY_HELD else [])
            readable, writable = select.select(reads, [conn] if up else [], [])[:2]
            try:
                if wake in readable:
                    os.read(wake, 512)
                    up += size()
                if 0 in readable:
                    data = os.read(0, 65535)
                    if not data:
                        break
                    up += frame(0, data)
                if conn in readable:
                    data = conn.recv(65536)
                    if not data:
                        break
                    while data:
                        data = data[os.write(1, data):]
                if conn in writable:
                    up = up[conn.send(up):]
            except BlockingIOError:
                continue
    except OSError:
        pass
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, saved)


# xfce4-terminal 1.0's own options (`xfce4-terminal --help`): those that take a value, and those
# that take none. Every program on the desktop that opens a terminal (the panel, exo's
# TerminalEmulator helpers, x-terminal-emulator, GIO's Terminal=true) reaches it through --terminal.
TERMINAL_VALUES = {"--title", "--dynamic-title-mode", "--initial-title", "--working-directory", "--color-text",
                   "--color-bg", "--display", "--geometry", "--role", "--startup-id", "--icon", "--font", "--zoom",
                   "--default-display", "--default-working-directory"}
TERMINAL_FLAGS = {"-h", "--help", "-V", "--version", "--disable-server", "--color-table", "--preferences", "--tab",
                  "--window", "-H", "--hold", "--active-tab", "--drop-down", "--fullscreen", "--maximize",
                  "--minimize", "--show-menubar", "--hide-menubar", "--show-borders", "--hide-borders",
                  "--show-toolbar", "--hide-toolbar", "--show-scrollbar", "--hide-scrollbar"}


def terminal(args):
    """--terminal (see the module's docstring). Values go on glued to their option, so the real
    parser reads each one as the value it is here."""
    import shlex
    out, i = [], 0

    def refuse(why):
        sys.stderr.write("xfce4-terminal: %s. Serein's computer runs a terminal's command as `shell`; run "
                         "commands with computer_run.\n" % why)
        sys.exit(1)

    while i < len(args):
        arg, value = args[i], None
        name = arg.split("=", 1)[0]
        if arg in ("-x", "--execute"):
            if args[i + 1:]:
                out += ["-x", TERM_CLIENT, "--run", "--"] + args[i + 1:]
            break
        if arg in ("-e", "--command", "-T", "--title", "-I", "--icon") or arg in TERMINAL_VALUES:
            if i + 1 >= len(args):
                refuse("%s needs a value" % arg)
            name, value, i = {"-e": "--command", "-T": "--title", "-I": "--icon"}.get(arg, arg), args[i + 1], i + 1
        elif "=" in arg and (name == "--command" or name in TERMINAL_VALUES):
            value = arg.split("=", 1)[1]
        elif arg not in TERMINAL_FLAGS:
            refuse("%r is not an option of this terminal" % arg)
        if name == "--command":
            try:
                command = shlex.split(value)
            except ValueError:
                refuse("the command %r does not parse" % value)
            if command:
                out.append("--command=" + shlex.join([TERM_CLIENT, "--run", "--"] + command))
        elif value is not None:
            out.append(name + "=" + value)
        else:
            out.append(arg)
        i += 1
    os.execve("/usr/bin/xfce4-terminal.distrib", ["xfce4-terminal"] + out, dict(os.environ, SHELL=TERM_CLIENT))


def helper_mode():
    if SHELL_ONLY and not OWN:
        threading.Thread(target=terminal_serve, daemon=True).start()
    out = sys.stdout.buffer
    for line in sys.stdin.buffer:
        try:
            request = json.loads(line)
        except ValueError:
            continue
        request_id = request.get("id")
        op = OPS.get(request.get("op"))
        try:
            if op is None:
                raise RuntimeError("unknown op")
            answer = op(request)
            answer["id"] = request_id
        except Exception as error:  # every failure is one line back, never a dead helper
            answer = {"id": request_id, "error": str(error)[:400] or error.__class__.__name__}
        out.write(json.dumps(answer).encode() + b"\n")
        out.flush()


OPEN, DATA, CLOSE = 1, 2, 3


def proxy_mode():
    out = sys.stdout.buffer
    out_lock = threading.Lock()
    conns = {}
    conns_lock = threading.Lock()

    def send(conn_id, kind, payload=b""):
        with out_lock:
            out.write(struct.pack(">IBI", conn_id, kind, len(payload)) + payload)
            out.flush()

    def pump(conn_id, sock):
        try:
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                send(conn_id, DATA, chunk)
        except OSError:
            pass
        send(conn_id, CLOSE)
        with conns_lock:
            conns.pop(conn_id, None)
        try:
            sock.close()
        except OSError:
            pass

    def from_serein():
        stdin = sys.stdin.buffer
        while True:
            head = stdin.read(9)
            if len(head) < 9:
                os._exit(0)
            conn_id, kind, length = struct.unpack(">IBI", head)
            payload = stdin.read(length) if length else b""
            with conns_lock:
                sock = conns.get(conn_id)
            if sock is None:
                continue
            try:
                if kind == DATA:
                    sock.sendall(payload)
                elif kind == CLOSE:
                    sock.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    # The port first: one held by anything else (a command that took it while no shim ran) would
    # get the browser's traffic, so the shim ends instead of serving beside it.
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(("127.0.0.1", 3128))
        server.listen(64)
    except OSError as error:
        sys.stderr.write("The proxy port 127.0.0.1:3128 is taken: %s\n" % error)
        sys.exit(2)
    threading.Thread(target=from_serein, daemon=True).start()
    next_id = 0
    while True:
        sock, _ = server.accept()
        next_id += 1
        with conns_lock:
            conns[next_id] = sock
        send(next_id, OPEN)
        threading.Thread(target=pump, args=(next_id, sock), daemon=True).start()


def armor_mode(argv):
    out = sys.stdout.buffer
    if not argv:
        out.write(b"!2\n")
        out.flush()
        return
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=HOME, env=ENV)
    except OSError:
        out.write(b"!127\n")
        out.flush()
        return

    def feed():
        try:
            for line in sys.stdin.buffer:
                line = line.strip()
                if not line:
                    continue
                if line == b".":
                    break
                proc.stdin.write(base64.b64decode(line, validate=True))
                proc.stdin.flush()
        except (OSError, ValueError):
            pass
        try:
            proc.stdin.close()
        except OSError:
            pass

    threading.Thread(target=feed, daemon=True).start()
    while True:
        chunk = os.read(proc.stdout.fileno(), 49152)
        if not chunk:
            break
        out.write(b":" + base64.b64encode(chunk) + b"\n")
        out.flush()
    code = proc.wait()
    out.write(b"!%d\n" % (code if code >= 0 else 128 - code))
    out.flush()


VSOCK_PORT = 6100
LINE_LIMIT = 65536


def read_request(conn):
    line = b""
    while not line.endswith(b"\n"):
        chunk = conn.recv(1)
        if not chunk or len(line) >= LINE_LIMIT:
            return None
        line += chunk
    try:
        request = json.loads(line)
    except ValueError:
        return None
    argv = request.get("argv") if isinstance(request, dict) else None
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and a for a in argv):
        return None
    return argv, bool(request.get("stdin")), bool(request.get("framed"))


def serve_link(conn):
    request = read_request(conn)
    if request is None:
        return
    argv, want_stdin, framed = request
    if not framed:
        # The command speaks over the connection itself: the helper's JSON lines, or the shim's frames.
        os.dup2(conn.fileno(), 0)
        os.dup2(conn.fileno(), 1)
        null = os.open(os.devnull, os.O_WRONLY)
        os.dup2(null, 2)
        try:
            os.execvpe(argv[0], argv, session_env())
        except OSError:
            return
    lock = threading.Lock()

    def frame(kind, payload):
        with lock:
            conn.sendall(struct.pack(">B3xI", kind, len(payload)) + payload)

    try:
        proc = subprocess.Popen(argv, stdin=conn.fileno() if want_stdin else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=HOME, env=session_env())
    except OSError as error:
        frame(2, str(error).encode()[:400])
        frame(3, b"127")
        return

    def pump(stream, kind):
        while True:
            chunk = os.read(stream.fileno(), 65536)
            if not chunk:
                break
            frame(kind, chunk)

    pumps = [threading.Thread(target=pump, args=(proc.stdout, 1)), threading.Thread(target=pump, args=(proc.stderr, 2))]
    for thread in pumps:
        thread.start()
    for thread in pumps:
        thread.join()
    frame(3, str(proc.wait()).encode())
    conn.shutdown(socket.SHUT_RDWR)


def vsock_mode():
    import signal
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
    server.listen(16)
    while True:
        conn, (cid, _port) = server.accept()
        # Only the Mac running this computer; nothing else can reach the port, and nothing else is served.
        if cid != socket.VMADDR_CID_HOST:
            conn.close()
            continue
        if os.fork() != 0:
            conn.close()
            continue
        # The child waits for its own commands: their exit codes must reach Serein.
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        server.close()
        try:
            serve_link(conn)
        except OSError:
            pass
        os._exit(0)


# What makes the desktop's programs run a command line or load code, in its home: entries
# (Exec and the helpers' commands), launcher folders, menus, saved sessions, and the settings
# that name a command. The desktop holds the screen, so a file a model wrote there (the browser's
# Save as, a settings window, an old checkpoint) must never run as it. --scrub (start.sh, and
# after a checkpoint is restored) and --guard (kept running by start.sh, on every write) leave
# each one inert and the person's other files as they are: an entry whose commands are not the
# image's own is renamed NAME.serein-off; a setting that names a command not in the image's own
# defaults is dropped; a link that points into a folder `shell` can write, or nowhere, is removed.
# The list of what the desktop's programs read in the home was measured (docs/handoff/cua-computer.md,
# "Measured surface"), not written from memory.
OFF = ".serein-off"
# Folders the desktop never writes in ordinary use: each is a link to an empty folder of the
# image's (root's), so nothing can be saved there, not even for the moment before a pass. One
# found as a folder (an old home, or one made since) is switched off whole. So are the desktop's
# custom actions (Thunar/uca.xml: its commands run from a file icon's menu; the image's own stay)
# and the folders whose files name a library the browser loads: NSS module lists, Vulkan layers.
# So are the panel's launcher folders: the panel reads a file there again the moment it changes and
# runs its command on the next press, before any pass. Its launchers name the image's own entries
# instead (see panel_item), and a custom command there was always switched off. Their link's folder
# holds an empty launcher-N for each plugin id, as the panel cannot live without one (its copy of an
# entry fails cleanly there; with no folder it crashes). shortcut: ids 1 to 200 (the panel takes the lowest
# free one), so a launcher with a higher id crashes the panel when it gets an item; raise the Dockerfile's count then.
SEALED = "/usr/share/serein/sealed"
SEALED_DIRS = dict.fromkeys([".local/share/applications", ".local/share/xfce4/helpers", ".local/share/xfce4/panel/plugins",
                             ".config/menus", ".config/Thunar", ".pki", ".local/share/pki", ".config/vulkan",
                             ".local/share/vulkan"], SEALED) | {".config/xfce4/panel": "/usr/share/serein/panel"}
# The lists that choose which program opens a type of file or link (GIO reads ~/.config/mimeapps.list
# and DESKTOP-mimeapps.list there; the ones in ~/.local/share/applications are sealed): a choice
# stays only when the image itself makes it, by an entry that lists the type or its own mimeapps.list.
MIME_GROUPS = ("[Default Applications]", "[Added Associations]", "[MIME Cache]")
SYSTEM_MIMEAPPS = ["/etc/xdg/mimeapps.list", "/usr/share/applications/mimeapps.list"]
ENTRY_DIRS = [(".local/share/applications", True), (".config/autostart", False), (".local/share/xfce4/helpers", False),
              ("Desktop", False)]
WHOLE_DIRS = [".local/share/xfce4/panel/plugins", ".config/menus", ".cache/sessions"]
COMMAND_KEYS = {"Exec", "X-XFCE-Commands", "X-XFCE-CommandsWithParameter", "X-XFCE-Binaries"}
SYSTEM_ENTRIES = ["/usr/share/applications", "/usr/local/share/applications", "/etc/xdg/autostart",
                  "/usr/share/xfce4/helpers"]
XFCONF = ".config/xfce4/xfconf/xfce-perchannel-xml"
SYSTEM_XFCONF = "/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
# Per channel, the properties whose values name a command or code: each value must be one of the
# image's own defaults for that channel.
XFCONF_COMMANDS = {
    "xfce4-keyboard-shortcuts": ("/commands/",),
    "xfce4-session": ("/general/LockCommand", "/sessions/"),
    "xsettings": ("/Gtk/Modules",),
    "xfce4-terminal": ("/run-custom-command", "/custom-command"),
}
# The keys of other settings files that name a command or code, or the folder whose entries the
# desktop shows as launchers (user-dirs.dirs: it stays ~/Desktop, guarded above).
DROPPED_KEYS = {".config/xfce4/terminal/terminalrc": ("RunCustomCommand", "CustomCommand"),
                ".config/Terminal/terminalrc": ("RunCustomCommand", "CustomCommand"),
                ".config/gtk-3.0/settings.ini": ("gtk-modules",), ".config/gtk-4.0/settings.ini": ("gtk-modules",),
                ".config/user-dirs.dirs": ("XDG_DESKTOP_DIR",)}
HELPERS_RC = ".config/xfce4/helpers.rc"
SHELL_WRITES = ("/home/serein/work", "/tmp", "/var/tmp", "/dev/shm", "/run")
READ_LIMIT = 4_000_000


def entry_commands(data):
    found = set()
    for line in data.decode("utf-8", "replace").splitlines():
        key, eq, value = line.partition("=")
        if eq and key.split("[")[0].strip() in COMMAND_KEYS:
            found.add(value.strip())
    return found


def read_small(path):
    with open(path, "rb") as f:
        data = f.read(READ_LIMIT + 1)
    if len(data) > READ_LIMIT:
        raise OSError("too big")
    return data


def system_commands():
    found = set()
    for folder in SYSTEM_ENTRIES:
        for name in os.listdir(folder) if os.path.isdir(folder) else []:
            try:
                found |= entry_commands(read_small(os.path.join(folder, name)))
            except OSError:
                pass
    return found


def helper_categories():
    found = {}
    folder = "/usr/share/xfce4/helpers"
    for name in os.listdir(folder) if os.path.isdir(folder) else []:
        try:
            for line in read_small(os.path.join(folder, name)).decode("utf-8", "replace").splitlines():
                if line.startswith("X-XFCE-Category="):
                    found[name[:-len(".desktop")]] = line.split("=", 1)[1].strip()
        except OSError:
            pass
    return found


def switch_off(path):
    os.replace(path, path + OFF)


def seal(path, target):
    if not os.path.isdir(target) or os.path.islink(path) and os.readlink(path) == target:
        return
    if os.path.lexists(path):
        off, n = path + OFF, 1
        while os.path.lexists(off):
            n += 1
            off = "%s%s%d" % (path, OFF, n)
        os.rename(path, off)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.symlink(target, path)


def image_mime_apps():
    """Per type, the apps the image itself names for it."""
    found = {}

    def add(kind, apps):
        found.setdefault(kind.strip(), set()).update(a.strip() for a in apps.split(";") if a.strip())
    for folder in ("/usr/share/applications", "/usr/local/share/applications"):
        for name in os.listdir(folder) if os.path.isdir(folder) else []:
            try:
                for line in read_small(os.path.join(folder, name)).decode("utf-8", "replace").splitlines():
                    if line.startswith("MimeType="):
                        for kind in line[len("MimeType="):].split(";"):
                            add(kind, name)
            except OSError:
                pass
    for path in SYSTEM_MIMEAPPS:
        group = ""
        try:
            for line in read_small(path).decode("utf-8", "replace").splitlines():
                group = line.strip() if line.startswith("[") else group
                if group in MIME_GROUPS and "=" in line:
                    add(*line.split("=", 1))
        except OSError:
            pass
    return found


def rewrite(path, data):
    """`data` in place of the file at `path`, whole or not at all, with its mode."""
    mode = os.stat(path).st_mode & 0o777
    fd, made = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".serein-")
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(made, mode)
    os.replace(made, path)


def risky(path):
    """A link that points nowhere yet, or into a folder `shell` can write."""
    target = os.path.realpath(path)
    return not os.path.exists(path) or any(target == w or target.startswith(w + "/") for w in SHELL_WRITES)


def unlinked_ancestor(path):
    """Removes a risky link at `path` or at any folder above it in the home; True when one was there."""
    rel = os.path.relpath(path, HOME).split(os.sep)
    for depth in range(1, len(rel) + 1):
        part = os.path.join(HOME, *rel[:depth])
        if os.path.islink(part) and risky(part):
            os.unlink(part)
            return True
    return False


def regular_files(folder, deep):
    """The files in a folder (and below it when `deep`). A risky link there is removed, and in a
    folder read deep so is a link to a folder (only the link: what it points to stays)."""
    found = []
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        if os.path.islink(path) and (risky(path) or deep and os.path.isdir(path)):
            os.unlink(path)
        elif deep and os.path.isdir(path):
            found += regular_files(path, deep)
        elif os.path.isfile(path) and not name.endswith(OFF):
            found.append(path)
    return found


def foreign(path, commands):
    """An entry whose commands are not all the image's own; one Serein cannot read counts."""
    try:
        return not entry_commands(read_small(path)) <= commands
    except OSError:
        return True


def panel_item(item):
    """A launcher item that is one of the image's entries, by path or file URI, as the image's layout
    names them and the panel saves one added from its list. A bare name would have the panel copy the
    entry into its sealed folder, which it does not survive."""
    import urllib.parse
    path = urllib.parse.unquote(item[len("file://"):]) if item.startswith("file:///") else item
    real = os.path.realpath(path)
    return path.startswith("/") and os.path.dirname(real) in SYSTEM_ENTRIES[:2] and os.path.isfile(real)


def scrub_xfconf(path, channel, system):
    """Drops what names a command; returns the properties dropped, which xfconfd may still hold."""
    import xml.etree.ElementTree as ET
    prefixes = XFCONF_COMMANDS.get(channel, ())
    try:
        root = ET.fromstring(read_small(path))
    except (ET.ParseError, ValueError):
        switch_off(path)
        return []

    def values(prop):
        own = [prop.get("value")] if prop.get("value") is not None else []
        return own + [v.get("value") or "" for v in prop.findall("value")]

    dropped = []

    def walk(parent, at):
        for prop in list(parent.findall("property")):
            where = at + "/" + (prop.get("name") or "")
            name = prop.get("name") or ""
            guarded = any(where.startswith(p) for p in prefixes) and not all(v in system for v in values(prop))
            panel = channel == "xfce4-panel" and (name in ("custom-menu-file", "custom-menu") or (
                name == "items" and parent.get("value") == "launcher" and not all(panel_item(v) for v in values(prop))
            ) or prop.get("value") == "directorymenu")
            if guarded or panel:
                parent.remove(prop)
                dropped.append(where)
            else:
                walk(prop, where)

    walk(root, "")
    if dropped:
        rewrite(path, ET.tostring(root, encoding="UTF-8"))
    return dropped


def reset_live(channel, props):
    """xfconfd keeps a value it has loaded whatever its file now says: reset each one there too."""
    try:
        with open(os.path.join(TMP, "dbus-address")) as f:
            env = dict(ENV, DBUS_SESSION_BUS_ADDRESS=f.read().strip())
    except OSError:
        return  # no session yet: xfconfd will load the file as it is now
    for prop in props:
        subprocess.run(["xfconf-query", "-c", channel, "-p", prop, "-r", "-R"], env=env, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if channel == "xfce4-panel":
        # The panel's plugins ignore a reset (a dropped launcher's button stayed and ran): it reloads.
        subprocess.run(["xfce4-panel", "-r"], env=dict(env, XAUTHORITY=os.path.join(TMP, "xauth")), timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def xfconf_values(channel):
    import xml.etree.ElementTree as ET
    try:
        root = ET.fromstring(read_small(os.path.join(SYSTEM_XFCONF, channel + ".xml")))
    except (OSError, ET.ParseError):
        return set()
    return {e.get("value") for e in root.iter() if e.get("value") is not None}


def scrub_config(commands, categories, apps, live=False):
    """One pass over every file that names a command (see OFF); quiet about files that are gone.
    `live` resets in xfconfd what it drops from xfconf files (--guard, while the session runs)."""
    def each(path, fix):
        try:
            if not unlinked_ancestor(path):
                fix(path)
        except (OSError, subprocess.SubprocessError):
            pass

    panel = os.path.join(HOME, ".config/xfce4/panel")
    if not live and os.path.isdir(panel) and not os.path.islink(panel):
        # An older home's launchers name copies in that folder, now sealed: its panel starts from the image's layout.
        each(os.path.join(HOME, XFCONF, "xfce4-panel.xml"), lambda p: os.path.isfile(p) and switch_off(p))
    for rel, target in SEALED_DIRS.items():
        sealed = os.path.join(HOME, rel)
        each(os.path.dirname(sealed), lambda _, path=sealed, target=target: seal(path, target))
    for rel, deep in ENTRY_DIRS:
        folder = os.path.join(HOME, rel)
        each(folder, lambda f: [switch_off(p) for p in regular_files(f, deep) if foreign(p, commands)])
    for rel in WHOLE_DIRS:
        each(os.path.join(HOME, rel), lambda f: [switch_off(p) for p in regular_files(f, True)])
    xfconf = os.path.join(HOME, XFCONF)

    def channels(folder):
        for path in regular_files(folder, False):
            if path.endswith(".xml"):
                channel = os.path.basename(path)[:-4]
                dropped = scrub_xfconf(path, channel, xfconf_values(channel))
                if live and dropped:
                    reset_live(channel, dropped)
    each(xfconf, channels)

    def mime_list(path):
        lines, kept, group = read_small(path).split(b"\n"), [], ""
        for line in lines:
            text = line.decode("utf-8", "replace")
            group = text.strip() if text.startswith("[") else group
            kind, eq, value = text.partition("=")
            named = [a.strip() for a in value.split(";") if a.strip()]
            own = [a for a in named if a in apps.get(kind.strip(), ())]
            if eq and group in MIME_GROUPS and own != named:
                if not own:
                    continue
                line = ("%s=%s;" % (kind, ";".join(own))).encode()
            kept.append(line)
        if kept != lines:
            rewrite(path, b"\n".join(kept))
    config = os.path.join(HOME, ".config")
    each(config, lambda folder: [mime_list(p) for p in regular_files(folder, False)
                                 if os.path.basename(p) == "mimeapps.list" or p.endswith("-mimeapps.list")])

    def keys(path, drop):
        lines = read_small(path).split(b"\n")
        kept = [l for l in lines if l.split(b"=")[0].strip().decode("utf-8", "replace") not in drop]
        if len(kept) != len(lines):
            rewrite(path, b"\n".join(kept))
    for rel, drop in DROPPED_KEYS.items():
        each(os.path.join(HOME, rel), lambda p: os.path.isfile(p) and keys(p, drop))

    def helpers(path):
        lines = read_small(path).split(b"\n")
        kept = []
        for line in lines:
            key, eq, value = line.decode("utf-8", "replace").partition("=")
            if not eq or categories.get(value.strip()) == key.strip():
                kept.append(line)
        if len(kept) != len(lines):
            rewrite(path, b"\n".join(kept))
    each(os.path.join(HOME, HELPERS_RC), lambda p: os.path.isfile(p) and helpers(p))


def scrub_home(full=True):
    """--scrub, at start and after a checkpoint goes back: nothing in the home keeps a setuid or
    setgid bit, ~/work's too (but ~/work's own setgid, which keeps its files in the desktop user's
    group); outside ~/work, links that reach risky places go and nothing stays writable by the
    group (the `shell` user's); then every file that names a command. A folder of the desktop
    user's own that shuts its owner out is opened to it, so nothing below hides from the walk.
    The guard sweeps the bits alone (full=False)."""
    work = os.path.join(HOME, "work")
    for top, dirs, files in os.walk(HOME):
        for name in dirs + files:
            path = os.path.join(top, name)
            bits_only = not full or path == work or path.startswith(work + "/")
            try:
                fd = os.open(path, os.O_PATH | os.O_NOFOLLOW)
            except OSError:
                continue
            try:
                st = os.fstat(fd)
                if stat.S_ISLNK(st.st_mode):
                    if not bits_only and risky(path):
                        os.unlink(path)
                    continue
                mode = st.st_mode & 0o7777
                kept = mode & (0o1777 if bits_only else 0o1755) | (mode & 0o2000 if path == work else 0)
                if stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid():
                    kept |= 0o500
                if kept != mode:
                    # The file it opened, never a link the shell user put in its place since.
                    os.chmod("/proc/self/fd/%d" % fd, kept)
            except OSError:
                pass
            finally:
                os.close(fd)
    if full:
        scrub_config(system_commands(), helper_categories(), image_mime_apps())


SWEEP = 30


def guard_home():
    """--guard: scrub_config again after every write under the folders it reads, for as long as
    the desktop runs (start.sh keeps it running, and starts the session only once it has written
    its pid to /tmp/serein/guard after its first pass). A folder made later is watched from then
    on: each pass watches every folder there is again first."""
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    fd = libc.inotify_init1(os.O_CLOEXEC)
    commands, categories, apps = system_commands(), helper_categories(), image_mime_apps()
    folders = {HOME, os.path.join(HOME, HELPERS_RC.rsplit("/", 1)[0]), os.path.join(HOME, XFCONF)}
    folders |= {os.path.join(HOME, rel) for rel, _ in ENTRY_DIRS} | {os.path.join(HOME, r) for r in WHOLE_DIRS}
    folders |= {os.path.join(HOME, rel) for rel in SEALED_DIRS}
    folders |= {os.path.dirname(os.path.join(HOME, rel)) for rel in DROPPED_KEYS}
    for folder in list(folders):
        while folder != HOME:
            folder = os.path.dirname(folder)
            folders.add(folder)
    deep = [os.path.join(HOME, rel) for rel, d in ENTRY_DIRS if d] + [os.path.join(HOME, r) for r in WHOLE_DIRS]

    def watch():
        every = set(folders)
        for top in deep:
            for here, dirs, _ in os.walk(top):
                every.add(here)
        for folder in every:
            if fd >= 0 and os.path.isdir(folder):
                libc.inotify_add_watch(fd, folder.encode(), 0x8 | 0x80 | 0x100)  # close-write, moved-to, create

    marked, swept = False, 0
    while True:
        try:
            watch()
            scrub_config(commands, categories, apps, live=True)
            if not marked:
                write_small(os.path.join(TMP, "guard"), str(os.getpid()))
                marked = True
            # A setuid or setgid bit that appears in the home goes within SWEEP seconds.
            if time.time() - swept >= SWEEP:
                scrub_home(full=False)
                swept = time.time()
            if fd < 0:
                time.sleep(1)
                continue
            select.select([fd], [], [], SWEEP)
            time.sleep(0.02)
            while select.select([fd], [], [], 0)[0]:
                os.read(fd, 65536)
        except Exception as error:  # the guard never stops while the desktop runs
            sys.stderr.write("guard: %s\n" % error)
            time.sleep(1)


def exo_open(args):
    """exo-open for the desktop's programs (the Dockerfile moves the real one aside): it opens a
    desktop entry as a program, so a file the model could write or a desktop entry outside the
    image's own folders opens nothing, with or without --launch (a helper given its parameter).
    Only exo-open's own options pass: any other word that starts with "-" (a GTK module, or a flag
    for the helper's program) is refused. URLs go on. A file goes on as the path it was checked at,
    with no link in it, so nothing swapped in after the check is what opens."""
    import urllib.parse
    try:
        here = os.getcwd()
    except OSError:
        here = "/"
    words, base, i = [], here, 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            words += range(i + 1, len(args))
            break
        if arg in ("--launch", "--working-directory"):
            if arg == "--working-directory" and i + 1 < len(args):
                base = args[i + 1]
            i += 1  # its value: the helper's category, or a folder
        elif arg.startswith("--working-directory="):
            base = arg.partition("=")[2]
        elif not (arg in ("-h", "-?", "--help", "-V", "--version") or arg.startswith("--launch=")):
            if arg.startswith("-"):
                sys.stderr.write("Serein's computer passes no option %r through exo-open.\n" % arg)
                sys.exit(1)
            words.append(i)
        i += 1
    argv = list(args)
    for at in words:
        url = urllib.parse.urlparse(argv[at])
        if url.scheme and url.scheme != "file":  # urlparse lower-cases it, as GIO reads it
            continue
        path = urllib.parse.unquote(url.path) if url.scheme else argv[at]
        # A relative path as exo-open may read it: from the working directory given, or its own.
        reals = [os.path.realpath(os.path.join(folder, path)) for folder in (base, here)]
        for real in reals:
            entry = any(p.lower().endswith((".desktop", ".kdelnk")) for p in (path, real))
            refused = any(real.startswith(w + "/") for w in SHELL_WRITES) or (
                entry and not real.startswith("/usr/share/applications/"))
            if not refused and os.path.isfile(real) and not real.startswith(("/usr/share/", "/etc/xdg/")):
                try:
                    with open(real, "rb") as f:
                        refused = b"[Desktop Entry]" in f.read(4096)
                except OSError:
                    pass
            if refused:
                sys.stderr.write("Serein's computer opens no launcher or command file from %s. Run commands "
                                 "with computer_run, open apps from the Applications menu, pages with "
                                 "computer_open_url.\n" % path)
                sys.exit(1)
        if os.path.exists(reals[0]):
            argv[at] = reals[0]
    os.execv("/usr/bin/exo-open.distrib", ["exo-open"] + argv)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--exo-open"]:
        exo_open(sys.argv[2:])
    elif sys.argv[1:2] == ["--terminal"]:
        terminal(sys.argv[2:])
    elif sys.argv[1:2] == ["--scrub"]:
        scrub_home()
    elif sys.argv[1:2] == ["--guard"]:
        guard_home()
    elif sys.argv[1:2] == ["--term-client"]:
        term_client(sys.argv[2:])
    elif sys.argv[1:2] == ["--armor"]:
        rest = sys.argv[2:]
        armor_mode(rest[1:] if rest[:1] == ["--"] else rest)
    elif "--proxy" in sys.argv[1:]:
        proxy_mode()
    elif "--vsock" in sys.argv[1:]:
        vsock_mode()
    elif "--job" in sys.argv[1:]:
        # Only a folder of JOBS itself: the argument names nothing else.
        index = sys.argv.index("--job")
        target = os.path.realpath(sys.argv[index + 1]) if index + 1 < len(sys.argv) else ""
        if os.path.dirname(target) != os.path.realpath(JOBS):
            sys.exit(2)
        job_mode(target)
    else:
        helper_mode()
