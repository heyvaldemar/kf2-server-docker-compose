#!/usr/bin/env python3
# fake-kf2.py - a stand-in for the Killing Floor 2 server, for
# tests/e2e-moderation.sh. It does the three things the moderation tools
# depend on and nothing else:
#
#   - answers A2S_INFO and A2S_PLAYER on 127.0.0.1:<port>, with a challenge
#     first the way the real server does; the player count is read from
#     /data/players and the roster from /data/names on every query, so a test
#     can change them while it runs; it stays silent while /data/silent exists;
#   - "rewrites its config at startup": copies the fixture ini into place on
#     first start, and on every start drops any BannedIDs line whose id is
#     named in /data/drop-on-start, then deletes that marker, which is how a
#     test proves that the read-back notices an id the server did not keep;
#   - exits promptly on SIGTERM, and counts its starts in /data/starts.
#
# No game files and no download: the pinned image's python3 is all it needs,
# which is the same python3 the tools use in production.
import os
import re
import signal
import socket
import struct
import sys
import time

INI = os.environ.get("KF2_FAKE_INI", "/data/serverfiles/KFGame/Config/kf2server/LinuxServer-KFGame.ini")
FIXTURE = "/fixture.ini"
PORT = int(os.environ.get("KF2_FAKE_QUERY_PORT", "27015"))
NAME = "fake | kf2 (test)"
MAP = "KF-BioticsLab"
CHALLENGE = b"\x11\x22\x33\x44"


def read(name, default):
    try:
        with open("/data/" + name) as f:
            return f.read()
    except OSError:
        return default


os.makedirs(os.path.dirname(INI), exist_ok=True)
if not os.path.exists(INI):
    with open(FIXTURE, "rb") as src, open(INI, "wb") as dst:
        dst.write(src.read())
drop = read("drop-on-start", "").split()
if drop:
    with open(INI, encoding="utf-8", errors="surrogateescape", newline="") as f:
        text = f.read()
    nl = "\r\n" if "\r\n" in text else "\n"
    keep = []
    for line in text.splitlines():
        m = re.fullmatch(r"BannedIDs=\(Uid=\(A=(-?\d+),B=(-?\d+)\)\)", line)
        if m and str((int(m.group(2)) << 32) | (int(m.group(1)) & 0xFFFFFFFF)) in drop:
            print("fake-kf2: dropping %s at startup" % line, flush=True)
            continue
        keep.append(line)
    with open(INI, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(nl.join(keep) + nl)
    os.remove("/data/drop-on-start")
with open("/data/starts", "a") as f:
    f.write("%d\n" % int(time.time()))

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", PORT))
print("fake-kf2: listening on 127.0.0.1:%d" % PORT, flush=True)


def cstr(s):
    return s.encode() + b"\x00"


while True:
    data, peer = sock.recvfrom(4096)
    if os.path.exists("/data/silent"):
        continue
    if len(data) < 5 or data[:4] != b"\xff\xff\xff\xff":
        continue
    kind = data[4:5]
    if kind == b"T":
        if data[-4:] != CHALLENGE:
            sock.sendto(b"\xff\xff\xff\xffA" + CHALLENGE, peer)
            continue
        players = int(read("players", "0").strip() or "0")
        pkt = (b"\xff\xff\xff\xffI" + bytes([17]) + cstr(NAME) + cstr(MAP) + cstr("kfgame")
               # A 16-bit field; the engine itself truncates the app id here
               # and carries the full one in the extra data, which the tools
               # never read.
               + cstr("Killing Floor 2") + struct.pack("<H", 232090 & 0xFFFF)
               + bytes([players, 6, 0]) + b"d" + b"l" + bytes([0, 1]))
        sock.sendto(pkt, peer)
    elif kind == b"U":
        if data[5:9] != CHALLENGE:
            sock.sendto(b"\xff\xff\xff\xffA" + CHALLENGE, peer)
            continue
        names = [n for n in read("names", "").splitlines() if n.strip()]
        pkt = b"\xff\xff\xff\xffD" + bytes([len(names)])
        for i, name in enumerate(names):
            pkt += bytes([i]) + cstr(name) + struct.pack("<if", 10 * (i + 1), 600.0 * (i + 1))
        sock.sendto(pkt, peer)
