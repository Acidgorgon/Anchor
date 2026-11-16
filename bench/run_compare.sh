#!/usr/bin/env bash
# Anchor vs stock ProfileStore 1.0.3 comparison (bench/compare_bench.luau), run
# natively (--codegen -O2) and interpreted (-O2), plus the blob compression estimate.
#
#   bench/run_compare.sh                         # everything, native + interpreted
#   bench/run_compare.sh --native                # native only (or --interp)
#   COMPARE_ONLY=load,save bench/run_compare.sh  # sections: load,save,memory,size,calls,server
#   COMPARE_RUNS=7 COMPARE_SERVER_RUNS=7 ...     # runs per measurement (median reported)
#
# Output: bench/results/compare/compare-{native,interp}[-<sections>].{md,json} and
# bench/results/compare/zstd.md. bench/RESULTS.md is written by hand from these.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT/tests/host"
HOST="$HOST_DIR/build/luau-bench"
MODES=(native interp)
case "${1:-}" in
	--native) MODES=(native) ;;
	--interp) MODES=(interp) ;;
	-h|--help) sed -n '2,11p' "$0"; exit 0 ;;
esac

if [ ! -x "$HOST" ] || [ "$HOST_DIR/main.cpp" -nt "$HOST" ]; then
	gen=()
	command -v ninja >/dev/null 2>&1 && gen=(-G Ninja)
	cmake -S "$HOST_DIR" -B "$HOST_DIR/build" "${gen[@]}" -DCMAKE_BUILD_TYPE=Release >/dev/null &&
		cmake --build "$HOST_DIR/build" -j "$(nproc 2>/dev/null || echo 4)" >/dev/null || { echo "host build failed" >&2; exit 2; }
fi

export ANCHOR_BENCH_RESULTS="${ANCHOR_BENCH_RESULTS:-$ROOT/bench/results/compare}"
mkdir -p "$ANCHOR_BENCH_RESULTS/blobs"

rc=0
for mode in "${MODES[@]}"; do
	flags=(-O2)
	[ "$mode" = native ] && flags=(--codegen -O2)
	echo "== compare_bench ($mode)"
	"$HOST" "${flags[@]}" "$ROOT/tests/mock/runner.luau" "$ROOT" "$ROOT/bench/compare_bench.luau" || rc=1
done

# Roblox stores buffers in DataStores as base64 and may zstd-compress them
# ("zbase64"). That is Studio-only behaviour; this is an estimate with python's
# zstandard (level 3) or, without it, zlib.
python3 - "$ANCHOR_BENCH_RESULTS/blobs" "$ANCHOR_BENCH_RESULTS/zstd.md" <<'EOF'
import os, sys, base64, zlib
d, outp = sys.argv[1], sys.argv[2]
try:
    import zstandard
    comp, label = (lambda b: zstandard.ZstdCompressor(level=3).compress(b)), "zstd level 3"
except ImportError:
    comp, label = (lambda b: zlib.compress(b, 6)), "zlib level 6 (zstandard not installed; rough proxy)"
lines = [f"## Compression estimate ({label}); Roblox's real zbase64 choice/level is unknown", "",
         "| file | raw bytes | base64 | compressed | compressed+base64 |", "|---|---:|---:|---:|---:|"]
names = sorted(n for n in os.listdir(d) if n.endswith(".bin") or n.endswith(".json"))
for name in names:
    raw = open(os.path.join(d, name), "rb").read()
    c = comp(raw)
    lines.append(f"| {name} | {len(raw)} | {len(base64.b64encode(raw))} | {len(c)} | {len(base64.b64encode(c))} |")
open(outp, "w").write("\n".join(lines) + "\n")
print("\n" + "\n".join(lines))
EOF
exit $rc
