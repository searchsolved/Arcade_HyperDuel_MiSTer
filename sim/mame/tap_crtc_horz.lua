-- Trace hyprduel main-CPU writes to the CRTC horizontal register
-- (0x478890) with the PC of each write, to identify the code doing the
-- 655k locked writes. Prints a per-PC histogram with data-value ranges
-- plus a per-frame-bucket count, then exits at frame 450.
--
-- Usage: mame hyprduel -rompath roms -video none -sound none \
--          -nothrottle -autoboot_script sim/mame/tap_crtc_horz.lua
--
-- Landmines (project memory): pin tap handles in _G; never call
-- screen:frame_number() inside tap callbacks.

local mem  = manager.machine.devices[":maincpu"].spaces["program"]
local cpu  = manager.machine.devices[":maincpu"]
local screen = manager.machine.screens[":screen"]

local by_pc = {}       -- pc -> {count, min, max, first, last}
local total = 0
local frame_counts = {}  -- frame bucket (n//30) -> writes in bucket
local cur_bucket = 0

_G._horz_tap = mem:install_write_tap(0x478890, 0x478891, "horz_tap",
  function(offset, data, mask)
    total = total + 1
    local pc = cpu.state["CURPC"].value
    local e = by_pc[pc]
    if e == nil then
      by_pc[pc] = {count = 1, min = data, max = data, first = data, last = data}
    else
      e.count = e.count + 1
      if data < e.min then e.min = data end
      if data > e.max then e.max = data end
      e.last = data
    end
    frame_counts[cur_bucket] = (frame_counts[cur_bucket] or 0) + 1
  end)

local n = 0
emu.register_frame_done(function()
  n = n + 1
  cur_bucket = math.floor(n / 30)
  if n == 450 then
    print(string.format("HORZTAP total=%d", total))
    local pcs = {}
    for pc in pairs(by_pc) do pcs[#pcs + 1] = pc end
    table.sort(pcs, function(a, b) return by_pc[a].count > by_pc[b].count end)
    for i = 1, math.min(#pcs, 12) do
      local pc = pcs[i]
      local e = by_pc[pc]
      print(string.format("HORZTAP pc=%06x count=%d min=%04x max=%04x first=%04x last=%04x",
        pc, e.count, e.min, e.max, e.first, e.last))
    end
    local buckets = {}
    for b in pairs(frame_counts) do buckets[#buckets + 1] = b end
    table.sort(buckets)
    for _, b in ipairs(buckets) do
      print(string.format("HORZTAP frames %d-%d: %d writes",
        b * 30, b * 30 + 29, frame_counts[b]))
    end
    manager.machine:exit()
  end
end)
