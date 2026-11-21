#!/bin/bash
# Generates the synthetic datasets (Appendix B, Algorithm 2) for every repetition rate, once as
# RLE+LZ4 (database cr<k>) and once as PLAIN+UNCOMPRESSED (database pl<k>), k = rate*10.
# Uses the tsfile classes of the built CompressIoTDB distribution, so the files match its format.
set -euo pipefail
. "$(dirname "$0")/config.sh"
[ -n "$CIO_HOME" ] || { echo "CIO_HOME not found; run ./check_env.sh"; exit 1; }
BUILD="$FIG9_DIR/work/datagen-classes"; mkdir -p "$BUILD"
CP="$CIO_HOME/lib/*"
javac -nowarn -cp "$CP" -d "$BUILD" "$FIG9_DIR"/datagen/GenerateDataset.java "$FIG9_DIR"/datagen/VerifyTsFile.java
for r in $RATES; do
  k=$(rate_key "$r")
  for kind in cr pl; do
    out="$DATA_ROOT/$kind$k"
    if [ -d "$out/root.$kind$k" ]; then echo "skip $kind$k (exists: $out)"; continue; fi
    if [ "$kind" = cr ]; then enc=RLE; comp=LZ4; else enc=PLAIN; comp=UNCOMPRESSED; fi
    echo "=== generating $kind$k rate=$r $enc/$comp ==="
    java -Dlogback.configurationFile="$FIG9_DIR/datagen/logback-quiet.xml" -cp "$BUILD:$CP" GenerateDataset \
      --rate "$r" --length "$LENGTH" --sensors "$SENSORS" --db "$kind$k" --out "$out" \
      --encoding "$enc" --compressor "$comp" --seed "$SEED" --run-max "$RUN_MAX"
    du -sh "$out"
  done
done
echo "Datasets are in $DATA_ROOT"
