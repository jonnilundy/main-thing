#!/usr/bin/env python3
"""Summarize a SwiftUI template Instruments trace of Main Thing.

    scripts/trace-summary.py <file.trace> [--window START-END]

Prints hitches (count, durations), app commits and WindowServer renders over 16.7ms, SwiftUI
body updates per view, main thread CPU and its top frames. `--window 10-40` keeps only seconds
10 to 40 of the recording, for the part where the rows were swept. Exported tables are cached in
<file.trace>.export/ next to the trace.
"""
import collections
import os
import subprocess
import sys
import xml.etree.ElementTree as ET


def export(trace, schema, outdir):
    path = os.path.join(outdir, schema + ".xml")
    if not os.path.exists(path):
        xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
        with open(path, "wb") as out:
            subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
                           stdout=out, stderr=subprocess.DEVNULL, check=True)
    return path


def rows(path):
    """Rows as {mnemonic: element}, with id/ref references resolved."""
    node = ET.parse(path).getroot().find("node")
    if node is None or node.find("schema") is None:
        return []
    cols = [c.find("mnemonic").text for c in node.find("schema").findall("col")]
    ids = {}

    def register(e):
        if e.get("id"):
            ids[e.get("id")] = e
        for child in e:
            register(child)

    def resolve(e):
        return ids.get(e.get("ref"), e) if e.get("ref") else e

    out = []
    for r in node.findall("row"):
        register(r)
        out.append({mn: resolve(e) for mn, e in zip(cols, list(r))})
    out_resolve = resolve
    return out, out_resolve


def value(e):
    try:
        return int(e.text)
    except (TypeError, ValueError, AttributeError):
        return None


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    trace = args[0].rstrip("/")
    lo, hi = 0.0, float("inf")
    if "--window" in args:
        a, b = args[args.index("--window") + 1].split("-")
        lo, hi = float(a), float(b)
    outdir = trace + ".export"
    os.makedirs(outdir, exist_ok=True)

    def table(schema, time_key):
        got = rows(export(trace, schema, outdir))
        if not got:
            return [], (lambda e: e)
        rs, resolve = got
        keep = [r for r in rs if value(r.get(time_key)) is not None and lo <= value(r[time_key]) / 1e9 <= hi]
        return keep, resolve

    span = "whole trace" if hi == float("inf") else f"seconds {lo:g} to {hi:g}"
    print(f"trace: {trace} ({span})")

    hitches, _ = table("hitches", "start")
    durations = sorted(value(r["duration"]) / 1e6 for r in hitches)
    print(f"hitches: {len(hitches)}" + (f", ms min {durations[0]:.1f} median {durations[len(durations)//2]:.1f} max {durations[-1]:.1f} total {sum(durations):.0f}" if durations else ""))

    commits, _ = table("hitches-updates", "start")
    cms = sorted(value(r["duration"]) / 1e6 for r in commits)
    if cms:
        print(f"app commits: {len(cms)}, ms median {cms[len(cms)//2]:.2f} p95 {cms[int(len(cms)*.95)]:.2f} max {cms[-1]:.2f}, over 8.3ms {sum(c > 8.3 for c in cms)}, over 16.7ms {sum(c > 16.7 for c in cms)}")

    renders, _ = table("hitches-renders", "start")
    rms = sorted(value(r["duration"]) / 1e6 for r in renders)
    if rms:
        offscreen = sum(value(r["offscreen-passes"]) or 0 for r in renders)
        print(f"renders: {len(rms)}, ms median {rms[len(rms)//2]:.2f} max {rms[-1]:.2f}, offscreen passes {offscreen}")

    updates, _ = table("swiftui-updates", "start")
    bodies = collections.Counter()
    body_time = collections.Counter()
    for r in updates:
        d = r["description"].get("fmt") or ""
        if d.startswith("DynamicBody<ViewBodyAccessor<"):
            name = d[len("DynamicBody<ViewBodyAccessor<"):].split(">")[0].split("<")[0]
            bodies[name] += 1
            body_time[name] += value(r["duration"]) or 0
    total_update = sum(value(r["duration"]) or 0 for r in updates) / 1e6
    print(f"swiftui updates: {len(updates)} ({total_update:.1f} ms); body updates per view:")
    for name, n in bodies.most_common(12):
        print(f"  {n:6d}  {body_time[name]/1e6:8.1f} ms  {name}")

    samples, resolve = table("time-profile", "time")
    main = [r for r in samples if (r["thread"].get("fmt") or "").startswith("Main Thread")]
    weight = lambda r: value(r["weight"]) or 0
    main_ms = sum(weight(r) for r in main) / 1e6
    all_ms = sum(weight(r) for r in samples) / 1e6
    print(f"cpu: main thread {main_ms:.0f} ms, all threads {all_ms:.0f} ms")

    inclusive = collections.Counter()
    leaf = collections.Counter()
    for r in main:
        bt = r.get("stack")
        if bt is None:
            continue
        frames = [resolve(f).get("name") or "?" for f in bt.findall("frame")]
        if frames:
            leaf[frames[0]] += weight(r)
        for name in set(frames):
            inclusive[name] += weight(r)
    ours = [(n, w) for n, w in inclusive.most_common() if "MainThing" in n or n.split("(")[0].split(".")[0] in APP_TYPES]
    print("main thread, app frames by inclusive time:")
    for name, w in ours[:12]:
        print(f"  {w/1e6:8.1f} ms  {name[:130]}")
    print("main thread, leaf frames by self time:")
    for name, w in leaf.most_common(12):
        print(f"  {w/1e6:8.1f} ms  {name[:130]}")
    hover_ms = sum(v for n, v in inclusive.items() if n.startswith("HoverEventDispatcher.receiveEvents")) / 1e6
    row_ms = sum(v for n, v in inclusive.items() if n.startswith("TaskRow.body")) / 1e6
    row_updates = bodies.get("TaskRow", 0)
    swept = row_updates > 0 or row_ms > 0
    print(f"sweep evidence: TaskRow body updates {row_updates}, TaskRow.body {row_ms:.1f} ms, SwiftUI hover dispatch {hover_ms:.1f} ms"
          + ("" if swept else "  <- no row hover in this trace: the notch was not open under the cursor"))
    watch = ["NSHapticFeedbackManager", "setIgnoresMouseEvents", "HoverController.evaluate", "CrossOffRenderer", "PenStroke",
             "sizeWithAttributes", "accessibilityDisplayShouldIncreaseContrast", "rowHover", "os_log", "Logger"]
    print("main thread, watched frames (inclusive):")
    for key in watch:
        w = sum(v for n, v in inclusive.items() if key in n)
        print(f"  {w/1e6:8.1f} ms  {key}")


APP_TYPES = {"NotchBody", "NotchView", "Band", "TaskRow", "OpenContent", "Ink", "CrossOffRenderer", "HoverController",
             "NotchModel", "PanelLayout", "PenStroke", "RowHaptics", "NotchHover", "Dot", "RowsBlock", "Sounds"}

if __name__ == "__main__":
    main()
