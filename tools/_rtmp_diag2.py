#!/usr/bin/env python3
"""完整模拟 ffmpeg 的推流命令序列，并打印服务端每条返回消息（用于定位 publish 之后断开的原因）。"""
import socket
import struct
import sys
import time

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19350
APP = "live"
STREAM = "reecho"


def amf_str(s):
    b = s.encode()
    return b"\x02" + struct.pack(">H", len(b)) + b


def amf_num(n):
    return b"\x00" + struct.pack(">d", float(n))


def amf_null():
    return b"\x05"


def amf_bool(v):
    return b"\x01" + (b"\x01" if v else b"\x00")


def amf_obj(d):
    out = b"\x03"
    for k, v in d.items():
        kb = k.encode()
        out += struct.pack(">H", len(kb)) + kb
        if isinstance(v, str):
            out += amf_str(v)
        elif isinstance(v, bool):
            out += amf_bool(v)
        elif isinstance(v, (int, float)):
            out += amf_num(v)
        else:
            out += amf_null()
    out += b"\x00\x00\x09"
    return out


def send_cmd(sock, csid, msid, payload, chunk_size):
    out = struct.pack(">B", csid)
    out += b"\x00\x00\x00"          # timestamp
    out += struct.pack(">I", len(payload))[1:]
    out += struct.pack(">B", 20)     # msg type: command
    out += struct.pack("<I", msid)
    out += payload[:chunk_size]
    rest = payload[chunk_size:]
    while rest:
        out += struct.pack(">B", 0xC0 | csid)
        out += rest[:chunk_size]
        rest = rest[chunk_size:]
    sock.sendall(out)


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            return None
        buf += c
    return buf


def main():
    sock = socket.create_connection((HOST, PORT), timeout=5)
    c1 = b"\x00\x00\x00\x00" + b"\x00\x00\x00\x00" + bytes([0x5A]) * 1528
    sock.sendall(b"\x03" + c1)
    if read_exact(sock, 1) != b"\x03":
        print("S0 错误")
        return 1
    s1 = read_exact(sock, 1536)
    s2 = read_exact(sock, 1536)
    sock.sendall(s1)
    print("握手完成")

    chunk_size = 128
    # connect
    send_cmd(sock, 3, 0, amf_str("connect") + amf_num(1) + amf_obj({
        "app": APP, "type": "nonprivate", "flashVer": "FMLE/3.0 (compatible; FMSc/1.0)",
        "tcUrl": f"rtmp://127.0.0.1:{PORT}/{APP}",
        "fpad": False, "capabilities": 15, "audioCodecs": 4071,
        "videoCodecs": 252, "videoFunction": 1, "objectEncoding": 0,
    }), chunk_size)
    time.sleep(0.2)
    # releaseStream / FCPublish / createStream
    for name, txn in (("releaseStream", 2), ("FCPublish", 3), ("createStream", 4)):
        send_cmd(sock, 3, 0, amf_str(name) + amf_num(txn) + amf_null() + amf_str(STREAM), chunk_size)
    time.sleep(0.2)
    # publish
    send_cmd(sock, 4, 1, amf_str("publish") + amf_num(5) + amf_null() + amf_str(STREAM) + amf_str("live"), chunk_size)
    print("已发送 publish，开始读取服务端消息…")

    # 读并解析 chunk
    states = {}
    deadline = time.time() + 4
    sock.settimeout(1.0)
    try:
        while time.time() < deadline:
            bh = read_exact(sock, 1)
            if bh is None:
                print("!! 服务端关闭了连接")
                break
            fmt = (bh[0] >> 6) & 3
            csid = bh[0] & 0x3F
            if csid == 0:
                csid = 64 + read_exact(sock, 1)[0]
            elif csid == 1:
                csid = 64 + struct.unpack("<H", read_exact(sock, 2))[0]

            st = states.setdefault(csid, {"len": 0, "type": 0, "ts": 0, "msid": 0, "buf": b""})
            if fmt == 0:
                h = read_exact(sock, 11)
                ts = int.from_bytes(h[0:3], "big")
                st["len"] = int.from_bytes(h[3:6], "big")
                st["type"] = h[6]
                st["msid"] = struct.unpack("<I", h[7:11])[0]
                st["ts"] = ts
                st["buf"] = b""
            elif fmt == 1:
                h = read_exact(sock, 7)
                st["len"] = int.from_bytes(h[3:6], "big")
                st["type"] = h[6]
                st["buf"] = b""
            elif fmt == 2:
                read_exact(sock, 3)
                st["buf"] = b""
            need = min(chunk_size, st["len"] - len(st["buf"]))
            payload = read_exact(sock, need)
            if payload is None:
                print("!! 读 payload 时断开")
                break
            st["buf"] += payload
            if len(st["buf"]) >= st["len"]:
                body = st["buf"]
                st["buf"] = b""
                name = ""
                if st["type"] == 20 and len(body) > 3 and body[0] == 0x02:
                    n = struct.unpack(">H", body[1:3])[0]
                    name = body[3:3 + n].decode("utf-8", "replace")
                print(f"  <- csid={csid} type={st['type']} len={len(body)} msid={st['msid']} ts={st['ts']} cmd={name!r} "
                      f"hdr={body[:48].hex()}")
                if st["type"] == 1 and len(body) == 4:
                    chunk_size = struct.unpack(">I", body)[0]
                    print(f"     (chunk size -> {chunk_size})")
    except socket.timeout:
        print("读取超时（服务端没再发东西）")
    except ConnectionResetError:
        print("!! 连接被重置")
    sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
