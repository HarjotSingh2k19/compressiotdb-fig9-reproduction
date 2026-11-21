# Reproducing Fig. 9 of CompressIoTDB (PVLDB 18(10), 2025)

Fig. 9 plots throughput (points/s) against repetition rate (0.1, 0.3, 0.5, 0.7, 0.9) for
QT1 (AGG with time filter, `AGG_RANGE`), QT2 (AGG with value filter, `AGG_VALUE`) and
QT3 (EXP with value filter, `EXP_VALUE`), for four systems:
Uncompressed, IoTDB, CompressIoTDB-NoLate and CompressIoTDB.

## What was and was not run in the sandbox

Run and checked in the sandbox (Linux, JDK 25, no internet, no IoTDB build):

- `datagen/GenerateDataset.java` compiled against the fork's tsfile sources and produced a full
  10^8 x 5 sensor dataset (166 TsFiles, 65 s). `VerifyTsFile.java` read a file back.
- `patches/nolate.patch` applies cleanly (`patch -p1 --dry-run`) and the patched
  `ValuePageReader.java` compiles against the fork's tsfile sources.
- `analyze.py` parsed the authors' real benchmark logs (`res5`) and reproduced their `statics.csv`
  latencies exactly. It wrote `reference_output/` (the authors' Fig. 9 from `statics.csv`).
- `bench/make_configs.py` wrote 30 configs, `bash -n` passes for all shell scripts.

Not run (needs your Mac): building the patched distribution, starting any IoTDB server, loading
datasets, running IoT-Benchmark, and therefore every measured number. `reference_output/` holds the
authors' numbers only. `run_fig9.sh`, `check_env.sh` and `gen_datasets.sh` have not been executed
end to end. The SVG output was checked for valid XML but not looked at in a browser; the PNG path
(matplotlib) was not exercised because matplotlib is not installable in the sandbox.

## About your path

The sandbox cannot see your Mac, so I cannot confirm that
`/Users/hs/Documents/Development/data-management/CompressIoTDB` exists. It is the default
`CIO_REPO` in `config.sh`. `./check_env.sh` prints `[ok]` or `[MISSING]` for the repo, the
distribution, the benchmark and the stock IoTDB, so run it first. Override any path with an
environment variable, for example `CIO_REPO=/other/path ./check_env.sh`.

## Mac commands

All commands assume JDK 17 (`export JAVA_HOME=$(/usr/libexec/java_home -v 17)`).

### 1. Put the toolkit in place

```bash
cd /Users/hs/Documents/Development/data-management/CompressIoTDB   # your repo
cp -R /path/to/fig9 ./fig9        # or keep it anywhere; config.sh finds its own directory
cd fig9 && chmod +x *.sh
./check_env.sh
```

### 2. Build the NoLate switch (skip if you do not need the NoLate series)

CompressIoTDB already decompresses the general-purpose layer (LZ4) lazily: `ValuePageReader`
only calls `checkAndUncompressPageData()` on first access. The repo has no switch to turn that
off. `patches/nolate.patch` adds `-Dcompressiotdb.nolate=true`, which decompresses in the
constructor instead. The default is off, so CompressIoTDB behaves as before. Stop any running
server first.

```bash
cd /Users/hs/Documents/Development/data-management/CompressIoTDB
git apply fig9/patches/nolate.patch
# tsfile (the iotdb build uses org.apache.tsfile 9.0.1-SNAPSHOT from ~/.m2)
cd tsfile
[ -f .mvn/extensions.xml ] && mv .mvn/extensions.xml .mvn/extensions.xml.bak
./mvnw install -P with-java -DskipTests -Dspotless.check.skip=true -Dcheckstyle.skip=true -Drat.skip=true
# distribution (same command you used before)
cd ../iotdb
./mvnw install -pl distribution -am -DskipTests -Dspotless.check.skip=true -Dcheckstyle.skip=true -Drat.skip=true
cd ../fig9 && ./check_env.sh      # must print: distribution contains the NoLate switch
```

The rebuild creates a fresh distribution directory, so data loaded earlier into the old one is
not reused. The script loads everything it needs.

### 3. Stock Apache IoTDB for the "IoTDB" series

```bash
cd ~ && curl -LO https://archive.apache.org/dist/iotdb/1.3.3/apache-iotdb-1.3.3-all-bin.zip
unzip apache-iotdb-1.3.3-all-bin.zip     # -> ~/apache-iotdb-1.3.3-all-bin  (STOCK_HOME default)
```

I could not check that URL from the sandbox (403). Any stock Apache IoTDB 1.3.x release works
(it reads the same TsFile format); set `STOCK_HOME` if you unpack it elsewhere.

### 4. Generate the datasets

```bash
./gen_datasets.sh        # about 1 to 3 minutes per dataset, 10 datasets
```

This writes `work/datasets/cr<k>` (RLE + LZ4, used by IoTDB, NoLate, CompressIoTDB) and
`work/datasets/pl<k>` (PLAIN + UNCOMPRESSED, used by Uncompressed) for k = 1, 3, 5, 7, 9
(rate x 10). Device `root.<db>.g_0.d_0`, five FLOAT sensors `s_0..s_4`, 10^8 points each.
Disk: the compressed sets are about 0.1 GB each, the plain sets about 2 GB each, and loading
copies them into the server data directory, so keep 30 GB free. Delete `work/datasets/pl*`
after the Uncompressed run if space is tight.

Check the generator against the shipped 0.5 dataset:

```bash
du -sh work/datasets/cr5 ../data          # shipped data is about 112 MB; mine is expected to be smaller
```

### 5. Run the benchmark

```bash
export MEMORY_SIZE=8G        # optional; heap for the IoTDB server, adjust to your RAM
./run_fig9.sh                # all systems, about 3 hours on a laptop
# or a quick pass first:
SYSTEMS="iotdb cio" RATES="0.1 0.9" QTS="QT1" LOOP=5 ./run_fig9.sh
```

For each system the script stops any server on port 6667, starts the right distribution (NoLate
adds `-Dcompressiotdb.nolate=true` to `conf/datanode-env.sh` between marker comments), loads the
needed databases with `tools/load-tsfile.sh -s <dir> -os none -of none`, runs one benchmark per
rate and query type with `sh benchmark.sh -cf configs/<db>_<QT>.properties`, then stops the
server. Logs land in `results/<system>/<db>_<QT>.log`. Only one server runs at a time.

### 6. Compare and plot

`run_fig9.sh` ends by calling `analyze.py`. To redo it:

```bash
python3 analyze.py --results results \
  --statics ../benchmark/iot-benchmark-iotdb-1.3/res_on_datasets_with_varying_repetition_rates/statics.csv \
  --out fig9_output
open fig9_output/fig9.svg        # fig9.png too if `pip3 install matplotlib` was done
```

Outputs: `fig9.svg` (top row authors, bottom row measured), `fig9_measured.csv`,
`fig9_reference_authors.csv`, and `summary.txt` with the CompressIoTDB / IoTDB throughput ratio per
rate. Compare ratios and trends with the authors' numbers, not absolute values: their machine was
an i9-9900K with 64 GB.

## Assumptions you should know about

1. **Throughput definition.** `statics.csv` holds average latency in ms (`res_parse.py` reads the
   AVG column of the latency matrix), not throughput. I compute points scanned per query divided by
   latency. Points per query: QT1 1.25e8 (QUERY_INTERVAL 2.5e10 ms at 1 s spacing is 2.5e7 rows,
   times 5 sensors), QT2 and QT3 5e8. Check from the authors' log `res5`: `VALUE_RANGE` returned
   7.16e7 points per query and `EXP_VALUE` 2.86e8, both 57 % of those two figures, which fits a
   value > 7000 filter over exactly these point counts. The paper may define throughput
   differently; change it with `--points-qt1/2/3`.
2. **System mapping.** In `statics.csv`, `baseline` = IoTDB, `plain` = Uncompressed, `ours` =
   CompressIoTDB, `nolazy` = NoLate. The names of the authors' config folders (`config_iotdb`,
   `config_plain`, `config_ours`, `config_nolazy`) support this. The authors' own IoTDB baseline
   build is unknown; I use stock Apache IoTDB 1.3.3 on the same RLE + LZ4 files. Uncompressed runs
   on the CompressIoTDB build with PLAIN + UNCOMPRESSED data.
