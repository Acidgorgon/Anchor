#!/usr/bin/env python3
"""zstd size estimate for codec_bench outputs.

    luau-bench bench/codec_bench.luau OUTDIR      # writes OUTDIR/{small,fm}.{bin,json}
    python3 bench/codec_zstd.py OUTDIR

Roblox stores a buffer in a DataStore as JSON {"m":null,"t":"buffer","zbase64":...}
(zstd + base64, done in Studio/engine; the exact level and framing are
Studio-only facts we cannot measure here). This script reports, per dataset:
raw blob, base64(blob), zstd(blob), base64(zstd(blob)), JSON, zstd(JSON),
for zstd levels 3 and 19. Needs `pip install zstandard`.
"""
import base64
import os
import sys

try:
    import zstandard
except ImportError:
    sys.exit("zstandard module not available (pip install zstandard)")


def b64len(n: int) -> int:
    return 4 * ((n + 2) // 3)


def main() -> None:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    hdr = f"{'data':6} {'blob':>7} {'b64':>7} {'json':>7} | " + " | ".join(
        f"L{lvl}: {'z(blob)':>7} {'b64z':>7} {'z(json)':>7}" for lvl in (3, 19)
    )
    print(hdr)
    for name in ("small", "fm"):
        bin_path = os.path.join(outdir, name + ".bin")
        json_path = os.path.join(outdir, name + ".json")
        if not os.path.exists(bin_path):
            continue
        blob = open(bin_path, "rb").read()
        js = open(json_path, "rb").read()
        cols = []
        for lvl in (3, 19):
            c = zstandard.ZstdCompressor(level=lvl)
            zb = c.compress(blob)
            zj = c.compress(js)
            assert zstandard.ZstdDecompressor().decompress(zb) == blob
            cols.append(f"L{lvl}: {len(zb):7d} {b64len(len(zb)):7d} {len(zj):7d}")
        print(f"{name:6} {len(blob):7d} {len(base64.b64encode(blob)):7d} {len(js):7d} | " + " | ".join(cols))


if __name__ == "__main__":
    main()
