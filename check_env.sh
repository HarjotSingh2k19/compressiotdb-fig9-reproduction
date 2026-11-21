#!/bin/bash
# Verifies that every path and tool the toolkit needs exists on this machine.
. "$(dirname "$0")/config.sh"
ok=0; bad=0
chk() { # description, test-result
  if [ "$2" = "1" ]; then echo "  [ok]      $1"; ok=$((ok+1)); else echo "  [MISSING] $1"; bad=$((bad+1)); fi
}
t() { [ -e "$1" ] && echo 1 || echo 0; }
echo "Paths (override with environment variables, see config.sh):"
chk "CompressIoTDB repo           CIO_REPO   = $CIO_REPO" "$(t "$CIO_REPO/iotdb")"
chk "CompressIoTDB distribution   CIO_HOME   = ${CIO_HOME:-<not found>}" "$([ -n "$CIO_HOME" ] && t "$CIO_HOME/sbin/start-standalone.sh" || echo 0)"
chk "tsfile jar in CIO_HOME/lib" "$([ -n "$CIO_HOME" ] && ls "$CIO_HOME"/lib/tsfile-*.jar >/dev/null 2>&1 && echo 1 || echo 0)"
chk "IoT-Benchmark                BENCH_HOME = $BENCH_HOME" "$(t "$BENCH_HOME/benchmark.sh")"
chk "Stock Apache IoTDB (baseline) STOCK_HOME = $STOCK_HOME" "$(t "$STOCK_HOME/sbin/start-standalone.sh")"
echo "Tools:"
for c in java javac python3; do chk "$c on PATH ($(command -v $c || echo none))" "$(command -v $c >/dev/null && echo 1 || echo 0)"; done
if command -v java >/dev/null; then echo "  java version: $(java -version 2>&1 | head -1)"; fi
echo "Patch state:"
if [ -n "$CIO_HOME" ] && ls "$CIO_HOME"/lib/tsfile-*.jar >/dev/null 2>&1; then
  j=$(ls "$CIO_HOME"/lib/tsfile-*.jar | head -1)
  if unzip -p "$j" org/apache/tsfile/read/reader/page/ValuePageReader.class 2>/dev/null | grep -aq "compressiotdb.nolate"; then
    echo "  [ok]      distribution contains the NoLate switch (compressiotdb.nolate)"
  else
    echo "  [info]    distribution was built WITHOUT patches/nolate.patch: NoLate series cannot be measured"
  fi
fi
echo "Free disk near $FIG9_DIR: $(df -h "$FIG9_DIR" 2>/dev/null | awk "NR==2{print \$4}")"
echo; echo "$ok ok, $bad missing"; [ "$bad" -eq 0 ]
