#!/usr/bin/env python3
"""Parse IoT-Benchmark logs, convert latency to throughput, compare with the authors' statics.csv
and draw Fig. 9 ("Throughput across varying repetition rates").

Throughput (points/s) = points scanned by one query / average query latency.
Points scanned per query (5 FLOAT sensors, 10^8 rows, 1 s timestamp spacing):
  QT1 AGG_RANGE : time window QUERY_INTERVAL = 2.5e10 ms = 2.5e7 rows  -> 1.25e8 points
  QT2 AGG_VALUE : whole series                                          -> 5e8 points
  QT3 EXP_VALUE : whole series                                          -> 5e8 points
  QT4 AGG_RANGE_VALUE : same time window as QT1                         -> 1.25e8 points
This was cross-checked with the authors' raw logs (res5): VALUE_RANGE returned 7.16e7 points per
query and EXP_VALUE 2.86e8 per query, i.e. 57 % of 1.25e8 and of 5e8 (value > 7000).
Override with --points-qt1/2/3/4 if your data differs. Standard library only; matplotlib is used for
a PNG when it is installed, an SVG is always written.
"""
import argparse
import csv
import os
import re
import sys

SYSTEMS = [  # key, label, statics.csv column
    ("uncompressed", "Uncompressed", "plain"),
    ("iotdb", "IoTDB", "baseline"),
    ("nolate", "CompressIoTDB-NoLate", "nolazy"),
    ("cio", "CompressIoTDB", "ours"),
]
COLORS = {"uncompressed": "#8c8c8c", "iotdb": "#4c78a8", "nolate": "#f2a541", "cio": "#d1495b"}
QTS = [
    ("QT1", "AGG_RANGE", "QT1: AGG with time filter"),
    ("QT2", "AGG_VALUE", "QT2: AGG with value filter"),
    ("QT3", "EXP_VALUE", "QT3: EXP with value filter"),
    ("QT4", "AGG_RANGE_VALUE", "QT4: AGG with time + value filter"),
]
RATES = ["0.1", "0.3", "0.5", "0.7", "0.9"]


def parse_log(path):
    """Return {operation: (avg_latency_ms, ok_operations)} from one IoT-Benchmark stdout log."""
    ok, lat, okpt, fail = {}, {}, {}, {}
    section = None
    with open(path, errors="replace") as f:
        for line in f:
            if "Result Matrix" in line:
                section = "result"
                continue
            if "Latency (ms) Matrix" in line:
                section = "latency"
                continue
            parts = line.split()
            if not parts or not re.match(r"^[A-Z_]+$", parts[0]) or len(parts) < 2:
                continue
            try:
                value = float(parts[1])
            except ValueError:
                continue
            if section == "result":
                ok[parts[0]] = int(value)
                if len(parts) >= 4:
                    try:
                        okpt[parts[0]] = float(parts[2])
                        fail[parts[0]] = int(float(parts[3]))
                    except ValueError:
                        pass
            elif section == "latency":
                lat[parts[0]] = value
    return {op: (lat[op], ok.get(op, 0), okpt.get(op, 0), fail.get(op, 0)) for op in lat}


def points_per_query(args):
    return {"QT1": args.points_qt1, "QT2": args.points_qt2, "QT3": args.points_qt3,
            "QT4": args.points_qt4}


def load_measured(results_dir, pts):
    rows = []
    for key, label, _ in SYSTEMS:
        for r in RATES:
            k = int(round(float(r) * 10))
            for qt, op, _t in QTS:
                for kind in ("cr", "pl"):
                    path = os.path.join(results_dir, key, "%s%d_%s.log" % (kind, k, qt))
                    if not os.path.exists(path):
                        continue
                    res = parse_log(path).get(op)
                    if not res or res[0] <= 0 or res[1] == 0:
                        print("warning: no valid %s result in %s" % (op, path), file=sys.stderr)
                        continue
                    # An aggregate over loaded data returns >= 1 point per op; 0 points means the
                    # query hit an empty database. Failed ops also invalidate the average.
                    if res[2] <= 0 or res[3] > 0:
                        print("warning: REJECTED %s in %s (okPoint=%s, failOperation=%s): "
                              "data missing or queries failed" % (op, path, res[2], res[3]),
                              file=sys.stderr)
                        continue
                    rows.append({"system": key, "rate": r, "qt": qt, "op": op,
                                 "latency_ms": res[0], "ok_ops": res[1],
                                 "throughput": pts[qt] / (res[0] / 1000.0)})
    return rows


