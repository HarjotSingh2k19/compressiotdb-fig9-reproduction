# Shared settings for the Fig. 9 toolkit. Every value can be overridden from the environment,
# e.g.  CIO_REPO=/some/path ./run_fig9.sh
FIG9_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CompressIoTDB checkout.
# Default: a CompressIoTDB clone next to this folder (../CompressIoTDB).
: "${CIO_REPO:=$(cd "$FIG9_DIR/.." && pwd)/CompressIoTDB}"

# Built CompressIoTDB distribution (directory that contains sbin/start-standalone.sh).
# Auto-detected below if left empty.
: "${CIO_HOME:=}"

# Stock Apache IoTDB 1.3.x distribution, used for the "IoTDB" baseline only.
: "${STOCK_HOME:=$HOME/apache-iotdb-1.3.3-all-bin}"

# Extended IoT-Benchmark shipped in the repo (supports EXP_VALUE).
: "${BENCH_HOME:=$CIO_REPO/benchmark/iot-benchmark-iotdb-1.3}"

# Where generated TsFiles and results go. About 10 GB for all 10 datasets.
: "${DATA_ROOT:=$FIG9_DIR/work/datasets}"
: "${RESULT_DIR:=$FIG9_DIR/results}"

RATES="${RATES:-0.1 0.3 0.5 0.7 0.9}"
SENSORS="${SENSORS:-5}"
LENGTH="${LENGTH:-100000000}"      # points per sensor (paper: 10^8)
LOOP="${LOOP:-20}"                 # operations per client and query type (authors: 100 mixed)
RUN_MAX="${RUN_MAX:-100}"          # generator repeat_len upper bound (see README)
SEED="${SEED:-42}"
MEMORY_SIZE="${MEMORY_SIZE:-}"     # e.g. 8G; empty = IoTDB default (1/2 of RAM)

# Locate sbin/start-standalone.sh below a directory (the assembly is sometimes nested twice).
find_home() {
  local base="$1" f
  [ -z "$base" ] && return 1
  # Prefer the full all-bin package: the datanode-bin package has no start-confignode.sh, so
  # start-standalone.sh fails there.
  f=$(find "$base" -maxdepth 5 -name start-standalone.sh -path '*all-bin*sbin*' 2>/dev/null | head -1)
  [ -z "$f" ] && f=$(find "$base" -maxdepth 5 -name start-standalone.sh -path '*sbin*' 2>/dev/null | head -1)
  [ -n "$f" ] && dirname "$(dirname "$f")"
}

if [ -z "$CIO_HOME" ]; then
  CIO_HOME="$(find_home "$CIO_REPO/iotdb/distribution/target")"
fi
STOCK_HOME_RESOLVED="$(find_home "$STOCK_HOME")"
[ -n "$STOCK_HOME_RESOLVED" ] && STOCK_HOME="$STOCK_HOME_RESOLVED"

rate_key() { awk -v r="$1" 'BEGIN{printf "%d", r*10+0.5}'; }   # 0.3 -> 3
