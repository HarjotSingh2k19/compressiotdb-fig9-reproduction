#!/bin/bash
# Runs the Fig. 9 experiment: 4 systems x 5 repetition rates x 3 query types.
#
#   iotdb         stock Apache IoTDB   (STOCK_HOME)  on RLE+LZ4 data   (DB cr<k>)
#   uncompressed  CompressIoTDB build  (CIO_HOME)    on PLAIN data      (DB pl<k>)
#   nolate        CompressIoTDB build  (CIO_HOME)    on RLE+LZ4 data, -Dcompressiotdb.nolate=true
#   cio           CompressIoTDB build  (CIO_HOME)    on RLE+LZ4 data
#
# Usage:  ./run_fig9.sh                       all systems, all rates
#         SYSTEMS="cio iotdb" RATES="0.5" ./run_fig9.sh
# Datasets must exist (./gen_datasets.sh). Results go to results/<system>/<db>_<QT>.log.
set -uo pipefail
. "$(dirname "$0")/config.sh"
SYSTEMS="${SYSTEMS:-iotdb uncompressed nolate cio}"
QTS="${QTS:-QT1 QT2 QT3}"
MARK="# >>> fig9 nolate"

python3 "$FIG9_DIR/bench/make_configs.py" "$FIG9_DIR/configs" "$LOOP" >/dev/null
[ -f "$BENCH_HOME/benchmark.sh" ] || { echo "IoT-Benchmark not found: $BENCH_HOME"; exit 1; }

port_open() { (exec 3<>/dev/tcp/127.0.0.1/6667) 2>/dev/null; }
cli() { "$1/sbin/start-cli.sh" -h 127.0.0.1 -p 6667 -u root -pw root -e "$2" 2>&1; }

iotdb_procs() { ps ax -o command= | grep -c '[o]rg.apache.iotdb' ; }
stop_server() {
  local home="$1"
  "$home/sbin/stop-standalone.sh" >/dev/null 2>&1 || true
  # Ports close before the JVMs exit; starting again too early makes the next start fail.
  for _ in $(seq 1 90); do
    if ! port_open && [ "$(iotdb_procs)" = 0 ]; then sleep 2; return 0; fi
    sleep 2
  done
  echo "IoTDB processes still running after stop: $(iotdb_procs)"; return 1
}
start_server() {
  local home="$1" nolate="$2" env="$1/conf/datanode-env.sh"
  # remove an earlier switch block, then add it back if requested
  if grep -q "$MARK" "$env"; then sed -i.fig9bak "/$MARK/,/# <<< fig9 nolate/d" "$env"; fi
  if [ "$nolate" = 1 ]; then
    printf '\n%s\nIOTDB_JMX_OPTS="$IOTDB_JMX_OPTS -Dcompressiotdb.nolate=true"\n# <<< fig9 nolate\n' "$MARK" >> "$env"
  fi
  if [ -n "$MEMORY_SIZE" ]; then sed -i.fig9bak "s/^MEMORY_SIZE=.*/MEMORY_SIZE=$MEMORY_SIZE/" "$env"; fi
  mkdir -p "$RESULT_DIR/server_logs"
  (cd "$home" && nohup ./sbin/start-standalone.sh > "$RESULT_DIR/server_logs/start_$(basename "$home").log" 2>&1 &)
  for _ in $(seq 1 150); do
    if port_open && cli "$home" "show databases" | grep -qi "database\|Total line"; then return 0; fi
    sleep 2
  done
  echo "server did not become ready (see $home/logs/log_datanode_all.log)"; return 1
}

