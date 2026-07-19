# Release announcement (paste-ready drafts)

## GitHub release notes (attach to the tagged release)

**Hyper Duel for MiSTer - first release**

First FPGA implementation of the Imagetek I4220 video chip, running
Technosoft's Hyper Duel (1993). Playable start to finish, verified
against MAME frame by frame and against real hardware beyond that.

Features:
- High score autosave
- Native 60.24 Hz video timing, measured from real PCBs (60 Hz compat
  option in the OSD for strict displays)
- The real display window: the game programs the chip to show lines
  2-225, and this core honours it. Two lines of real picture at the
  bottom that emulation has always cropped, and none of the scratch
  lines emulation has always wrongly shown at the top.
- OKI sample pitch from the measured 2.000 MHz clock and the mix
  balance measured from PCB recordings
- DIP switches from the OSD including Free Play; boot warning skip
  option

Requires the MAME `hyprduel` ROM set (0.288 naming) loaded through the
included MRA. A second MRA covers the `hyprduel2` alternate revision.
No ROM data is included.

Accuracy methodology, evidence and honest limitations: docs/ACCURACY.md
in the repo. The research findings (display window programming, refresh
rate, OKI clock, mix balance, interrupt cadence) are written up there
with reproduction steps, and an upstream report for MAME is included.

## Forum/Discord post

Hyper Duel (Technosoft, 1993) is now available for MiSTer. This one is
the first FPGA implementation of any Imagetek video chip (the I4220;
the same family drives the whole Metro arcade catalogue), built from
MAME's reverse engineering as the starting oracle and then verified
against real hardware: board photographs for the clock tree and bus
widths, and original-PCB recordings analysed down to individual
scanlines and spectral lines.

Some things came out of the verification work that were not previously
documented anywhere:

- The board runs at 60.24 Hz, not 60 Hz. Measured three independent
  ways from two PCB recordings, including the board's own vertical-rate
  electrical hum picked up in the audio. The core ships this timing
  natively with a 60 Hz compat option.
- The CRTC registers MAME logs and ignores turn out to program the
  visible display window. Hyper Duel asks for lines 2-225, and uses the
  two lines above it as hidden scratch space. Every version of the
  well-known top-of-screen scroll glitch in emulation of this game is
  that scratch space being displayed. The core implements the window,
  and a report with the register decode has been prepared for MAME.
- The OKI sample clock is 2.000 MHz (emulation's unverified value is
  about 3 percent sharp), and the sample-to-music balance on real
  boards is substantially hotter than emulation plays it.

The renderer is line-budget-proven (zero missed scanlines across long
stress simulations; the real board's slowdown reproduces for free from
cycle-accurate CPUs). High score autosave, OSD DIPs with Free Play,
and both ROM revisions are supported via MRA.

Credits where they are absolutely due: MAME's Imagetek reverse
engineering (Luca Elia, David Haywood, Angelo Salese and contributors)
is the foundation this stands on; Jorge Cwik's fx68k and Jose Tejada's
jt51/jt6295 provide the CPUs and sound; the MiSTer framework carries
it all. Board photography by Stefan Lindberg and the original-PCB
recording by STG cvlt made the hardware verification possible.

The full simulation and verification harness ships in the repo, so
every accuracy claim is reproducible. The I4220 RTL is written to be
reusable: Magical Error wo Sagase shares this exact board and is the
natural next target, and collaborators interested in the wider Metro
family are very welcome.

Repo: [link]  |  Accuracy documentation: docs/ACCURACY.md
