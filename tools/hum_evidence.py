#!/usr/bin/env python3
"""Isolate the board's vertical-rate electrical pickup from a PCB
recording and produce the evidence artifacts for ACCURACY.md.

Method G of docs/plan_refresh_measurement.md: during quiet passages the
recording contains a narrow spectral line from the board's frame-rate
electrical load, picked up on the audio ground. The line and its second
harmonic sit at the VERTICAL RATE (measured 60.24 / 120.48 Hz after
chain correction), NOT at US mains (60.00 / 120.00, grid-regulated).

Outputs (docs/evidence/refresh/):
  spectrum_fund_<tag>.png   55-65 Hz spectrum, mains vs measured marked
  spectrum_harm_<tag>.png   115-125 Hz spectrum, same
  hum_isolated_<tag>.wav    bandpass-isolated, normalized hum audio
  peaks printed to stdout (raw, uncorrected for the chain clock)

Usage: hum_evidence.py <video> <start_s> <end_s> <tag> [chain_scale]
"""
import subprocess
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy.io import wavfile
from scipy.signal import butter, sosfiltfilt

OUT = "/Users/leefoot/python_scripts/hyperduel-mister/docs/evidence/refresh"


def extract(video, t0, t1):
    cmd = ["ffmpeg", "-v", "error", "-ss", str(t0), "-to", str(t1),
           "-i", video, "-vn", "-ac", "1", "-ar", "48000",
           "-f", "f32le", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32), 48000


def spectrum_peak(x, fs, f_lo, f_hi):
    # single long FFT with 8x zero-padding for smooth interpolation
    n = len(x)
    w = np.hanning(n)
    nfft = 1 << (int(np.ceil(np.log2(n))) + 3)
    spec = np.abs(np.fft.rfft(x * w, nfft)) ** 2
    freqs = np.fft.rfftfreq(nfft, 1 / fs)
    band = (freqs >= f_lo) & (freqs <= f_hi)
    fb, sb = freqs[band], spec[band]
    pk = fb[np.argmax(sb)]
    # SNR: peak power over median power in the band
    snr = sb.max() / np.median(sb)
    return fb, sb, pk, snr


def plot_band(fb, sb, pk, mains, title, path, chain_scale):
    db = 10 * np.log10(sb / sb.max())
    plt.figure(figsize=(9, 4.2))
    plt.plot(fb, db, lw=0.8, color="#1f77b4")
    plt.axvline(mains, color="#d62728", ls="--", lw=1.2,
                label=f"US mains ({mains:.2f} Hz)")
    plt.axvline(pk, color="#2ca02c", ls="-", lw=1.2,
                label=f"measured line ({pk:.3f} Hz raw, "
                      f"{pk * chain_scale:.3f} Hz chain-corrected)")
    plt.xlabel("frequency [Hz]")
    plt.ylabel("power [dB rel. peak]")
    plt.title(title)
    plt.legend(loc="upper right", fontsize=8)
    plt.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig(path, dpi=140)
    plt.close()


def main(video, t0, t1, tag, chain_scale=1.0):
    x, fs = extract(video, t0, t1)
    print(f"{tag}: {len(x)/fs:.1f}s of audio")

    for name, lo, hi, mains in [("fund", 55, 65, 60.0),
                                ("harm", 115, 125, 120.0)]:
        fb, sb, pk, snr = spectrum_peak(x, fs, lo, hi)
        print(f"  {name}: peak {pk:.4f} Hz raw "
              f"({pk*chain_scale:.4f} corrected), band SNR {snr:.0f}")
        plot_band(fb, sb, pk, mains,
                  f"Hyper Duel PCB recording, {t1-t0:.0f}s quiet window: "
                  f"{'vertical rate' if name=='fund' else '2nd harmonic'}",
                  f"{OUT}/spectrum_{name}_{tag}.png", chain_scale)

    # isolated, audible hum: both bands, normalized. 4th-order zero-phase
    # Butterworth; nothing else is done to the signal.
    sos = butter(4, [55, 65], btype="band", fs=fs, output="sos")
    sos2 = butter(4, [115, 125], btype="band", fs=fs, output="sos")
    iso = sosfiltfilt(sos, x) + sosfiltfilt(sos2, x)
    iso = iso / (np.abs(iso).max() + 1e-12) * 0.85
    wavfile.write(f"{OUT}/hum_isolated_{tag}.wav", fs,
                  (iso * 32767).astype(np.int16))
    print(f"  wrote spectrum_fund/harm_{tag}.png + hum_isolated_{tag}.wav")


if __name__ == "__main__":
    v, a, b, tag = sys.argv[1:5]
    cs = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0
    main(v, float(a), float(b), tag, cs)
