#!/usr/bin/env python3
"""
模拟 iPhone 端：在本机监听 FXP/2 端口，验证 PC 端 USB 隧道。

用法：
    python tools/test-phone.py --port 28767 --out received [--duration 20]

它会：
  1. accept 一个连接
  2. 读文本行握手（DYH2/2 + JSON），回 DYA2/2 + JSON
  3. 循环解析 28 字节 FXP/2 帧头 + 载荷
  4. 视频（type 0x10）写 received.h264，音频（type 0x11）写 received.aac
  5. 结束时打印统计（帧数/关键帧/字节/最大帧/时间戳单调性）

随后可用 ffprobe 校验：
    ffprobe -f h264 received.h264
    ffprobe -f aac  received.aac
"""
import argparse
import os
import socket
import struct
import sys
import time

MAGIC = 0x324D5944
HEADER = 28

FRAME_NAMES = {
    0x01: "CONFIG", 0x02: "PING", 0x03: "PONG", 0x04: "STOP",
    0x05: "REQUEST_IDR", 0x10: "VIDEO", 0x11: "AUDIO", 0x12: "META",
}


def read_exact(conn, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=28767)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--out", default="received")
    ap.add_argument("--duration", type=float, default=0, help="秒；0 表示一直收到断开")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    outdir = os.path.dirname(os.path.abspath(args.out)) or "."
    os.makedirs(outdir, exist_ok=True)
    video_path = args.out + ".h264"
    audio_path = args.out + ".aac"

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, args.port))
    srv.listen(1)
    print(f"[phone] 监听 {args.bind}:{args.port}，等待 PC 连接…", flush=True)

    srv.settimeout(30)
    try:
        conn, addr = srv.accept()
    except socket.timeout:
        print("[phone] 等待连接超时", file=sys.stderr)
        return 2

    conn.settimeout(10)
    print(f"[phone] 已连接 {addr}", flush=True)

    # ---- 握手 ----
    handshake = b""
    while handshake.count(b"\n") < 2 and len(handshake) < 8192:
        b = conn.recv(1)
        if not b:
            print("[phone] 握手阶段对端关闭", file=sys.stderr)
            return 3
        handshake += b

    text = handshake.decode("utf-8", "replace")
    if not text.startswith("DYH2/2"):
        print(f"[phone] 握手魔数错误: {text[:40]!r}", file=sys.stderr)
        return 4
    print(f"[phone] 握手请求: {text.strip()}", flush=True)

    ack = ('DYA2/2\n'
           '{"status":"ok","app":"TestPhone","version":"1.0.0","width":1280,"height":720,"fps":30}\n')
    conn.sendall(ack.encode())

    stats = {
        "video": 0, "audio": 0, "key": 0, "bytes_v": 0, "bytes_a": 0,
        "max_frame": 0, "pings": 0, "meta": 0,
        "last_pts_v": -1, "last_pts_a": -1, "pts_backwards": 0,
    }
    started = time.time()

    vf = open(video_path, "wb")
    af = open(audio_path, "wb")
    try:
        while True:
            if args.duration and (time.time() - started) > args.duration:
                print("[phone] 到达时长限制，结束")
                break

            try:
                header = read_exact(conn, HEADER)
            except (ConnectionResetError, ConnectionAbortedError, OSError) as exc:
                print(f"[phone] 连接中断: {exc}")
                break
            if header is None:
                print("[phone] 对端关闭连接")
                break

            magic, ftype, flags, channel = struct.unpack_from("<IBBH", header, 0)
            pts, dts = struct.unpack_from("<qq", header, 8)
            (length,) = struct.unpack_from("<I", header, 24)

            if magic != MAGIC:
                print(f"[phone] 魔数错误 0x{magic:08X}", file=sys.stderr)
                return 5
            if length > 8 * 1024 * 1024:
                print(f"[phone] 帧过大 {length}", file=sys.stderr)
                return 6

            if length:
                try:
                    payload = read_exact(conn, length)
                except (ConnectionResetError, ConnectionAbortedError, OSError) as exc:
                    print(f"[phone] 载荷读取中断: {exc}")
                    break
            else:
                payload = b""
            if payload is None:
                print("[phone] 载荷读取中断")
                break

            stats["max_frame"] = max(stats["max_frame"], length)
            # 视频/音频各自单调（两者时间戳本来就会交错）
            if ftype == 0x10:
                if stats["last_pts_v"] >= 0 and pts < stats["last_pts_v"] - 500000:
                    stats["pts_backwards"] += 1
                stats["last_pts_v"] = max(stats["last_pts_v"], pts)
            elif ftype == 0x11:
                if stats["last_pts_a"] >= 0 and pts < stats["last_pts_a"] - 500000:
                    stats["pts_backwards"] += 1
                stats["last_pts_a"] = max(stats["last_pts_a"], pts)

            if ftype == 0x10:
                vf.write(payload)
                stats["video"] += 1
                stats["bytes_v"] += length
                if flags & 0x01:
                    stats["key"] += 1
            elif ftype == 0x11:
                af.write(payload)
                stats["audio"] += 1
                stats["bytes_a"] += length
            elif ftype == 0x02:
                stats["pings"] += 1
                pong = struct.pack("<IBBHqqI", MAGIC, 0x03, 0, 0, 0, 0, 0)
                conn.sendall(pong)
            elif ftype == 0x12:
                stats["meta"] += 1
            elif not args.quiet:
                print(f"[phone] {FRAME_NAMES.get(ftype, hex(ftype))} len={length} pts={pts/1000:.1f}ms")
    finally:
        vf.close()
        af.close()
        conn.close()
        srv.close()

    elapsed = max(time.time() - started, 0.001)
    print("\n==== 统计 ====")
    print(f"时长            : {elapsed:.1f}s")
    print(f"视频帧          : {stats['video']} (关键帧 {stats['key']})  {stats['bytes_v']/1024:.1f} KiB")
    print(f"音频帧          : {stats['audio']}  {stats['bytes_a']/1024:.1f} KiB")
    print(f"PING/PONG       : {stats['pings']}")
    print(f"最大帧          : {stats['max_frame']} B")
    print(f"时间戳倒退      : {stats['pts_backwards']}")
    print(f"视频码率        : {stats['bytes_v']*8/elapsed/1000:.0f} kbps")
    print(f"输出            : {video_path} / {audio_path}")

    ok = stats["video"] > 0 and stats["key"] > 0 and stats["pts_backwards"] == 0
    print("结果            :", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
