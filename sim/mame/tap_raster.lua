-- Log every VDP register write with beam position for raster-split analysis.
--
-- Usage:
--   DUMP_DIR=build/mame/raster DUMP_TOTAL=620 mame hyprduel \
--     -rompath roms -video none -sound none -nothrottle \
--     -autoboot_script sim/mame/tap_raster.lua
--
-- Writes: <outdir>/raster_writes.csv
-- Columns: frame, vpos, hpos, addr (hex), data (hex)
-- Pin with _G to prevent GC.

local outdir = os.getenv("DUMP_DIR") or "build/mame/raster"
local total  = tonumber(os.getenv("DUMP_TOTAL") or "620")
local screen = manager.machine.screens[":screen"]
local mem    = manager.machine.devices[":maincpu"].spaces["program"]

os.execute("mkdir -p " .. outdir)
local fh = assert(io.open(outdir .. "/raster_writes.csv", "w"))
fh:write("frame,vpos,hpos,addr,data\n")

local frame_num = 0

-- VDP register space: 0x478800-0x4788FF (write-only control regs)
-- Also capture scroll/window writes at 0x470000-0x47001F
_G._raster_tap1 = mem:install_write_tap(0x478800, 0x4788ff, "vdp_ctrl_tap",
  function(offset, data, mask)
    local v = screen:vpos()
    local h = screen:hpos()
    fh:write(string.format("%d,%d,%d,%06x,%04x\n",
             frame_num, v, h, offset, data))
  end)

_G._raster_tap2 = mem:install_write_tap(0x470000, 0x47001f, "vdp_scroll_tap",
  function(offset, data, mask)
    local v = screen:vpos()
    local h = screen:hpos()
    fh:write(string.format("%d,%d,%d,%06x,%04x\n",
             frame_num, v, h, offset, data))
  end)

_G._raster_frame = emu.add_machine_frame_notifier(function()
  frame_num = frame_num + 1
  if frame_num > total then
    fh:close()
    print(string.format("raster: done, %d frames logged", total))
    manager.machine:exit()
  end
end)

print(string.format("raster: logging VDP writes for %d frames into %s",
                     total, outdir))