def load_reference(statics, pts):
    """statics.csv blocks: 'resK,baseline,plain,ours,nolazy,...' then one row per operation."""
    rows, tag = [], None
    cols = None
    with open(statics) as f:
        for line in f:
            p = line.strip().split(",")
            if len(p) < 5:
                continue
            if p[0].startswith("res"):
                tag = p[0]
                cols = p[1:5]
                continue
            op = p[0]
            qt = next((q for q, o, _ in QTS if o == op), None)
            if qt is None or tag is None:
                continue
            rate = "%.1f" % (int(tag[3:]) / 10.0)
            vals = dict(zip(cols, map(float, p[1:5])))
            for key, _label, col in SYSTEMS:
                rows.append({"system": key, "rate": rate, "qt": qt, "op": op,
                             "latency_ms": vals[col], "ok_ops": "",
                             "throughput": pts[qt] / (vals[col] / 1000.0)})
    return rows


def write_csv(path, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["system", "rate", "qt", "op", "latency_ms", "ok_ops", "throughput_points_per_s"])
        for r in sorted(rows, key=lambda r: (r["qt"], r["rate"], r["system"])):
            w.writerow([r["system"], r["rate"], r["qt"], r["op"], r["latency_ms"], r["ok_ops"],
                        "%.0f" % r["throughput"]])


def index(rows):
    return {(r["system"], r["rate"], r["qt"]): r["throughput"] for r in rows}


def speedup_table(name, rows):
    idx = index(rows)
    out = ["%s: CompressIoTDB throughput / IoTDB throughput" % name,
           "  %-5s" % "" + "".join("%9s" % ("rate " + r) for r in RATES)]
    for qt, _op, title in QTS:
        cells = []
        for r in RATES:
            a, b = idx.get(("cio", r, qt)), idx.get(("iotdb", r, qt))
            cells.append("%9s" % ("%.2fx" % (a / b) if a and b else "-"))
        out.append("  %-5s" % qt + "".join(cells))
    return "\n".join(out)


# ---------------------------------------------------------------- SVG output (no dependencies)
def nice_max(v):
    import math
    e = 10 ** math.floor(math.log10(v))
    for m in (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        if m * e >= v:
            return m * e
    return 10 * e


def fmt(v):
    if v >= 1e9:
        return "%.1fG" % (v / 1e9)
    if v >= 1e6:
        return "%gM" % round(v / 1e6, 1)
    if v >= 1e3:
        return "%gk" % round(v / 1e3, 1)
    return "%g" % v


def svg_chart(path, panels):
    """panels: list of rows; each row = (row_title, rows_of_results)."""
    pw, ph, ml, mt = 360, 230, 70, 46
    width = len(QTS) * pw + 40
    height = len(panels) * (ph + 80) + 50
    s = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" font-family="Helvetica,Arial,sans-serif" font-size="11">' % (width, height),
         '<rect width="100%" height="100%" fill="white"/>']
    # legend
    x = 20
    for key, label, _ in SYSTEMS:
        s.append('<rect x="%d" y="12" width="12" height="12" fill="%s"/><text x="%d" y="22">%s</text>' % (x, COLORS[key], x + 16, label))
        x += 30 + 7 * len(label)
    for ri, (row_title, rows) in enumerate(panels):
        idx = index(rows)
        oy = 40 + ri * (ph + 80)
        s.append('<text x="20" y="%d" font-size="13" font-weight="bold">%s</text>' % (oy, row_title))
        for ci, (qt, _op, title) in enumerate(QTS):
            ox = 10 + ci * pw
            vals = [idx.get((k, r, qt)) for k, _l, _c in SYSTEMS for r in RATES]
            vmax = nice_max(max([v for v in vals if v] or [1]))
            x0, y0, w, h = ox + ml, oy + mt, pw - ml - 20, ph - mt - 30
            s.append('<text x="%d" y="%d" font-weight="bold">%s</text>' % (x0, oy + 22, title))
            for t in range(5):
                yv = vmax * t / 4
                y = y0 + h - h * t / 4
                s.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#ddd"/>' % (x0, y, x0 + w, y))
                s.append('<text x="%d" y="%.1f" text-anchor="end">%s</text>' % (x0 - 4, y + 4, fmt(yv)))
            gw = w / len(RATES)
            bw = gw * 0.8 / len(SYSTEMS)
            for gi, r in enumerate(RATES):
                gx = x0 + gi * gw + gw * 0.1
                for si, (key, _l, _c) in enumerate(SYSTEMS):
                    v = idx.get((key, r, qt))
                    if v:
                        bh = h * v / vmax
                        s.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>' % (gx + si * bw, y0 + h - bh, bw, bh, COLORS[key]))
                s.append('<text x="%.1f" y="%d" text-anchor="middle">%s</text>' % (x0 + gi * gw + gw / 2, y0 + h + 15, r))
            s.append('<text x="%.1f" y="%d" text-anchor="middle">repetition rate</text>' % (x0 + w / 2, y0 + h + 29))
            if ci == 0:
                s.append('<text x="%d" y="%d" transform="rotate(-90 %d %d)" text-anchor="middle">throughput (points/s)</text>' % (ox + 12, y0 + h / 2, ox + 12, y0 + h / 2))
    s.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(s))