3. **NoLate** is my reading of Appendix G (general-purpose decompression happens at chunk reader
   construction instead of at series scan). The authors' NoLate build is not in the repo.
4. **Generator parameters.** Appendix B (Algorithm 2) fixes the structure: random deltas, zero-delta
   runs with probability = repetition rate, prefix sum, zoom to mean 10^4, increase rate 1
   (monotone), 10^8 points. It does not give the delta mean/variance or the upper bound of
   `repeat_len`. Defaults: delta ~ N(1, 1) truncated to positive, `repeat_len` uniform in
   [1, 100] (`RUN_MAX`). I picked 100 because small values make the data nearly independent of the
   rate. Measured here with one sensor of 10^8 points: with 1, 98 % of consecutive values are
   equal at rate 0.5 anyway (float precision 2 on a monotone series spanning 0 to 2x10^4); with 10,
   the compressed size is 15 MB at rates 0.1, 0.5 and 0.9; with 100 it is 23 / 17 / 8 MB at
   0.1 / 0.5 / 0.9, which gives the rate dependence the authors' latencies show. The shipped 0.5
   data is about 22 MB per sensor against my 17 MB, so it is not an exact match. To try other
   values, delete `work/datasets` and run `RUN_MAX=<n> ./gen_datasets.sh`, then compare
   `du -sh` with `../data`. The timestamps (start 1000000000003,
   1000 ms step, 7-day partitions) were decoded from the shipped `.tsfile.resource` files.
