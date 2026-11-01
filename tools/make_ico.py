"""Pack PNGs into a Windows .ico (PNG-compressed entries, as Windows Vista and later read them).
Usage: python3 tools/make_ico.py out.ico icon-16.png icon-32.png ..."""
import struct, sys
out, pngs = sys.argv[1], sys.argv[2:]
entries, blobs, offset = [], [], 6 + 16 * len(pngs)
for p in pngs:
    data = open(p, "rb").read()
    w, h = struct.unpack(">II", data[16:24])
    entries.append(struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(data), offset))
    blobs.append(data); offset += len(data)
with open(out, "wb") as f:
    f.write(struct.pack("<HHH", 0, 1, len(pngs))); f.write(b"".join(entries)); f.write(b"".join(blobs))
print(out, len(pngs), "sizes")
