#!/usr/bin/env bash
# Runs Anchor's Luau tests on the luau-bench host (Luau 0.700) with the Roblox mock.
#
#   tests/run.sh                      # every tests/**/*_test.luau
#   tests/run.sh tests/stock          # only files under a directory
#   tests/run.sh tests/stock/lock_test.luau
#   tests/run.sh -t "autosave"        # only tests whose name contains the text
#   tests/run.sh -v                   # echo every simulated print/warn
#   tests/run.sh --codegen            # run with native code generation
#
# Each test file runs in a fresh VM. Exit status is non-zero if any test fails.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT/tests/host"
HOST="$HOST_DIR/build/luau-bench"

FLAGS=()
TARGETS=()
while [ $# -gt 0 ]; do
	case "$1" in
		-v|--verbose) export ANCHOR_TEST_VERBOSE=1 ;;
		-t|--filter) shift; export ANCHOR_TEST_FILTER="$1" ;;
		--codegen) FLAGS+=("--codegen") ;;
		-O0|-O1|-O2) FLAGS+=("$1") ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) TARGETS+=("$1") ;;
	esac
	shift
done

build_host() {
	local gen=()
	command -v ninja >/dev/null 2>&1 && gen=(-G Ninja)
	cmake -S "$HOST_DIR" -B "$HOST_DIR/build" "${gen[@]}" -DCMAKE_BUILD_TYPE=Release >/dev/null &&
		cmake --build "$HOST_DIR/build" -j "$(nproc 2>/dev/null || echo 4)" >/dev/null
}

if [ ! -x "$HOST" ] || [ "$HOST_DIR/main.cpp" -nt "$HOST" ] || [ "$HOST_DIR/CMakeLists.txt" -nt "$HOST" ]; then
	echo "building luau-bench host..."
	if ! build_host; then
		echo "host build failed" >&2
		exit 2
	fi
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
	TARGETS=("$ROOT/tests")
fi

FILES=()
for t in "${TARGETS[@]}"; do
	if [ -d "$t" ]; then
		while IFS= read -r f; do FILES+=("$f"); done < <(find "$t" -name '*_test.luau' -not -path '*/host/*' | sort)
	elif [ -f "$t" ]; then
		FILES+=("$t")
	else
		echo "no such test file or directory: $t" >&2
		exit 2
	fi
done

if [ ${#FILES[@]} -eq 0 ]; then
	echo "no *_test.luau files found"
	exit 0
fi

total_pass=0
total_fail=0
failed_files=()
for f in "${FILES[@]}"; do
	abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
	rel="${abs#"$ROOT"/}"
	echo "== $rel"
	out="$("$HOST" ${FLAGS[@]+"${FLAGS[@]}"} "$ROOT/tests/mock/runner.luau" "$ROOT" "$abs" 2>&1)"
	rc=$?
	printf '%s\n' "$out" | grep -v '^RESULT '
	result="$(printf '%s\n' "$out" | grep '^RESULT ' | tail -1)"
	p="$(printf '%s' "$result" | sed -n 's/.*pass=\([0-9]*\).*/\1/p')"
	n="$(printf '%s' "$result" | sed -n 's/.*fail=\([0-9]*\).*/\1/p')"
	total_pass=$((total_pass + ${p:-0}))
	total_fail=$((total_fail + ${n:-0}))
	if [ $rc -ne 0 ]; then
		failed_files+=("$rel")
		if [ -z "$result" ]; then
			total_fail=$((total_fail + 1))
			echo "  FAIL  (file crashed before reporting results)"
		fi
	fi
done

echo
echo "Total: $total_pass passed, $total_fail failed, ${#FILES[@]} file(s)"
if [ ${#failed_files[@]} -gt 0 ]; then
	printf 'Failed: %s\n' "${failed_files[@]}"
	exit 1
fi
exit 0
