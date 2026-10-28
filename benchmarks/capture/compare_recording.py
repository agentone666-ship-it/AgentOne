#!/usr/bin/env python3
"""Private opt-in waveform acceptance. Never uploads or commits audio/transcripts.

Requires ffmpeg, numpy and scipy. A real playback/capture must be performed first.
The source file is a reference only and is never inserted into the capture database.
"""
import argparse
import datetime as dt
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import numpy as np
from scipy.signal import correlate

RATE = 2000

def decode(path):
    data = subprocess.check_output(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(path), "-vn", "-ac", "1", "-ar", str(RATE), "-f", "f32le", "-"])
    return np.frombuffer(data, dtype="<f4").astype(np.float64)

def best_match(search, template):
    template = template - template.mean()
    energy = np.dot(template, template)
    n = len(template)
    if len(search) < n or energy < 1e-12:
        return -1.0, 0
    sums = np.r_[0.0, np.cumsum(search)]
    powers = np.r_[0.0, np.cumsum(search * search)]
    variance = np.maximum(1e-20, powers[n:] - powers[:-n] - (sums[n:] - sums[:-n]) ** 2 / n)
    score = correlate(search, template, mode="valid", method="fft") / np.sqrt(variance * energy)
    # FFT roundoff divided by a near-zero silent-window variance produces
    # impossible scores >1. Silence is never an acceptable waveform anchor.
    score[variance < max(1e-10, float(variance.max()) * 1e-9)] = -1
    score = np.clip(score, -1, 1)
    index = int(score.argmax())
    return float(score[index]), index

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--reference", required=True)
    p.add_argument("--memory", required=True)
    p.add_argument("--started-ms", type=int, required=True)
    p.add_argument("--ended-ms", type=int, required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    root = pathlib.Path(args.memory).resolve()
    reference = pathlib.Path(args.reference).resolve()
    source = decode(reference)
    db = sqlite3.connect("file:" + str(root / "memory.sqlite") + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    rows = db.execute("SELECT * FROM segments WHERE state='sealed' AND source='mixed' AND started_ms<? AND ended_ms>? ORDER BY started_ms", (args.ended_ms, args.started_ms)).fetchall()
    if not rows:
        raise SystemExit("No sealed capture files in requested window")
    start = min(r["started_ms"] for r in rows)
    end = max(r["ended_ms"] for r in rows)
    captured = np.zeros(round((end - start) / 1000 * RATE) + RATE * 3)
    manifests = []
    for r in rows:
        path = (root / r["relative_path"]).resolve()
        if not path.is_relative_to(root / "Audio"):
            raise SystemExit("Capture source escaped Audio root")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != r["sha256"]:
            raise SystemExit("Capture hash mismatch")
        audio = decode(path)
        index = round((r["started_ms"] - start) / 1000 * RATE)
        captured[index:index + len(audio)] = audio
        manifests.append({"id": r["id"], "started_ms": r["started_ms"], "ended_ms": r["ended_ms"], "sha256": digest})
    # Coarse anchors establish the actual playback offset, independent of a UI click timestamp.
    anchors = []
    for second in range(2, int(len(source) / RATE) - 3, 30):
        template = source[second * RATE:(second + 3) * RATE]
        if np.sqrt(np.mean(template ** 2)) < 0.002:
            continue
        score, index = best_match(captured, template)
        if score >= 0.45:
            anchors.append((second, index / RATE, score))
    if len(anchors) < 5:
        raise SystemExit("Too few independent waveform anchors; capture cannot be accepted")
    anchors = np.array(anchors)
    offset = np.median(anchors[:, 1] - anchors[:, 0])
    good = anchors[np.abs(anchors[:, 1] - anchors[:, 0] - offset) < 1.5]
    if len(good) < 5:
        raise SystemExit("Waveform anchors are inconsistent")
    slope, intercept = np.polyfit(good[:, 0], good[:, 1], 1)
    if not 0.995 < slope < 1.005:
        raise SystemExit("Unexpected playback speed or capture clock drift")
    # Dense 1-second voiced windows every 0.5 seconds: not ASR or a file-count proxy.
    windows = []
    for second in np.arange(0, len(source) / RATE - 1, 0.5):
        first = round(second * RATE)
        template = source[first:first + RATE]
        if np.sqrt(np.mean(template ** 2)) < 0.002:
            continue
        predicted = (slope * second + intercept) * RATE
        left = max(0, round(predicted - 0.25 * RATE))
        right = min(len(captured), round(predicted + 1.25 * RATE))
        score, index = best_match(captured[left:right], template)
        windows.append({"source_s": round(float(second), 3), "score": round(score, 4), "matched": score >= 0.55, "capture_s": round((left + index) / RATE, 3)})
    failed = [w for w in windows if not w["matched"]]
    first = [w for w in windows if w["source_s"] < 5]
    last = [w for w in windows if w["source_s"] > len(source) / RATE - 6]
    passed = bool(windows) and not failed and bool(first) and bool(last)
    report = {"benchmark": "private-real-waveform-completeness-v1", "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "passed": passed, "scope": "Real source/captured waveform comparison; dense voiced windows, not ASR quality or a guarantee during sleep/power loss", "source_sha256": hashlib.sha256(reference.read_bytes()).hexdigest(), "reference_duration_s": len(source) / RATE, "capture_window_ms": [start, end], "source_offset_in_capture_s": float(intercept), "clock_scale": float(slope), "voiced_windows": len(windows), "matched_windows": len(windows) - len(failed), "failed_windows": failed, "first_5s_passed": bool(first) and all(w["matched"] for w in first), "last_5s_passed": bool(last) and all(w["matched"] for w in last), "capture_sources": manifests, "windows": windows}
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    output.chmod(0o600)
    print(json.dumps({k: v for k, v in report.items() if k not in ("windows", "capture_sources", "failed_windows")}, ensure_ascii=False))
    if failed:
        print(json.dumps({"failed_windows": failed[:25]}))
    raise SystemExit(0 if passed else 1)

if __name__ == "__main__":
    main()
