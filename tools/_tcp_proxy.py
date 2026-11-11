#!/usr/bin/env python3
"""TCP 双向代理 + 十六进制抓包，用于观察 ffmpeg 与 RTMP 服务端的握手/exchange。"""
import socket
import threading
import sys
import binascii

LISTEN = int(sys.argv[1]) if len(sys.argv) > 1 else 19360
TARGET_HOST = "127.0.0.1"
TARGET_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 19350
LOG_C2S = open("proxy_c2s.bin", "wb")
LOG_S2C = open("proxy_s2c.bin", "wb")


def pump(src, dst, log, tag):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            log.write(data)
            log.flush()
            if len(data) < 200:
                print(f"{tag} {len(data):5d} {binascii.hexlify(data).decode()}")
            else:
                print(f"{tag} {len(data):5d} {binascii.hexlify(data[:64]).decode()}…")
            dst.sendall(data)
    except Exception as e:
        print(f"{tag} 结束: {e}")
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except Exception:
            pass


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", LISTEN))
srv.listen(1)
print(f"代理监听 {LISTEN} → {TARGET_HOST}:{TARGET_PORT}")
while True:
    client, addr = srv.accept()
    print(f"连接来自 {addr}")
    upstream = socket.create_connection((TARGET_HOST, TARGET_PORT))
    t1 = threading.Thread(target=pump, args=(client, upstream, LOG_C2S, "C→S"), daemon=True)
    t2 = threading.Thread(target=pump, args=(upstream, client, LOG_S2C, "S→C"), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    print("会话结束")
