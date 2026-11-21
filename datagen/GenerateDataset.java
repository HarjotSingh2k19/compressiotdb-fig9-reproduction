import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.apache.tsfile.common.conf.TSFileDescriptor;
import org.apache.tsfile.enums.TSDataType;
import org.apache.tsfile.file.metadata.enums.CompressionType;
import org.apache.tsfile.file.metadata.enums.TSEncoding;
import org.apache.tsfile.read.common.Path;
import org.apache.tsfile.write.TsFileWriter;
import org.apache.tsfile.write.record.Tablet;
import org.apache.tsfile.write.schema.MeasurementSchema;

/**
 * Synthetic dataset generator for the CompressIoTDB Fig. 9 reproduction.
 *
 * <p>Implements "Algorithm 2: Numerical Data Generator" of the paper appendix (Appendix B): a delta
 * sequence is built (a zero-delta run with probability = repetition rate, otherwise a Gaussian
 * delta whose sign follows the increase rate), prefix-summed, then zoomed so the mean equals
 * --mean. The result is written as TsFiles that can be loaded with tools/load-tsfile.sh.
 *
 * <p>Layout mirrors the shipped example dataset (CompressIoTDB/data): one aligned device
 * root.&lt;db&gt;.g_0.d_0, sensors s_0..s_4 (FLOAT), timestamps 1000000000003 + i * 1000 ms, one
 * TsFile per 7-day time partition, directory root.&lt;db&gt;/20/&lt;partitionId&gt;/.
 *
 * <p>Streaming, two passes per sensor (pass 1: mean of the prefix sum; pass 2: regenerate and
 * write), so memory use does not depend on --length.
 */
public class GenerateDataset {
  static final long START_TS = 1000000000003L;
  static final long STEP_MS = 1000L;
  static final long PARTITION_MS = 604800000L; // IoTDB default time_partition_interval (7 days)
  static final int TABLET_ROWS = 10000;

  // ---- parameters ----
  static double rate = 0.5;
  static long length = 100_000_000L;
  static int sensors = 5;
  static String db = "test_5";
  static String out = "./out";
  static String encoding = "RLE";
  static String compressor = "LZ4";
  static long seed = 42;
  static double mean = 10000.0;
  static double deltaMean = 1.0;
  static double deltaSd = 1.0;
  static double increase = 1.0; // 1.0 => monotonic non-decreasing
  static int runMax = 100; // repeat_len is uniform in [1, runMax]; 100 is calibrated, see README

  /** Streams the delta sequence of one sensor; deterministic given the seed. */
  static final class DeltaStream {
    final Random rnd;

    DeltaStream(long s) {
      rnd = new Random(s);
    }

    /** Returns the next block of deltas into buf; returns the count (<= buf.length). */
    int fill(double[] buf, long remaining) {
      int n = 0;
      int cap = (int) Math.min(buf.length, remaining);
      while (n < cap) {
        if (rnd.nextDouble() < rate) {
          int len = runMax <= 1 ? 1 : 1 + rnd.nextInt(runMax);
          for (int k = 0; k < len && n < cap; k++) {
            buf[n++] = 0.0;
          }
        } else {
          boolean positive = rnd.nextDouble() < increase;
          double d = 0;
          if (positive) {
            while (d <= 0) {
              d = deltaMean + deltaSd * rnd.nextGaussian();
            }
          } else {
            while (d >= 0) {
              d = -deltaMean + deltaSd * rnd.nextGaussian();
            }
          }
          buf[n++] = d;
        }
      }
      return n;
    }
  }

  static double prefixMean(long s) {
    DeltaStream ds = new DeltaStream(s);
    double[] buf = new double[1 << 16];
    double acc = 0, sum = 0;
    long done = 0;
    while (done < length) {
      int n = ds.fill(buf, length - done);
      for (int i = 0; i < n; i++) {
        acc += buf[i];
        sum += acc;
      }
      done += n;
    }
    return sum / length;
  }