5. **Workload.** Each query type runs alone (the authors ran them mixed with
   `OPERATION_PROPORTION=0:0:0:1:1:1:1:0:0:0:0:1`), with `CLIENT_NUMBER=2` and `LOOP=20` per
   client instead of 100 to keep the run short. Set `LOOP=100` for a closer match. The original
   `config5*.properties` are not in the repo; the configs are rebuilt from the example config and
   the settings printed in the authors' logs.
6. The benchmark in `benchmark/iot-benchmark-iotdb-1.3/lib` uses the IoTDB 1.3.1 session client
   against a 1.3.3 server. That is how the repo ships it; I did not test it.

## Run log (2026-11-19, MacBook, 8 cores, 8 GB RAM, JDK 17)
Full run done; results in `results/`, figure and tables in `fig9_output/`.
Fixes made after the first run (2026-11-17, kept in `results_2026-11-17_invalid/`):
1. **Missing data.** `root.cr5` and `root.cr7` were never loaded into CompressIoTDB, so its
   0.3-0.7 queries ran on empty databases (1 ms latencies, 1000x "speedups"). The loader now checks
   the row count against `$LENGTH` and retries; `analyze.py` rejects any result with
   `okPoint = 0` or `failOperation > 0`.
2. **Wrong distribution.** `config.sh` picked the `datanode-bin` package, which has no
   `start-confignode.sh`. It now prefers `*all-bin*`.
3. **Restart race.** `stop_server` returned when port 6667 closed, before the JVMs exited, so the
   next start failed. It now waits for the IoTDB processes to exit.
4. **Region memory limit.** With all 10 databases loaded, the DataNode (MEMORY_SIZE=4G) refused new
   data regions (`Total allocated memory for direct buffer ... greater than limit`), so `pl7`
   failed. The script now drops the server copies of the other kind (cr vs pl) before loading.
   Source TsFiles in `work/datasets` are untouched.
5. **NoLate build.** `patches/nolate.patch` is applied to `CompressIoTDB/tsfile`. The full IoTDB
   rebuild failed on unrelated Maven checks, so the rebuilt `tsfile-9.0.1-SNAPSHOT.jar` was copied
   into the all-bin `lib/`. The original jar is in `work/jar_backup/`. The switch is off unless
   `-Dcompressiotdb.nolate=true` is set.
6. Two cells (IoTDB 0.5 QT3: 6 of 40 queries hit the 60 s timeout; Uncompressed 0.7 QT3: empty log)
   were rerun alone (`results_rerun/`); the failed logs are kept as `*.log.failed`.

## Final run (2026-11-21): QT4 added, NoLate and CompressIoTDB rerun
- **QT4 = AGG_RANGE_VALUE** (time range + value filter, 1.25e8 points scanned per query) added to
  `bench/make_configs.py` and `analyze.py`. It was measured for all four systems; the authors'
  reference values come from the same `statics.csv`.
- **NoLate** was rerun for QT1-QT4 at the same server heap as every other system
  (`MEMORY_SIZE=4G`; the Mac has 8 GB, so a larger heap would swap and would not be a fair
  comparison). The first NoLate run had 20-34 s outlier queries (e.g. QT2 rate 0.1 averaged
  10.1 s); the rerun averaged 1.8 s, so the first run was disturbed, not representative. Old logs are
  in `results_nolate_run1/`.
- **CompressIoTDB** was rerun right after NoLate (QT1-QT4) so the two are measured under the same
  conditions. Old logs are in `results_cio_run1/`.
- Final settings for every system: LOOP=20, CLIENT_NUMBER=2, MEMORY_SIZE=4G, one query type per run.
- Finding: CompressIoTDB and NoLate are within about 5 % of each other (0.86x-1.20x). The authors
  report a similar small gap (`ratio_nolazy` 4-11 % in `statics.csv`, 4.4 % in the paper). These
  queries read almost every page, so delaying LZ4 decompression saves little.
