-- Log every VDP register write with beam position for raster-split analysis.
--
-- Usage:
--   DUMP_DIR=build/mame/raster DUMP_TOTAL=620 mame hyprduel \
--     -rompath ../roms -video none -sound none -nothrottle \
--     -autoboot_script mame/tap_raster.lua
--
-- Writes: <outdir>/raster_writes.csv
-- Columns: frame, vpos, hpos, addr (hex), data (hex)
--
-- MAME 0.288 GOTCHA: screen:vpos()/hpos()/frame_number() FAULT when
-- called inside a write-tap callback (probe-verified: 52384/52384 vpos
-- calls errored, which is why v1 of this script logged zero rows).
-- Beam position is instead derived from machine.time (tap-safe,
-- probe-verified) relative to the frame notifier, where screen:vpos()
-- IS safe and anchors the line base. attotime.attoseconds is the
-- SUB-SECOND part only; combine with .seconds for deltas.

local outdir = os.getenv("DUMP_DIR") or "build/mame/raster"
local total  = tonumber(os.getenv("DUMP_TOTAL") or "620")
local machine = manager.machine
local screen  = machine.screens[":screen"]
local mem     = machine.devices[":maincpu"].spaces["program"]

os.execute("mkdir -p " .. outdir)
local fh = assert(io.open(outdir .. "/raster_writes.csv", "w"))
fh:write("frame,vpos,hpos,addr,data\n")

local V_TOTAL, H_TOTAL = 262, 424
local frame_num = 0
local t0_s, t0_as = 0, 0     -- machine time at last frame notifier
local line_as = 0            -- line period in attoseconds (measured)
local vbase = 0              -- vpos at notifier time

local function log_write(offset, data)
  if line_as == 0 then return end          -- need one full frame to calibrate
  local t = machine.time
  local dt = (t.seconds - t0_s) * 1e18 + (t.attoseconds - t0_as)
  local lines = math.floor(dt / line_as)
  local h = math.floor((dt - lines * line_as) / line_as * H_TOTAL)
  local v = (vbase + lines) % V_TOTAL
  fh:write(string.format("%d,%d,%d,%06x,%04x\n", frame_num, v, h, offset, data))
end

-- VDP control/scroll/window register space (0x478800-0x4788FF)
_G._raster_tap1 = mem:install_write_tap(0x478800, 0x4788ff, "vdp_ctrl_tap",
  function(offset, data, mask) log_write(offset, data) end)

-- 0x479700 register mirror (spr count/pri/offsets, layer pri, bg)
_G._raster_tap2 = mem:install_write_tap(0x479700, 0x47971f, "vdp_mirr_tap",
  function(offset, data, mask) log_write(offset, data) end)

local prev_s, prev_as = nil, nil
_G._raster_frame = emu.add_machine_frame_notifier(function()
  -- NOTE: screen:vpos() errors in THIS context too (it silently killed
  -- the frame counter in an earlier version). The notifier fires at a
  -- constant beam position, so vpos here is a constant unknown: leave
  -- vbase = 0 and let diff_raster.py calibrate the constant line offset
  -- between the two logs.
  local t = machine.time
  if prev_s then
    line_as = math.floor(((t.seconds - prev_s) * 1e18
                          + (t.attoseconds - prev_as)) / V_TOTAL)
  end
  prev_s, prev_as = t.seconds, t.attoseconds
  t0_s, t0_as = t.seconds, t.attoseconds
  frame_num = frame_num + 1
  if frame_num > total then
    fh:close()
    print(string.format("raster: done, %d frames logged", total))
    machine:exit()
  end
end)

print(string.format("raster: logging VDP writes for %d frames into %s",
                    total, outdir))
