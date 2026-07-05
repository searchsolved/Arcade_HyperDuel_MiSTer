#!/usr/bin/env python3
"""Convert tb_system +AUDIODUMP raw s16le mono capture to WAV.

The TB samples o_audio every 2048 sys clocks. sys = pixclk * P_PIXDIV;
at the sim's P_PIXDIV=16 that is 6.6666 MHz * 16 / 2048 = 52083 Hz.

Usage: raw_to_wav.py <in.raw> <out.wav> [rate]
"""
import sys
import wave

inp, outp = sys.argv[1], sys.argv[2]
rate = int(sys.argv[3]) if len(sys.argv) > 3 else 52083

data = open(inp, "rb").read()
if len(data) % 2:
    data = data[:-1]
w = wave.open(outp, "wb")
w.setnchannels(1)
w.setsampwidth(2)
w.setframerate(rate)
w.writeframes(data)
w.close()
print(f"{outp}: {len(data)//2} samples, {len(data)/2/rate:.1f}s at {rate} Hz")
