# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — re-entrant helper mains (keeper / gamescope / IM watch)

session_keeper_main() {
  exec python3 - "$1" <<'PY'
import array
import fcntl
import ipaddress
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse

session = sys.argv[1]
me = os.getpid()
netns = os.readlink("/proc/self/ns/net")
userns = os.readlink("/proc/self/ns/user")


def log(*args):
    print(time.strftime("%F %T"), *args, flush=True)


def pin_name_server_routes():
    """Give every name server a host route through the adapter it is reached
    by now. An accelerator in TUN mode routes everything into its adapter and
    sends the lookups for game domains through its node, where each takes one
    of the user's UDP sessions; past a few hundred the node stops answering,
    lookups time out and games cannot reach their servers. With these routes
    lookups go out as without the accelerator. Only the namespace's own routes
    change, so no privileges are needed."""
    ip = shutil.which("ip")
    try:
        with open("/etc/resolv.conf") as file:
            lines = file.read().splitlines()
    except OSError:
        return
    for line in lines:
        fields = line.split()
        if fields[:1] != ["nameserver"] or len(fields) < 2 or not ip:
            continue
        try:
            server = ipaddress.ip_address(fields[1].partition("%")[0])
        except ValueError:
            continue
        if server.is_loopback or server.is_link_local:
            continue  # never routed into an adapter
        family = "-6" if server.version == 6 else "-4"
        try:
            route = json.loads(subprocess.run([ip, "-j", family, "route", "get", str(server)],
                                              capture_output=True, text=True).stdout or "[]")[0]
        except (ValueError, IndexError):
            continue
        if route.get("dev") in (None, "lo"):
            continue
        command = [ip, family, "route", "replace", f"{server}/{server.max_prefixlen}", "dev", route["dev"]]
        if route.get("gateway"):
            command[5:5] = ["via", route["gateway"]]
        result = subprocess.run(command, capture_output=True, text=True)
        log(" ".join(command[1:]), result.stderr.strip() or "ok")


# pasta maps the user to root in the namespace. libdbus sends that uid (0) when
# it authenticates to the session bus, the bus sees the real uid on the socket
# and refuses the connection, so tray icons, notifications and everything else
# on D-Bus stopped working. The bridge lets clients authenticate to it,
# authenticates to the bus without claiming a uid (the bus then takes the real
# one from the socket) and then just copies bytes. File descriptor passing is
# refused, so the clients fall back to plain messages.
def bus_address_path(address):
    for entry in (address or "").split(";"):
        kind, _, params = entry.partition(":")
        if kind != "unix":
            continue
        for param in params.split(","):
            key, _, value = param.partition("=")
            if key == "path":
                return urllib.parse.unquote(value)
    return None


class BusAuthError(Exception):
    pass


def bus_read_line(sock, buffer):
    while b"\r\n" not in buffer:
        data = sock.recv(4096)
        if not data:
            raise BusAuthError("connection closed")
        buffer += data
        if len(buffer) > 16384:
            raise BusAuthError("line too long")
    line, _, rest = bytes(buffer).partition(b"\r\n")
    buffer[:] = rest
    return line.decode("ascii", "replace")


def bus_connect_upstream(path):
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    upstream.connect(path)
    upstream.sendall(b"\0AUTH EXTERNAL\r\n")
    buffer = bytearray()
    reply = bus_read_line(upstream, buffer)
    if reply.startswith("DATA"):
        upstream.sendall(b"DATA\r\n")
        reply = bus_read_line(upstream, buffer)
    if not reply.startswith("OK "):
        upstream.close()
        raise BusAuthError(f"the bus refused us: {reply}")
    return upstream, reply


def bus_copy(src, dst):
    try:
        while data := src.recv(65536):
            dst.sendall(data)
    except OSError:
        pass
    for sock, how in ((dst, socket.SHUT_WR), (src, socket.SHUT_RD)):
        try:
            sock.shutdown(how)
        except OSError:
            pass


def bus_serve_client(client, path):
    upstream = None
    try:
        buffer = bytearray()
        while not buffer:
            if not (data := client.recv(4096)):
                return
            buffer += data
        if buffer[0] != 0:
            return
        del buffer[0]
        ok = None
        while True:
            line = bus_read_line(client, buffer)
            command, _, arg = line.partition(" ")
            if command == "AUTH" and arg.startswith("EXTERNAL"):
                if arg == "EXTERNAL":  # no initial response: ask for it
                    client.sendall(b"DATA\r\n")
                    continue
            elif command == "DATA":
                pass
            elif command == "NEGOTIATE_UNIX_FD":
                client.sendall(b"ERROR\r\n")
                continue
            elif command == "BEGIN" and ok:
                upstream.sendall(b"BEGIN\r\n" + bytes(buffer))
                break
            elif command in ("AUTH", "CANCEL"):
                client.sendall(b"REJECTED EXTERNAL\r\n")
                continue
            else:
                client.sendall(b"ERROR\r\n")
                continue
            # the client has identified itself; anyone who can reach the
            # socket is the user, so accept and authenticate upstream
            if not ok:
                upstream, ok = bus_connect_upstream(path)
            client.sendall(ok.encode() + b"\r\n")
        threading.Thread(target=bus_copy, args=(upstream, client), daemon=True).start()
        bus_copy(client, upstream)
    except (OSError, BusAuthError):
        pass
    finally:
        client.close()
        if upstream:
            upstream.close()


def start_bus_bridge():
    upstream = bus_address_path(os.environ.get("DBUS_SESSION_BUS_ADDRESS"))
    if not upstream:
        log("no session bus to bridge")
        return
    path = os.path.join(session, "bus")
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(64)

    def accept():
        while True:
            try:
                client, _ = server.accept()
            except OSError:
                return
            threading.Thread(target=bus_serve_client, args=(client, upstream), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()


# Games reach the Steam client on 127.0.0.1:57343, here the namespace's own
# loopback. While Steam runs on the host, a listener here passes their
# connections on to it through the gateway address, which pasta takes to the
# host's loopback. It holds the port only meanwhile: a Steam started in the
# namespace, once the host's is gone, takes it itself.
STEAM_PORT = 57343


def default_gateway():
    try:
        routes = json.loads(subprocess.run(["ip", "-j", "-4", "route", "show", "default"],
                                           capture_output=True, text=True).stdout or "[]")
    except (OSError, ValueError):
        return None
    return next((route["gateway"] for route in routes if route.get("gateway")), None)


def host_steam_listening():
    """Whether the host's Steam client takes connections; pasta (our parent)
    and init run in the host's namespace and show its sockets."""
    local = f"0100007F:{STEAM_PORT:04X}"
    for pid in (os.getppid(), 1):
        try:
            with open(f"/proc/{pid}/net/tcp") as file:
                next(file)
                return any(fields[1] == local and fields[3] == "0A"
                           for fields in (line.split() for line in file))
        except (OSError, StopIteration, IndexError):
            continue
    return False


class SteamForward:
    def __init__(self):
        self.gateway = default_gateway()
        self.listener = None

    def update(self):
        if not self.gateway:
            return
        wanted = host_steam_listening()
        if wanted and not self.listener:
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                listener.bind(("127.0.0.1", STEAM_PORT))
                listener.listen(64)
            except OSError:
                listener.close()  # a Steam in the namespace has it
                return
            self.listener = listener
            threading.Thread(target=self.accept, args=(listener,), daemon=True).start()
            log(f"passing port {STEAM_PORT} on to the host's Steam")
        elif not wanted and self.listener:
            try:
                self.listener.shutdown(socket.SHUT_RDWR)  # wakes accept()
            except OSError:
                pass
            self.listener.close()
            self.listener = None
            log(f"port {STEAM_PORT} let go, the host's Steam is gone")

    def accept(self, listener):
        while True:
            try:
                client, _ = listener.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(client,), daemon=True).start()

    def serve(self, client):
        try:
            upstream = socket.create_connection((self.gateway, STEAM_PORT), timeout=5)
            upstream.settimeout(None)
        except OSError:
            client.close()
            return
        threading.Thread(target=bus_copy, args=(client, upstream), daemon=True).start()
        try:
            while data := upstream.recv(65536):
                client.sendall(data)
        except OSError:
            pass
        # reset the connection rather than close it first: that would leave the
        # port in TIME_WAIT for a minute, keeping a Steam started here from it
        try:
            client.shutdown(socket.SHUT_RD)  # wakes the other direction
            client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        except OSError:
            pass
        client.close()
        upstream.close()


# A Linux program of the session runs as the user in a user namespace of its
# own (pasta makes the user root here, which programs like Steam refuse), and
# from there cannot enter the session's. The wrapper it starts for a Windows
# program, a game Steam starts say, asks here instead: the keeper starts the
# wrapper with the request's command line, environment and folder, on the
# caller's standard input, output and error, answers with its exit status,
# and stops it if the caller goes away first.
def launch_serve(conn):
    fds = array.array("i")
    try:
        size, ancdata, _, _ = conn.recvmsg(4, socket.CMSG_LEN(3 * fds.itemsize))
        for level, kind, data in ancdata:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                fds.frombytes(data[:len(data) - len(data) % fds.itemsize])
        if len(size) != 4 or len(fds) != 3:
            return
        size = int.from_bytes(size, "big")
        data = bytearray()
        while len(data) < size:
            chunk = conn.recv(size - len(data))
            if not chunk:
                return
            data += chunk
        request = json.loads(data)
        child = subprocess.Popen(request["argv"], env=request["env"], cwd=request["cwd"],
                                 stdin=fds[0], stdout=fds[1], stderr=fds[2], start_new_session=True)
        for fd in fds:
            os.close(fd)
        del fds[:]
        log("started for a program of the session:", " ".join(request["argv"][1:])[:300])

        def stop_if_caller_gone():
            try:
                conn.recv(1)
            except OSError:
                pass
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except OSError:
                    pass

        threading.Thread(target=stop_if_caller_gone, daemon=True).start()
        status = child.wait()
        try:
            conn.sendall((status if status >= 0 else 128 - status).to_bytes(4, "big", signed=True))
        except OSError:
            pass  # the caller is gone, which stopped the program
    except (OSError, ValueError, KeyError, TypeError) as error:
        log("launch request failed:", error)
    finally:
        for fd in fds:
            os.close(fd)
        try:
            conn.shutdown(socket.SHUT_RDWR)  # wakes stop_if_caller_gone
        except OSError:
            pass
        conn.close()


def start_launch_server():
    path = os.path.join(session, "launch")
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(16)

    def accept():
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return
            threading.Thread(target=launch_serve, args=(conn,), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()


def others():
    """Processes in the namespace other than the keeper."""
    count = 0
    for name in os.listdir("/proc"):
        if not name.isdigit() or int(name) == me:
            continue
        try:
            if os.readlink(f"/proc/{name}/ns/net") == netns:
                count += 1
        except OSError:
            pass
    return count


def cleanup():
    # only our own: a keeper that never became the session's leaves its files
    try:
        with open(os.path.join(session, "keeper.pid")) as file:
            if file.read().strip() not in ("", str(me)):
                return
    except OSError:
        pass
    for name in ("keeper.pid", "netns", "userns", "bus", "launch"):
        try:
            os.unlink(os.path.join(session, name))
        except FileNotFoundError:
            pass


def stop(_signum, _frame):
    cleanup()
    log("stopped")
    os._exit(0)


for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, stop)
pin_name_server_routes()
start_bus_bridge()
start_launch_server()
steam_forward = SteamForward()
steam_forward.update()
for name, value in (("netns", netns), ("userns", userns)):
    with open(os.path.join(session, name), "w") as file:
        file.write(value)
with open(os.path.join(session, "keeper.pid.tmp"), "w") as file:
    file.write(str(me))
os.rename(os.path.join(session, "keeper.pid.tmp"), os.path.join(session, "keeper.pid"))
log("session up", netns)

# Programs join under the session lock and hold it until they are inside, so
# the keeper takes it before deciding the namespace is empty. Nobody joining
# within a minute means the program that asked for it failed to start.
lock = os.open(os.path.join(session, "lock"), os.O_RDWR | os.O_CREAT, 0o600)
seen = False
started = time.monotonic()
while True:
    time.sleep(1)
    steam_forward.update()
    if others():
        seen = True
        continue
    if not seen and time.monotonic() - started < 60:
        continue
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        continue
    if others():
        fcntl.flock(lock, fcntl.LOCK_UN)
        seen = True
        continue
    cleanup()
    log("session empty, closing" if seen else "nobody joined, closing")
    break
PY
}

