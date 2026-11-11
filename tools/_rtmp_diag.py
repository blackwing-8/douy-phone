#!/usr/bin/env python3
"""RTMP 诊断：手工做握手 + connect，把服务端返回的原始字节和 AMF0 打出来。"""
import socket
import struct
import sys
import binascii

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19350
APP = "live"


def amf_string(s):
    b = s.encode()
    return b"\x02" + struct.pack(">H", len(b)) + b


def amf_number(n):
    return b"\x00" + struct.pack(">d", float(n))


def amf_null():
    return b"\x05"


def amf_object(d):
    out = b"\x03"
    for k, v in d.items():
        kb = k.encode()
        out += struct.pack(">H", len(kb)) + kb
        if isinstance(v, str):
            out += amf_string(v)
        elif isinstance(v, (int, float)):
            out += amf_number(v)
        else:
            out += amf_null()
    out += b"\x00\x00\x09"
    return out


def chunk(csid, mtype, ts, msid, payload, chunk_size=128):
    # fmt 0
    out = struct.pack(">B", csid)  # fmt=0, csid<64
    out += struct.pack(">I", ts & 0xFFFFFF)[1:]  # 3 bytes
    out += struct.pack(">I", len(payload))[1:]
    out += struct.pack(">B", mtype)
    out += struct.pack("<I", msid)
    if len(payload) <= chunk_size:
        return out + payload
    out += payload[:chunk_size]
    rest = payload[chunk_size:]
    while rest:
        out += struct.pack(">B", 0xC0 | csid)  # fmt=3
        out += rest[:chunk_size]
        rest = rest[chunk_size:]
    return out


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise EOFError("closed")
        buf += c
    return buf


def parse_amf0(data):
    out = []
    i = 0
    while i < len(data):
        t = data[i]
        i += 1
        if t == 0x00:
            out.append(("number", struct.unpack(">d", data[i:i + 8])[0]))
            i += 8
        elif t == 0x01:
            out.append(("bool", data[i]))
            i += 1
        elif t == 0x02:
            n = struct.unpack(">H", data[i:i + 2])[0]
            i += 2
            out.append(("string", data[i:i + n].decode("utf-8", "replace")))
            i += n
        elif t == 0x03:
            props = {}
            while i + 2 < len(data):
                n = struct.unpack(">H", data[i:i + 2])[0]
                i += 2
                if n == 0 and data[i] == 0x09:
                    i += 1
                    break
                key = data[i:i + n].decode("utf-8", "replace")
                i += n
                vt = data[i]
                if vt == 0x02:
                    m = struct.unpack(">H", data[i + 1:i + 3])[0]
                    props[key] = data[i + 3:i + 3 + m].decode("utf-8", "replace")
                    i += 3 + m
                elif vt == 0x00:
                    props[key] = struct.unpack(">d", data[i + 1:i + 9])[0]
                    i += 9
                elif vt == 0x05:
                    props[key] = None
                    i += 1
                elif vt == 0x01:
                    props[key] = data[i + 1]
                    i += 2
                else:
                    props[key] = f"<type {vt:#x}>"
                    i += 1
                    break
            out.append(("object", props))
        elif t == 0x05:
            out.append(("null", None))
        elif t == 0x08:
            i += 4
            out.append(("ecma", "..."))
        elif t in (0x09,):
            break
        else:
            out.append((f"unknown 0x{t:02x}", data[i:i + 8].hex()))
            break
    return out


sock = socket.create_connection((HOST, PORT), timeout=5)

# --- 握手 ---
c1 = b"\x00\x00\x00\x00" + b"\x00\x00\x00\x00" + bytes(range(256)) * 6 + b"\x00" * (1528 - 1536 % 1528)
c1 = (b"\x00\x00\x00\x00" + b"\x00\x00\x00\x00" + b"\x1c" * 1528)
sock.sendall(b"\x03" + c1)
s0 = read_exact(sock, 1)
s1 = read_exact(sock, 1536)
s2 = read_exact(sock, 1536)
print(f"S0={s0.hex()}  S1[0:8]={s1[:8].hex()}  S2[0:8]={s2[:8].hex()}")
sock.sendall(s1)

# --- connect ---
MINIMAL = "--minimal" in sys.argv
if MINIMAL:
    payload = (amf_string("connect") + amf_number(1) + amf_object({"app": APP}))
else:
    payload = (amf_string("connect") + amf_number(1) +
               amf_object({"app": APP, "type": "nonprivate",
                           "flashVer": "FMLE/3.0 (compatible; FMSc/1.0)",
                           "tcUrl": f"rtmp://127.0.0.1:{PORT}/{APP}"}))
print(f"connect payload = {len(payload)} 字节")
sock.sendall(chunk(3, 20, 0, 0, payload))

# --- 读响应 ---
sock.settimeout(3)
data = b""
try:
    while True:
        c = sock.recv(65536)
        if not c:
            break
        data += c
        if len(data) > 8192:
            break
except socket.timeout:
    pass

print(f"\n收到 {len(data)} 字节")
print("HEX:", binascii.hexlify(data).decode())
print("\nAMF0 解析：")
for item in parse_amf0(data):
    print("  ", item)
sock.close()