def png_chart(path, panels):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return False
    fig, axes = plt.subplots(len(panels), len(QTS), figsize=(18, 3.8 * len(panels)), squeeze=False)
    for ri, (row_title, rows) in enumerate(panels):
        idx = index(rows)
        for ci, (qt, _op, title) in enumerate(QTS):
            ax = axes[ri][ci]
            bw = 0.8 / len(SYSTEMS)
            for si, (key, label, _c) in enumerate(SYSTEMS):
                ys = [idx.get((key, r, qt), 0) for r in RATES]
                ax.bar([i + si * bw for i in range(len(RATES))], ys, bw, label=label, color=COLORS[key])
            ax.set_xticks([i + 0.4 - bw / 2 for i in range(len(RATES))])
            ax.set_xticklabels(RATES)
            ax.set_xlabel("repetition rate")
            ax.set_title("%s\n%s" % (row_title, title), fontsize=9)
            if ci == 0:
                ax.set_ylabel("throughput (points/s)")
    axes[0][0].legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="results")
    ap.add_argument("--statics", required=True, help="authors' statics.csv")
    ap.add_argument("--out", default="fig9_output")
    ap.add_argument("--points-qt1", type=float, default=1.25e8)
    ap.add_argument("--points-qt2", type=float, default=5e8)
    ap.add_argument("--points-qt3", type=float, default=5e8)
    # QT4 scans the same time window as QT1 (2.5e7 rows x 5 sensors)
    ap.add_argument("--points-qt4", type=float, default=1.25e8)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    pts = points_per_query(args)

    ref = load_reference(args.statics, pts)
    write_csv(os.path.join(args.out, "fig9_reference_authors.csv"), ref)
    panels = [("Authors' raw results (statics.csv, i9-9900K 64 GB)", ref)]
    report = [speedup_table("Authors", ref)]

    meas = load_measured(args.results, pts) if os.path.isdir(args.results) else []
    if meas:
        write_csv(os.path.join(args.out, "fig9_measured.csv"), meas)
        panels.append(("This run (measured)", meas))
        report.append(speedup_table("Measured", meas))
    else:
        report.append("No measured logs found under %s (run ./run_fig9.sh first)." % args.results)

    svg_chart(os.path.join(args.out, "fig9.svg"), panels)
    made_png = png_chart(os.path.join(args.out, "fig9.png"), panels)
    text = "\n\n".join(report)
    with open(os.path.join(args.out, "summary.txt"), "w") as f:
        f.write(text + "\n")
    print(text)
    print("\nwrote %s/{fig9.svg%s, fig9_reference_authors.csv%s, summary.txt}" % (
        args.out, ", fig9.png" if made_png else "", ", fig9_measured.csv" if meas else ""))


if __name__ == "__main__":
    main()
