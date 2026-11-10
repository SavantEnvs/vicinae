#!/usr/bin/env bash
#
# mayhem/build.sh — build the fuzz harness over src/lib/xdgpp (.desktop entry parser) and its Catch2 test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# vicinae is a large Qt desktop app, but its .desktop entry parser (src/lib/xdgpp) is plain C++23
# with no Qt dependency, so the harness and its tests build from the library's own sources
# (the mime and bookmark parts, which need pugixml, are not part of the fuzzed entry path).
XDG="$SRC/src/lib/xdgpp"
CXXSTD=-std=c++23
LIB_SRCS=(
  "$XDG/xdgpp/locale/locale.cpp"
  "$XDG/xdgpp/desktop-entry/reader.cpp"
  "$XDG/xdgpp/desktop-entry/group.cpp"
  "$XDG/xdgpp/desktop-entry/value.cpp"
  "$XDG/xdgpp/desktop-entry/entry.cpp"
  "$XDG/xdgpp/desktop-entry/file.cpp"
  "$XDG/xdgpp/desktop-entry/action.cpp"
  "$XDG/xdgpp/desktop-entry/exec.cpp"
  "$XDG/xdgpp/env/env.cpp"
)

# 1) Fuzz harness + standalone reproducer, with the library compiled sanitized and carrying SanCov
#    counters (-fsanitize=fuzzer-no-link) so the fuzzed parser contributes edges.
COV=-fsanitize=fuzzer-no-link
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT
OBJS=()
for src in "${LIB_SRCS[@]}"; do
  o="$OBJ/$(basename "$(dirname "$src")")_$(basename "$src" .cpp).o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $COV $CXXSTD -DXDGPP_GROUP='"xdgpp"' -I"$XDG" -c "$src" -o "$o"
  OBJS+=("$o")
done
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $COV $CXXSTD -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $COV $CXXSTD -I"$XDG" -c "$SRC/mayhem/fuzz_desktop_entry.cc" -o "$OBJ/fuzz_desktop_entry.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/fuzz_desktop_entry.o" "${OBJS[@]}" "$OBJ/lsan_off.o" -o /mayhem/fuzz_desktop_entry
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $COV "$OBJ/fuzz_desktop_entry.o" "${OBJS[@]}" "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" -o /mayhem/fuzz_desktop_entry-standalone

# 2) Upstream's Catch2 suite (entry, reader, locale, env, file, special), with NORMAL flags
#    (separate, unsanitized build in a gitignored dir).
TESTDIR="$SRC/build-tests"
mkdir -p "$TESTDIR"
TEST_SRCS=(main entry env locale file special)
for t in "${TEST_SRCS[@]}"; do
  $CXX -O1 $CXXSTD $COVERAGE_FLAGS -DXDGPP_GROUP='"xdgpp"' -DXDGPP_FIXTURE_DIR="\"$XDG/fixtures\"" \
       -I"$XDG" -I"$XDG/xdgpp" -c "$XDG/tests/$t.cpp" -o "$TESTDIR/test_$t.o"
done
for src in "${LIB_SRCS[@]}"; do
  $CXX -O1 $CXXSTD $COVERAGE_FLAGS -DXDGPP_GROUP='"xdgpp"' -I"$XDG" -c "$src" \
       -o "$TESTDIR/lib_$(basename "$(dirname "$src")")_$(basename "$src" .cpp).o"
done
$CXX $COVERAGE_FLAGS "$TESTDIR"/*.o -lCatch2Main -lCatch2 -o "$TESTDIR/xdgpp-tests"