# Gamescope runs its own Xwayland, which the desktop's input method is not
# connected to, so nothing could be typed in Chinese there. This helper,
# started by Gamescope in front of the program, asks fcitx5 over D-Bus to serve
# that display as well, again whenever fcitx5 restarts (Wine's XIM otherwise
# stays on a server that is gone and swallows every key). A Gamescope in a
# window can start it before its Xwayland takes connections, and fcitx5 then
# never serves the display, so it waits for the display and makes sure fcitx5
# has registered there before starting the program. Nothing happens without
# fcitx5; the bus is never asked to start one.
gamescope_session_main() {
  exec python3 - "$SELF_PATH" "$@" <<'PY'
import ctypes
import ctypes.util
import os
import signal
import subprocess
import sys
import threading
import time

self_path, command = sys.argv[1], sys.argv[2:]


def x11_lib():
    try:
        x11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
    except OSError:
        return None
    voidp, ulong = ctypes.c_void_p, ctypes.c_ulong
    x11.XOpenDisplay.restype = voidp
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XCloseDisplay.argtypes = [voidp]
    x11.XDefaultRootWindow.restype = ulong
    x11.XDefaultRootWindow.argtypes = [voidp]
    x11.XInternAtom.restype = ulong
    x11.XInternAtom.argtypes = [voidp, ctypes.c_char_p, ctypes.c_int]
    x11.XGetAtomName.restype = voidp
    x11.XGetAtomName.argtypes = [voidp, ulong]
    x11.XGetWindowProperty.argtypes = [voidp, ulong, ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int, ulong,
                                       voidp, voidp, voidp, voidp, voidp]
    x11.XFree.argtypes = [voidp]
    return x11


def wait_for_display(x11, display, seconds=10):
    """A connection to display once its X server takes them, or None."""
    deadline = time.monotonic() + seconds
    while True:
        dpy = x11.XOpenDisplay(display.encode())
        if dpy or time.monotonic() > deadline:
            return dpy
        time.sleep(0.1)


def fcitx_serves(x11, dpy):
    """Whether fcitx5 has registered its XIM server on the display."""
    kind, fmt, count, after = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong()
    data = ctypes.POINTER(ctypes.c_ulong)()
    servers = x11.XInternAtom(dpy, b"XIM_SERVERS", 0)
    if x11.XGetWindowProperty(dpy, x11.XDefaultRootWindow(dpy), servers, 0, 64, 0, 4,  # XA_ATOM
                              ctypes.byref(kind), ctypes.byref(fmt), ctypes.byref(count), ctypes.byref(after),
                              ctypes.byref(data)) or not data:
        return False
    found = False
    for index in range(count.value):
        name = x11.XGetAtomName(dpy, data[index])
        if name:
            found = found or ctypes.string_at(name) == b"@server=fcitx"
            x11.XFree(name)
    x11.XFree(data)
    return found


def until_fcitx_serves(display, open_display):
    x11 = x11_lib()
    dpy = wait_for_display(x11, display) if x11 else None
    if not dpy:
        open_display()
        return
    for _attempt in range(2):
        open_display()
        for _ in range(20):
            if fcitx_serves(x11, dpy):
                x11.XCloseDisplay(dpy)
                return
            time.sleep(0.1)
    print(f"winrun: fcitx5 did not take {display}", file=sys.stderr)
    x11.XCloseDisplay(dpy)


def follow_input_method(display):
    """Have the session's fcitx5 serve display too, now and whenever it
    (re)starts, from a background thread. False without a session bus."""
    try:
        import gi
        gi.require_version("Gio", "2.0")
        from gi.repository import Gio, GLib
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except Exception as exc:  # no gi, no bus
        print(f"winrun: no input method in gamescope: {exc}", file=sys.stderr)
        return False

    def open_display():
        try:
            bus.call_sync("org.fcitx.Fcitx5", "/controller", "org.fcitx.Fcitx.Controller1", "OpenX11Connection",
                          GLib.Variant("(s)", (display,)), None, Gio.DBusCallFlags.NO_AUTO_START, 5000, None)
        except GLib.Error as exc:  # e.g. an fcitx5 without the method
            print(f"winrun: fcitx5 cannot serve {display}: {exc.message}", file=sys.stderr)

    def owner_changed(_bus, _sender, _path, _interface, _signal, parameters):
        if parameters.unpack()[2]:  # a new fcitx5 knows nothing about this display
            open_display()

    bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus",
                         "org.fcitx.Fcitx5", Gio.DBusSignalFlags.NONE, owner_changed)
    threading.Thread(target=GLib.MainLoop().run, daemon=True).start()
    owned, = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                           GLib.Variant("(s)", ("org.fcitx.Fcitx5",)), GLib.VariantType("(b)"),
                           Gio.DBusCallFlags.NONE, 2000, None).unpack()
    if owned:
        until_fcitx_serves(display, open_display)
    return True


