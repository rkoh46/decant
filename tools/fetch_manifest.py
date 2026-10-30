#!/usr/bin/env python3
"""Fetch one file (default BuildManifest.plist) out of a remote IPSW/zip with HTTP range requests, so a
12 GB firmware is never downloaded just to read its manifest. Standard library only.
Usage: fetch_manifest.py <ipsw-url> <out-path> [member-name]"""
import struct, sys, urllib.request, zlib

url, out = sys.argv[1], sys.argv[2]
member = sys.argv[3] if len(sys.argv) > 3 else "BuildManifest.plist"

def fetch(start, end):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}", "User-Agent": "Decant/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

with urllib.request.urlopen(urllib.request.Request(url, method="HEAD", headers={"User-Agent": "Decant/1.0"}), timeout=60) as r:
    size = int(r.headers["Content-Length"])

tail = fetch(max(0, size - 66000), size - 1)
eocd = tail.rfind(b"PK\x05\x06")
if eocd < 0: sys.exit("no end-of-central-directory record")
cd_count, cd_size, cd_off = struct.unpack("<HII", tail[eocd + 10:eocd + 20])
if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF or cd_count == 0xFFFF:     # zip64
    loc = tail.rfind(b"PK\x06\x07")
    z64_off = struct.unpack("<Q", tail[loc + 8:loc + 16])[0]
    z64 = fetch(z64_off, z64_off + 55)
    cd_count, cd_size, cd_off = struct.unpack("<QQQ", z64[32:56])[0], struct.unpack("<Q", z64[40:48])[0], struct.unpack("<Q", z64[48:56])[0]

cd = fetch(cd_off, cd_off + cd_size - 1)
pos = 0
while pos < len(cd):
    if cd[pos:pos + 4] != b"PK\x01\x02": break
    method, csize, usize, nlen, elen, clen = (struct.unpack("<H", cd[pos + 10:pos + 12])[0], *struct.unpack("<II", cd[pos + 20:pos + 28]),
                                              *struct.unpack("<HHH", cd[pos + 28:pos + 34]))
    lho = struct.unpack("<I", cd[pos + 42:pos + 46])[0]
    name = cd[pos + 46:pos + 46 + nlen].decode("utf-8", "replace")
    extra = cd[pos + 46 + nlen:pos + 46 + nlen + elen]
    if 0xFFFFFFFF in (csize, usize, lho):                                    # zip64 extra field
        e = 0
        while e + 4 <= len(extra):
            hid, hlen = struct.unpack("<HH", extra[e:e + 4]); body = extra[e + 4:e + 4 + hlen]; e += 4 + hlen
            if hid == 1:
                vals = list(struct.unpack("<" + "Q" * (len(body) // 8), body[:len(body) // 8 * 8]))
                if usize == 0xFFFFFFFF: usize = vals.pop(0)
                if csize == 0xFFFFFFFF: csize = vals.pop(0)
                if lho == 0xFFFFFFFF: lho = vals.pop(0)
    if name == member:
        lh = fetch(lho, lho + 29)
        n2, e2 = struct.unpack("<HH", lh[26:30])
        start = lho + 30 + n2 + e2
        data = fetch(start, start + csize - 1)
        if method == 8: data = zlib.decompress(data, -15)
        elif method != 0: sys.exit(f"unsupported compression {method}")
        open(out, "wb").write(data)
        print(f"{member}: {len(data)} bytes from a {size / 1e9:.2f} GB archive")
        sys.exit(0)
    pos += 46 + nlen + elen + clen
sys.exit(f"{member} not found")