  public static void main(String[] args) throws Exception {
    for (int i = 0; i < args.length; i += 2) {
      String v = args[i + 1];
      switch (args[i]) {
        case "--rate": rate = Double.parseDouble(v); break;
        case "--length": length = Long.parseLong(v); break;
        case "--sensors": sensors = Integer.parseInt(v); break;
        case "--db": db = v; break;
        case "--out": out = v; break;
        case "--encoding": encoding = v; break;
        case "--compressor": compressor = v; break;
        case "--seed": seed = Long.parseLong(v); break;
        case "--mean": mean = Double.parseDouble(v); break;
        case "--delta-mean": deltaMean = Double.parseDouble(v); break;
        case "--delta-sd": deltaSd = Double.parseDouble(v); break;
        case "--increase": increase = Double.parseDouble(v); break;
        case "--run-max": runMax = Integer.parseInt(v); break;
        default: throw new IllegalArgumentException("unknown option " + args[i]);
      }
    }
    System.out.printf(
        "rate=%.2f length=%d sensors=%d db=root.%s encoding=%s compressor=%s seed=%d runMax=%d%n",
        rate, length, sensors, db, encoding, compressor, seed, runMax);

    // Pass 1 (parallel over sensors): scale factor that makes the series mean equal --mean.
    ExecutorService pool = Executors.newFixedThreadPool(Math.min(sensors, 8));
    List<Future<Double>> fs = new ArrayList<>();
    for (int s = 0; s < sensors; s++) {
      final long sd = seed + s;
      fs.add(pool.submit(() -> prefixMean(sd)));
    }
    double[] scale = new double[sensors];
    for (int s = 0; s < sensors; s++) {
      scale[s] = mean / fs.get(s).get();
    }
    pool.shutdown();
    System.out.println("pass 1 done (zoom factors computed)");

    // Pass 2: regenerate the identical sequences and write TsFiles.
    TSFileDescriptor.getInstance().getConfig().setFloatPrecision(2);
    DeltaStream[] streams = new DeltaStream[sensors];
    double[][] bufs = new double[sensors][1 << 14];
    int[] bufLen = new int[sensors];
    int[] bufPos = new int[sensors];
    double[] acc = new double[sensors];
    long[] produced = new long[sensors];
    for (int s = 0; s < sensors; s++) {
      streams[s] = new DeltaStream(seed + s);
    }

    String device = "root." + db + ".g_0.d_0";
    List<MeasurementSchema> schemas = new ArrayList<>();
    TSEncoding enc = TSEncoding.valueOf(encoding);
    CompressionType comp = CompressionType.valueOf(compressor);
    for (int s = 0; s < sensors; s++) {
      schemas.add(new MeasurementSchema("s_" + s, TSDataType.FLOAT, enc, comp));
    }

    TsFileWriter writer = null;
    long curPartition = Long.MIN_VALUE;
    int fileNo = 0;
    long baseName = System.currentTimeMillis();
    Tablet tablet = new Tablet(device, schemas, TABLET_ROWS);
    long written = 0;
    long lastReport = System.nanoTime();
    while (written < length) {
      long ts0 = START_TS + written * STEP_MS;
      long partition = Math.floorDiv(ts0, PARTITION_MS);
      long partitionEndTs = (partition + 1) * PARTITION_MS;
      long rowsToPartitionEnd = (partitionEndTs - ts0 + STEP_MS - 1) / STEP_MS;
      int rows = (int) Math.min(Math.min(TABLET_ROWS, length - written), rowsToPartitionEnd);
      if (partition != curPartition) {
        if (writer != null) {
          writer.close();
        }
        File dir = new File(out, "root." + db + "/20/" + partition);
        dir.mkdirs();
        fileNo++;
        File f = new File(dir, (baseName + fileNo) + "-" + fileNo + "-0-0.tsfile");
        writer = new TsFileWriter(f);
        writer.registerAlignedTimeseries(new Path(device), schemas);
        curPartition = partition;
      }
      tablet.reset();
      for (int r = 0; r < rows; r++) {
        tablet.timestamps[r] = ts0 + r * STEP_MS;
      }
      for (int s = 0; s < sensors; s++) {
        float[] col = (float[]) tablet.values[s];
        for (int r = 0; r < rows; r++) {
          if (bufPos[s] >= bufLen[s]) {
            bufLen[s] = streams[s].fill(bufs[s], length - produced[s]);
            bufPos[s] = 0;
          }
          acc[s] += bufs[s][bufPos[s]++];
          produced[s]++;
          col[r] = (float) (acc[s] * scale[s]);
        }
      }
      tablet.rowSize = rows;
      writer.writeAligned(tablet);
      written += rows;
      if (System.nanoTime() - lastReport > 10_000_000_000L) {
        System.out.printf("  %.1f%% written%n", 100.0 * written / length);
        lastReport = System.nanoTime();
      }
    }
    writer.close();
    System.out.printf("done: %d points/sensor in %d TsFile(s) under %s/root.%s%n", length, fileNo, out, db);
  }
}
