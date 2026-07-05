-- Oracle tap for the YM2151 audio bug (docs/audio_bug_ym_irq_storm.md step 2).
-- Logs every sub-CPU access to the YM2151 ports (0x400000-0x400003) for the
-- first TAP_FRAMES frames of hyprduel, building the same statistics the
-- Verilator tb_system probes produce, so the two can be diffed directly.
--
-- Usage:
--   TAP_OUT=<file> TAP_FRAMES=470 mame hyprduel -rompath roms \
--     -video none -sound none -nothrottle -seconds_to_run 20 \
--     -autoboot_script sim/mame/tap_ym.lua
--
-- Output (text): histogram per register (count, last value, first frame),
-- distinct reg-0x14 values, status-read stats, first 200 (reg,val) pairs,
-- and the first 50 key-on (reg 0x08) writes with frame numbers.

local outpath = os.getenv("TAP_OUT") or "build/mame/ym_tap.txt"
local total_frames = tonumber(os.getenv("TAP_FRAMES") or "470")

local sub = manager.machine.devices[":sub"].spaces["program"]
local screen = manager.machine.screens[":screen"]

local frame_now = 0
local hist, lastv, ffirst, flast = {}, {}, {}, {}
local tailseq, tail_idx = {}, 0
local ctl, ctl_n = {}, 0
local r14_vals = {}
local seq, seq_n = {}, 0
local kon, kon_n = {}, 0
local cur_reg = -1
local wr_bytes = 0
local st_reads, st_flagA, st_flagB, st_busy = 0, 0, 0, 0
local st_last, st_lidx = {}, 0

local wtap = sub:install_write_tap(0x400000, 0x400003, "ym_wtap",
  function(offset, data, mask)
    local val = data & 0xff
    wr_bytes = wr_bytes + 1
    if offset < 0x400002 then
      cur_reg = val
    elseif cur_reg >= 0 then
      hist[cur_reg] = (hist[cur_reg] or 0) + 1
      lastv[cur_reg] = val
      if ffirst[cur_reg] == nil then ffirst[cur_reg] = frame_now end
      flast[cur_reg] = frame_now
      tail_idx = tail_idx + 1
      tailseq[(tail_idx - 1) % 40 + 1] =
        string.format("%d %02x %02x", frame_now, cur_reg, val)
      if seq_n < 200 then
        seq_n = seq_n + 1
        seq[seq_n] = string.format("%d %02x %02x", frame_now, cur_reg, val)
      end
      if cur_reg == 0x14 then r14_vals[val] = true end
      if cur_reg == 0x08 and kon_n < 50 then
        kon_n = kon_n + 1
        kon[kon_n] = string.format("%d %02x", frame_now, val)
      end
    end
  end)

local okiw, okiw_n = {}, 0
local otap = sub:install_write_tap(0x400004, 0x400005, "oki_wtap",
  function(offset, data, mask)
    if okiw_n < 50 then
      okiw_n = okiw_n + 1
      okiw[okiw_n] = string.format("%d %02x", frame_now, data & 0xff)
    end
  end)

-- NOTE: do not tap maincpu 0x800000 (subcpu_control_w) - MAME 0.288
-- segfaults when that handler (spin_until_interrupt inside) is wrapped.
local rtap = sub:install_read_tap(0x400000, 0x400003, "ym_rtap",
  function(offset, data, mask)
    local val = data & 0xff
    st_reads = st_reads + 1
    st_lidx = st_lidx + 1
    st_last[(st_lidx - 1) % 16 + 1] = val
    if (val & 0x01) ~= 0 then st_flagA = st_flagA + 1 end
    if (val & 0x02) ~= 0 then st_flagB = st_flagB + 1 end
    if (val & 0x80) ~= 0 then st_busy = st_busy + 1 end
  end)

-- Pin the tap handles globally: MAME removes a tap when its handle is
-- garbage collected, and locals go out of scope when the autoboot script
-- returns (this silently killed all taps around frame ~130 before).
_G.pinned_taps = { wtap, otap, rtap }

emu.register_frame_done(function()
  frame_now = screen:frame_number()
  if frame_now < total_frames then return end
  local f = assert(io.open(outpath, "w"))
  f:write(string.format("frames=%d wr_bytes=%d\n", total_frames, wr_bytes))
  f:write(string.format("status reads=%d flagA_set=%d flagB_set=%d busy_set=%d\n",
                        st_reads, st_flagA, st_flagB, st_busy))
  f:write("status last16:")
  for i = 1, 16 do
    local v = st_last[(st_lidx + i - 1) % 16 + 1]
    if v then f:write(string.format(" %02x", v)) end
  end
  f:write("\n")
  f:write("ym reg histogram (reg count lastval firstframe lastframe):\n")
  for r = 0, 255 do
    if hist[r] then
      f:write(string.format("  HIST %02x %d %02x %d %d\n",
                            r, hist[r], lastv[r], ffirst[r], flast[r]))
    end
  end
  f:write("last 40 writes (frame reg val):\n")
  for i = 1, math.min(tail_idx, 40) do
    f:write("  TAIL " .. tailseq[(tail_idx + i - 1) % 40 + 1] .. "\n")
  end
  f:write("subctl writes (frame val):\n")
  for i = 1, ctl_n do f:write("  CTL " .. ctl[i] .. "\n") end
  f:write("reg14 distinct values:")
  for v = 0, 255 do
    if r14_vals[v] then f:write(string.format(" %02x", v)) end
  end
  f:write("\n")
  f:write("first 200 writes (frame reg val):\n")
  for i = 1, seq_n do f:write("  SEQ " .. seq[i] .. "\n") end
  f:write("first 50 keyon writes (frame val):\n")
  for i = 1, kon_n do f:write("  KON " .. kon[i] .. "\n") end
  f:write("first 50 oki writes (frame val):\n")
  for i = 1, okiw_n do f:write("  OKI " .. okiw[i] .. "\n") end
  f:close()
  emu.print_info("ym tap written to " .. outpath)
  manager.machine:exit()
end)
