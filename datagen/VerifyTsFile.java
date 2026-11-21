import java.util.ArrayList;
import java.util.List;
import org.apache.tsfile.read.TsFileReader;
import org.apache.tsfile.read.TsFileSequenceReader;
import org.apache.tsfile.read.common.Path;
import org.apache.tsfile.read.common.RowRecord;
import org.apache.tsfile.read.expression.QueryExpression;
import org.apache.tsfile.read.query.dataset.QueryDataSet;

/** Reads one TsFile back and prints row count, first rows, min/max/mean of s_0 and repeat rate. */
public class VerifyTsFile {
  public static void main(String[] a) throws Exception {
    String file = a[0];
    String device = a[1]; // e.g. root.test_5.g_0.d_0
    try (TsFileSequenceReader r = new TsFileSequenceReader(file);
        TsFileReader reader = new TsFileReader(r)) {
      List<Path> paths = new ArrayList<>();
      paths.add(new Path(device, "s_0", false));
      QueryDataSet ds = reader.query(QueryExpression.create(paths, null));
      long n = 0, same = 0;
      double min = Double.MAX_VALUE, max = -Double.MAX_VALUE, sum = 0, prev = Double.NaN;
      while (ds.hasNext()) {
        RowRecord rec = ds.next();
        double v = rec.getFields().get(0).getFloatV();
        if (n < 3) System.out.println(rec);
        if (v == prev) same++;
        prev = v; n++; sum += v; min = Math.min(min, v); max = Math.max(max, v);
      }
      System.out.printf("rows=%d min=%.2f max=%.2f mean=%.2f repeatedFraction=%.4f%n", n, min, max, sum / n, (double) same / n);
    }
  }
}
