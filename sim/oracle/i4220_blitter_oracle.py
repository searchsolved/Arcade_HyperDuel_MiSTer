#!/usr/bin/env python3
"""I4220 blitter oracle.

Direct port of MAME's imagetek_i4100_device::blitter_w main loop
(imagetek_i4100.cpp:881-1005). Reads a blit scene directory, applies every
blit in order to the three VRAM images, writes vram{0,1,2}.out.hex
(one 4-digit hex word per line, same format the RTL testbench dumps).

Scene layout:
  vram0.bin vram1.bin vram2.bin  initial VRAM (128 KB each)
  gfxrom.bin                     opcode/data streams + tile data
  blits.txt                      one blit per line: <tmap> <src> <dst> (hex)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from i4220_oracle import load_words  # noqa: E402


class BlitterOracle:
    def __init__(self, scene):
        scene = Path(scene)
        self.scene = scene
        self.vram = [load_words(scene / f"vram{i}.bin") for i in range(3)]
        self.gfxrom = Path(scene / "gfxrom.bin").read_bytes()
        self.blits = []
        for line in (scene / "blits.txt").read_text().splitlines():
            line = line.split("#")[0].strip()
            if line:
                tmap, src, dst = (int(v, 16) for v in line.split())
                self.blits.append((tmap, src, dst))

    def blt_write(self, tmap, offs, data, mask):
        if 1 <= tmap <= 3:
            v = self.vram[tmap - 1]
            v[offs] = (v[offs] & ~mask) | (data & mask)

    def run_one(self, tmap, src_offs, dst_offs):
        """Returns True if the blit ran to a stop opcode (-> IRQ)."""
        rom = self.gfxrom
        size = len(rom)

        shift = 0 if (dst_offs & 0x80) else 8
        mask = 0x00FF if (dst_offs & 0x80) else 0xFF00
        col_restore = (dst_offs >> 8) & 0xFF  # (regs[0x0a/2] >> 8) & 0xff

        dst_offs >>= 8
        if tmap not in (1, 2, 3):
            return False

        while True:
            src_offs %= size
            b1 = rom[src_offs]
            src_offs += 1
            count = ((~b1) & 0x3F) + 1
            op = (b1 & 0xC0) >> 6

            if op == 0:
                if b1 == 0:
                    return True  # STOP -> blit done IRQ
                while count:
                    count -= 1
                    src_offs %= size
                    b2 = rom[src_offs] << shift
                    src_offs += 1
                    dst_offs &= 0xFFFF
                    self.blt_write(tmap, dst_offs, b2, mask)
                    dst_offs = ((dst_offs + 1) & 0xFF) | (dst_offs & ~0xFF)
            elif op == 1:  # fill with increasing value
                src_offs %= size
                b2 = rom[src_offs]
                src_offs += 1
                while count:
                    count -= 1
                    dst_offs &= 0xFFFF
                    self.blt_write(tmap, dst_offs, (b2 << shift) & 0xFFFF, mask)
                    dst_offs = ((dst_offs + 1) & 0xFF) | (dst_offs & ~0xFF)
                    b2 = (b2 + 1) & 0xFFFF
            elif op == 2:  # fill with fixed value
                src_offs %= size
                b2 = rom[src_offs] << shift
                src_offs += 1
                while count:
                    count -= 1
                    dst_offs &= 0xFFFF
                    self.blt_write(tmap, dst_offs, b2, mask)
                    dst_offs = ((dst_offs + 1) & 0xFF) | (dst_offs & ~0xFF)
            else:  # op == 3: skip
                if b1 == 0xC0:  # skip to next row, restore column
                    dst_offs += 0x100
                    dst_offs &= ~0xFF
                    dst_offs |= col_restore
                else:
                    dst_offs += count

    def run(self):
        irqs = 0
        for tmap, src, dst in self.blits:
            if self.run_one(tmap, src, dst):
                irqs += 1
        return irqs

    def write_out(self):
        for i in range(3):
            path = self.scene / f"vram{i}.out.hex"
            path.write_text("\n".join("%04x" % w for w in self.vram[i]) + "\n")


if __name__ == "__main__":
    o = BlitterOracle(sys.argv[1])
    irqs = o.run()
    o.write_out()
    (o.scene / "irqs.out").write_text(f"{irqs}\n")
    print(f"blitter-oracle: {len(o.blits)} blits, {irqs} completed with IRQ -> "
          f"{o.scene}/vram*.out.hex")
