#!/usr/bin/env python3
"""Hace de tablet para probar la Mac sin Android (hito 2).

Se conecta a TabMonitor en 127.0.0.1:8081, manda hello, contesta lo que pide PROTOCOL.md y pasa
el video a ffplay en modo de baja latencia. Cada segundo manda ping e imprime la ida y vuelta.

    Scripts/view-stream.py                 ver el monitor virtual en una ventana
    Scripts/view-stream.py --save x.h264   además guarda el H.264 crudo (ffprobe x.h264)
    Scripts/view-stream.py --no-view       solo cuenta frames, sin ffplay
"""
import argparse
import json
import socket
import struct
import subprocess
import sys
import threading
import time

VIDEO, HELLO, CONFIG, KEY, PING, PONG, STATS = 0x01, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15


def message(kind, payload=b""):
    return struct.pack(">BI", kind, len(payload)) + payload


def read_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("la Mac cerró la conexión")
        buf += chunk
    return bytes(buf)


def now_ms():
    return time.monotonic_ns() // 1_000_000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8081)
    ap.add_argument("--save")
    ap.add_argument("--no-view", action="store_true")
    ap.add_argument("--size", default="960x600", help="tamaño de la ventana de ffplay")
    args = ap.parse_args()

    sock = socket.create_connection(("127.0.0.1", args.port))
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    hello = {"w": 2560, "h": 1600, "model": "view-stream.py", "android": "-",
             "maxDecode": {"w": 2560, "h": 1600, "fps": 60}}
    sock.sendall(message(HELLO, json.dumps(hello, separators=(",", ":")).encode()))

    player = None
    if not args.no_view:
        player = subprocess.Popen(
            ["ffplay", "-hide_banner", "-loglevel", "warning", "-window_title", "TabMonitor (prueba)",
             "-x", args.size.split("x")[0], "-y", args.size.split("x")[1], "-left", "0", "-top", "40",
             "-fflags", "nobuffer", "-flags", "low_delay", "-framedrop", "-probesize", "32",
             "-analyzeduration", "0", "-sync", "ext", "-f", "h264", "-i", "-", "-vf", "setpts=0"],
            stdin=subprocess.PIPE)
    saved = open(args.save, "wb") if args.save else None

    lock = threading.Lock()

    def pinger():
        while True:
            time.sleep(1)
            with lock:
                sock.sendall(message(PING, json.dumps({"ts": now_ms()}).encode()))

    threading.Thread(target=pinger, daemon=True).start()

    frames = keyframes = size = 0
    first_key = False
    last_report = time.monotonic()
    try:
        while True:
            kind, length = struct.unpack(">BI", read_exact(sock, 5))
            payload = read_exact(sock, length)
            if kind == VIDEO:
                key = payload[0] & 1
                nal = payload[9:]
                if key:
                    keyframes += 1
                    first_key = True
                if not first_key:
                    continue
                frames += 1
                size += len(payload)
                if player:
                    try:
                        player.stdin.write(nal)
                        player.stdin.flush()
                    except BrokenPipeError:
                        print("ffplay se cerró")
                        return
                if saved:
                    saved.write(nal)
            elif kind == CONFIG:
                print("config:", payload.decode())
            elif kind == PONG:
                pong = json.loads(payload)
                print(f"ping: ida y vuelta {now_ms() - pong['ts']} ms")
            t = time.monotonic()
            if t - last_report >= 2:
                print(f"video: {frames / (t - last_report):.1f} fps, {size * 8 / (t - last_report) / 1e6:.1f} Mbps, "
                      f"keyframes {keyframes}")
                frames = keyframes = size = 0
                last_report = t
    except (ConnectionError, KeyboardInterrupt) as e:
        print(e or "cortado")
    finally:
        sock.close()
        if saved:
            saved.close()
        if player:
            player.stdin.close()
            player.wait()


if __name__ == "__main__":
    sys.exit(main())
