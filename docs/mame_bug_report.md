# MAME bug report (paste-ready)

Post to: https://github.com/mamedev/mame/issues/new
Suggested labels: none (triage will assign)

---

**Title:**

hyprduel: i4220 CRTC vertical register programs the display window (first visible line = 2); the hardcoded visarea shows the game's off-screen work lines

**Body:**

## Summary

Hyper Duel (hyprduel, metro.cpp family, imagetek_i4100 video device) shows 1 to 2 lines of displaced scroll content at the top of the screen during attract mode raster effects (end of the stage 2 demo after the boss "blob" transition, and the stage 6 cloud scene). Real PCBs do not show this (reference longplay: https://www.youtube.com/watch?v=6KcyYm2Ggu0&t=643s and other PCB captures, clean top of screen throughout).

I traced the root cause while developing an FPGA re-implementation of the i4220, and it is not a scroll emulation bug. It is the visible area. The game programs the video chip's vertical display window through the CRTC registers that `imagetek_i4100.cpp` currently latches and ignores (the "CRT Controller, also understand why it needs so many writes before actual parameters" TODO). The programmed window starts at line 2: real hardware displays chip lines 2 to 225, and the game uses lines 0 and 1 as an off-screen work area. MAME's driver hardcodes `set_visarea(0, 320-1, 0, 223)`, so it displays two lines the game legitimately fills with scratch data.

Observed in 0.288; the relevant device and driver code are unchanged in current master.

## The CRTC register decode

Writes to 0x78880 (`crtc_vert_w`) are indexed parameter writes: parameter number in the high byte, value in the low byte. They only occur inside an unlock bracket (0x788A0 = 1, then the parameter writes, then 0x788A0 = 0).

Full write trace from power-on (deterministic emulator-side trace of boot plus the first attract demo). The game programs the block at two boot/title transitions and once more immediately before the raster-heavy attract demo:

```
frame vpos  addr    data   (frame/vpos = frames and lines after power-on)
104   248   78880   00DB \
104   248   78880   02EF  | transitional set, written 3x
104   248   78880   04F2  | (also at vpos 249, 250)
104   248   78880   0700 /
104   251   78880   00DF \
104   251   78880   02E9  | final set, remains for all gameplay
104   251   78880   04F0  | and attract raster scenes
104   251   78880   0702 /
329   ...           (same sequence again at the title transition)
1317  138   78880   00DF, 02E9
1317  139   78880   04F0, 0702   (re-armed just before the raster demo)
```

Decoding the final set as {param, value}: param 0 = 0xDF (223), param 2 = 0xE9 (233), param 4 = 0xF0 (240), param 7 = 0x02 (2).

Reading these as vertical timing for a 261-line frame:

- param 7 = 2 = first visible line
- param 0 = 223 = active span (224 lines, so active = lines 2 to 225)
- param 2 = 233 = vsync start
- param 4 = 240 = vsync end

The sync placement corroborates the decode independently: with active video on lines 2 to 225 of a 261-line frame, front porch 226 to 232, sync 233 to 239, back porch 240 to 260 is exactly standard NTSC-style vertical timing. The transitional set (0, 219, 239, 242) appears only during boot fades.

## What lives on the hidden lines

The game treats lines 0 and 1 as scratch space, which is what makes the wrong visarea visible:

- Across vblank the scroll registers hold a working accumulator that advances without bound (measured 7 to 12 px per frame in the cloud scenes). Its value lands on the top lines before the per-line raster program overwrites it.
- During the stage 2 boss transition the per-line raster program parks a per-frame outlier value on line 1: measured jumps of up to 191 px between the line 1 value and both neighbours, every frame for about 5 seconds. On hardware that stripe is never displayed. In MAME it is the artifact at the top of the screen.
- Pixel-exact frame differencing of MAME output in the cloud scene shows the top rows scrolling at 3 and 12 px per frame while the sky beneath moves at 1 px per frame: those rows are the work area, not the picture.

## The "so many writes" half of the TODO

The huge volume of writes that prompted the TODO comment goes to the horizontal register with the lock engaged. In the same power-on trace: 655,405 writes to 0x78890, all while `m_crtc_unlock` is 0, concentrated in boot-time busy loops, and zero during the attract raster demo. They are no-ops on hardware (consistent with PCB footage showing no geometric response). Only the unlock-bracketed writes carry programming.

## Verification

I implemented the decoded window in the FPGA re-implementation: raster row R displays chip line R + 2 and the render range extends to line 225. Results:

- Before the game programs the window (first ~100 frames), output is bit-identical to the previous build.
- After, output is exactly the previous build shifted by two lines (zero differing pixels on all comparable rows).
- The top-of-screen artifacts (boss stripe, cloud strip) are gone, verified on a CRT against the PCB footage. Nothing else changes.

## Suggested fix

Decode the indexed parameter writes in `crtc_vert_w` (and presumably `crtc_horz_w` for the horizontal equivalents) and drive the screen's visible area from param 7 and param 0 instead of the driver's hardcoded `FIRST_VISIBLE_LINE 0` / `LAST_VISIBLE_LINE 223`.

Related: the driver's `screen.set_refresh_hz(60)` is commented "Unknown/Unverified". I measured the real board's refresh at 60.24 Hz using three independent methods that agree, on two different PCB recordings: crystal-locked music tempo as the timebase anchor (the YM2151 is clocked by the photographed 4 MHz crystal, so fitting the recording's tune tempo against crystal-exact emulation calibrates each capture chain to ~200 ppm), frame-counted script intervals (a 248-frame game constant between the title jingle key-on and the announcer trigger plays 0.33 percent faster on both hardware recordings than a 60.011 Hz emulation; the two independent recordings agree to 0.007 percent), and the board's own vertical-rate electrical pickup present in the recordings as a narrow spectral line.

The pickup evidence is attached. The high-resolution spectrum of an 11-second quiet window resolves TWO peaks side by side: real mains hum at exactly 120.00 Hz, and the board's line at 120.48 Hz, about 15 dB stronger. The mains peak sitting precisely at 120.00 in the same spectrum demonstrates the chain's frequency axis is accurate at that exact point, so the 120.48 line cannot be mislabeled mains; in the bandpass-isolated audio the two sources are audible beating against each other at about 0.5 Hz. 60.24 Hz is consistent with a 424 x 261 raster at 26.666 MHz / 4:

```
screen.set_raw(XTAL(26'666'000) / 4, 424, 0, 320, 261, 2, 226);
```

which would fix the refresh rate and the visible area together. Note 26,666,000 / 4 / (424 * 261) = 60.2408 Hz.

Since imagetek_i4100 is shared across the metro.cpp family, other titles presumably program their own windows through the same registers; their values should be dumped before changing any shared defaults, but for hyprduel the programming above is stable across boot, attract and gameplay.

Additional corroboration from the game's own behavior: it services exactly 261 raster interrupt lines per frame; the 262nd line the current totals assume was never addressed by the game, because it does not exist on hardware.

Attached: the two hum spectra (fundamental and second harmonic, mains position marked) and the bandpass-isolated hum audio (zipped WAV). Full register write traces (CSV) and the remaining measurement data available on request.

---

Notes for Lee (not part of the issue):
- Post at: https://github.com/mamedev/mame/issues/new (plain issue).
- Drag these three files into the issue body as attachments (all in
  docs/evidence/refresh/): spectrum_harm_videoA.png,
  spectrum_fund_videoA.png, hum_isolated_videoA.zip.
- The "frame/vpos" numbers come from our deterministic sim boot; they are stable across runs and stated as such.
- MAME version claim: artifacts confirmed in 0.288 on this machine; device/driver code confirmed unchanged in master today.
- If they ask for the FPGA implementation, the core is pre-release; share at your discretion (public release imminent anyway).