display = os.environ.get("DISPLAY")
watcher = None
if display and follow_input_method(display):
    watcher = subprocess.Popen([self_path, "--ime-watch", display])
child = subprocess.Popen(command)
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, lambda signum, _frame: child.send_signal(signum))
try:
    status = child.wait()
finally:
    if watcher:
        watcher.terminate()
sys.exit(status if status >= 0 else 128 - status)
PY
}

# fcitx5's candidate window on Gamescope's display belongs to another process,
# and Gamescope only shows popups of the focused app. Until the display goes
# away, give fcitx5's windows there the STEAM_GAME of Gamescope's focused
# window, so Gamescope takes them as that app's, and mark them layered and
# transparent the way Wine marks windows: Gamescope then paints them on top as
# decorations instead of handing them the keyboard as popups, which lost the
# release of the key that switched the input method (Super stayed down).
ime_watch_main() {
  exec python3 - "$1" <<'PY'
import ctypes
import ctypes.util
import os
import sys

display = sys.argv[1]
x11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
ulong, voidp = ctypes.c_ulong, ctypes.c_void_p
x11.XOpenDisplay.restype = voidp
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XDefaultRootWindow.restype = ulong
x11.XDefaultRootWindow.argtypes = [voidp]
x11.XInternAtom.restype = ulong
x11.XInternAtom.argtypes = [voidp, ctypes.c_char_p, ctypes.c_int]
x11.XSelectInput.argtypes = [voidp, ulong, ctypes.c_long]
x11.XNextEvent.argtypes = [voidp, voidp]
x11.XGetClassHint.argtypes = [voidp, ulong, voidp]
x11.XFree.argtypes = [voidp]
x11.XGetWindowProperty.argtypes = [voidp, ulong, ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int, ulong,
                                   voidp, voidp, voidp, voidp, voidp]
x11.XChangeProperty.argtypes = [voidp, ulong, ulong, ulong, ctypes.c_int, ctypes.c_int, voidp, ctypes.c_int]
x11.XFlush.argtypes = [voidp]

# windows can go away between an event and our request: ignore the errors, and
# leave quietly once Gamescope is gone
on_error = ctypes.CFUNCTYPE(ctypes.c_int, voidp, voidp)(lambda *_: 0)
on_io_error = ctypes.CFUNCTYPE(ctypes.c_int, voidp)(lambda _: os._exit(0))
x11.XSetErrorHandler(on_error)
x11.XSetIOErrorHandler(on_io_error)


class ClassHint(ctypes.Structure):
    _fields_ = [("res_name", voidp), ("res_class", voidp)]


dpy = x11.XOpenDisplay(display.encode())
if not dpy:
    sys.exit(0)
root = x11.XDefaultRootWindow(dpy)
steam_game = x11.XInternAtom(dpy, b"STEAM_GAME", 0)
ex_style = x11.XInternAtom(dpy, b"_WINE_HWND_EXSTYLE", 0)
focused = x11.XInternAtom(dpy, b"GAMESCOPE_FOCUSED_WINDOW", 0)
cardinal = 6  # XA_CARDINAL
x11.XSelectInput(dpy, root, (1 << 19) | (1 << 22))  # SubstructureNotify, PropertyChange


def focused_window():
    kind, fmt, count, after, data = ulong(), ctypes.c_int(), ulong(), ulong(), ctypes.POINTER(ctypes.c_long)()
    if x11.XGetWindowProperty(dpy, root, focused, 0, 1, 0, cardinal, ctypes.byref(kind), ctypes.byref(fmt),
                              ctypes.byref(count), ctypes.byref(after), ctypes.byref(data)) or not data:
        return 0
    value = data[0] if count.value else 0
    x11.XFree(data)
    return value & 0xffffffff


def is_input_method(window):
    hint = ClassHint()
    if not x11.XGetClassHint(dpy, window, ctypes.byref(hint)):
        return False
    found = bool(hint.res_class) and ctypes.string_at(hint.res_class).lower() == b"fcitx"
    for pointer in (hint.res_name, hint.res_class):
        if pointer:
            x11.XFree(pointer)
    return found


def tag(window, app):
    for prop, value in ((ex_style, 0x80000 | 0x20), (steam_game, app)):  # WS_EX_LAYERED | WS_EX_TRANSPARENT
        value = ctypes.c_long(value)
        x11.XChangeProperty(dpy, window, prop, cardinal, 32, 0, ctypes.byref(value), 1)  # PropModeReplace


windows = set()
event = (ctypes.c_long * 24)()  # XEvent; fields read by their offset on 64-bit
while True:
    x11.XNextEvent(dpy, event)
    kind = event[0] & 0xffffffff
    if kind == 19:  # MapNotify: window at 40
        window = event[5] & 0xffffffff
        if window in windows or is_input_method(window):
            windows.add(window)
            if app := focused_window():
                tag(window, app)
    elif kind == 17:  # DestroyNotify: window at 40
        windows.discard(event[5] & 0xffffffff)
    elif kind == 28 and event[5] == focused and windows:  # PropertyNotify: atom at 40
        if app := focused_window():
            for window in windows:
                tag(window, app)
    x11.XFlush(dpy)
PY
}