# Row count of the last sensor; the load is only trusted when it equals $LENGTH.
db_rows() { # home db
  cli "$1" "select count(s_$((SENSORS-1))) from root.$2.g_0.d_0" | grep -E '^\|[ 0-9]' | tr -d '| ' | head -1
}
# Each data region reserves direct-buffer memory; with all 10 databases loaded the DataNode
# refuses to create more regions ("Total allocated memory for direct buffer ... greater than
# limit"). Drop the server-side copies of the other kind first; the source TsFiles under
# $DATA_ROOT are not touched and are reloaded when needed.
unload_other() { # home kind
  local home="$1" other k
  [ "$2" = cr ] && other=pl || other=cr
  for k in 1 3 5 7 9; do
    if cli "$home" "show databases root.$other$k" | grep -q "root.$other$k"; then
      echo "  dropping server copy of root.$other$k (frees region memory)"
      cli "$home" "delete database root.$other$k" >/dev/null
    fi
  done
}
load_kind() { # home kind(cr|pl)
  local home="$1" kind="$2" r k n try
  mkdir -p "$RESULT_DIR/load_logs"
  for r in $RATES; do
    k=$(rate_key "$r")
    n=$(db_rows "$home" "$kind$k")
    if [ "$n" = "$LENGTH" ]; then echo "  root.$kind$k verified ($n rows)"; continue; fi
    for try in 1 2 3; do
      echo "  loading $kind$k from $DATA_ROOT/$kind$k (try $try, found '${n:-none}' rows)"
      (cd "$home" && ./tools/load-tsfile.sh -s "$DATA_ROOT/$kind$k" -os none -of none) \
        > "$RESULT_DIR/load_logs/${kind}${k}.log" 2>&1
      sleep 3
      n=$(db_rows "$home" "$kind$k")
      [ "$n" = "$LENGTH" ] && break
    done
    if [ "$n" != "$LENGTH" ]; then
      echo "  ERROR: root.$kind$k has '${n:-none}' rows, expected $LENGTH (see $RESULT_DIR/load_logs/${kind}${k}.log)"
      return 1
    fi
    echo "  root.$kind$k verified ($n rows)"
  done
}
run_system() {
  local sys="$1" home kind nolate=0
  case "$sys" in
    iotdb)        home="$STOCK_HOME"; kind=cr ;;
    uncompressed) home="$CIO_HOME";   kind=pl ;;
    nolate)       home="$CIO_HOME";   kind=cr; nolate=1 ;;
    cio)          home="$CIO_HOME";   kind=cr ;;
    *) echo "unknown system $sys"; return 1 ;;
  esac
  [ -x "$home/sbin/start-standalone.sh" ] || { echo "[$sys] no IoTDB distribution at '$home', skipping"; return 1; }
  if [ "$nolate" = 1 ]; then
    j=$(ls "$home"/lib/tsfile-*.jar 2>/dev/null | head -1)
    if ! unzip -p "$j" org/apache/tsfile/read/reader/page/ValuePageReader.class 2>/dev/null | grep -aq compressiotdb.nolate; then
      echo "[nolate] distribution was built without patches/nolate.patch, skipping"; return 1
    fi
  fi
  echo "=== [$sys] $(date '+%F %T') ==="
  stop_server "$home" || return 1
  start_server "$home" "$nolate" || return 1
  unload_other "$home" "$kind"
  load_kind "$home" "$kind" || { stop_server "$home"; return 1; }
  mkdir -p "$RESULT_DIR/$sys"
  for r in $RATES; do
    k=$(rate_key "$r")
    for qt in $QTS; do
      log="$RESULT_DIR/$sys/$kind${k}_$qt.log"
      echo "  [$sys] rate=$r $qt -> $log"
      (cd "$BENCH_HOME" && sh benchmark.sh -cf "$FIG9_DIR/configs/$kind${k}_$qt.properties") > "$log" 2>&1
      grep -E "^(AGG_RANGE|AGG_VALUE|EXP_VALUE) " "$log" | head -3 | sed 's/^/      /'
    done
  done
  stop_server "$home"
}

for s in $SYSTEMS; do run_system "$s" || echo "[$s] FAILED or skipped"; done
python3 "$FIG9_DIR/analyze.py" --results "$RESULT_DIR" --statics "$CIO_REPO/benchmark/iot-benchmark-iotdb-1.3/res_on_datasets_with_varying_repetition_rates/statics.csv" --out "$FIG9_DIR/fig9_output"
