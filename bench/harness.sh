#!/usr/bin/env bash
# Runs Anchor benches on the luau-bench host (Luau 0.700, native codegen, -O2)
# with the Roblox mock. Bench files use bench/harness.luau (see its header).
#
#   bench/harness.sh                       # every bench/*_bench.luau
#   bench/harness.sh bench/codec_bench.luau
#   bench/harness.sh --interp ...          # without native codegen
#
# Results: printed tables + $ANCHOR_BENCH_RESULTS (default bench/results)/<title>.json.
# Blobs written with Bench.dumpBlob land in <results>/blobs/ and get a zstd (or, without the
# python zstandard module, zlib) size estimate at the end: Roblox compresses
# buffers stored in DataStores (zbase64) - a Studio-only fact we can only
# estimate here.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT/tests/host"
HOST="$HOST_DIR/build/luau-bench"
FLAGS=(--codegen -O2)
FILES=()
while [ $# -gt 0 ]; do
	case "$1" in
		--interp) FLAGS=(-O2) ;;
		-h|--help) sed -n '2,13p' "$0"; exit 0 ;;
		*) FILES+=("$1") ;;
	esac
	shift
done

if [ ! -x "$HOST" ] || [ "$HOST_DIR/main.cpp" -nt "$HOST" ]; then
	gen=()
	command -v ninja >/dev/null 2>&1 && gen=(-G Ninja)
	cmake -S "$HOST_DIR" -B "$HOST_DIR/build" "${gen[@]}" -DCMAKE_BUILD_TYPE=Release >/dev/null &&
		cmake --build "$HOST_DIR/build" -j "$(nproc 2>/dev/null || echo 4)" >/dev/null || { echo "host build failed" >&2; exit 2; }
fi

if [ ${#FILES[@]} -eq 0 ]; then
	while IFS= read -r f; do FILES+=("$f"); done < <(find "$ROOT/bench" -maxdepth 1 -name '*_bench.luau' | sort)
fi
if [ ${#FILES[@]} -eq 0 ]; then
	echo "no bench/*_bench.luau files"
	exit 0
fi

export ANCHOR_BENCH_RESULTS="${ANCHOR_BENCH_RESULTS:-$ROOT/bench/results}"
RESULTS="$ANCHOR_BENCH_RESULTS"
mkdir -p "$RESULTS/blobs"
rc=0
for f in "${FILES[@]}"; do
	abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
	echo "== ${abs#"$ROOT"/}"
	"$HOST" "${FLAGS[@]}" "$ROOT/tests/mock/runner.luau" "$ROOT" "$abs" || rc=1
done

if ls "$RESULTS/blobs/"*.bin >/dev/null 2>&1; then
	python3 - "$RESULTS/blobs" <<'EOF'
import os, sys, base64, zlib
d = sys.argv[1]
try:
    import zstandard
    comp, label = (lambda b: zstandard.ZstdCompressor(level=3).compress(b)), "zstd-3"
except ImportError:
    comp, label = (lambda b: zlib.compress(b, 6)), "zlib-6 (zstandard not installed; rough proxy)"
print(f"\n## Blob compression estimate ({label})")
print(f"{'blob':40} {'raw':>10} {'base64':>10} {'compressed':>10} {'zbase64':>10}")
for name in sorted(os.listdir(d)):
    if not name.endswith(".bin"):
        continue
    raw = open(os.path.join(d, name), "rb").read()
    c = comp(raw)
    print(f"{name[:-4]:40} {len(raw):>10} {len(base64.b64encode(raw)):>10} {len(c):>10} {len(base64.b64encode(c)):>10}")
EOF
fi
exit $rc
