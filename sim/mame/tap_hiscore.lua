-- Hunt the real hiscore table: start a game, idle to game over, and
-- watch when/where score data lands in RAM.
-- Logs: (a) the hiscore.dat region fff2a2-fff2e2 whenever it changes,
-- (b) full work-RAM scans for the default top score 1540613 in BCD.
-- Run: mame hyprduel -rompath ../../roms -video none -sound none \
--        -nothrottle -autoboot_script tap_hiscore.lua -seconds_to_run 600
local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local sys = machine.ioport.ports[":SYSTEM"]
local start1 = nil
for _, f in pairs(sys.fields) do
  if f.name == "1 Player Start" or f.mask == 0x10 then start1 = f end
end

local last_region = ""
local pressed = false
local frame = 0

local function region_hex()
  local t = {}
  for a = 0xfff2a2, 0xfff2e2 do t[#t+1] = string.format("%02x", mem:read_u8(a)) end
  return table.concat(t, " ")
end

local function scan_bcd()
  -- look for 01 54 06 13 and 15 40 61 anywhere in fe4000-ffffff
  local hits = {}
  for a = 0xfe4000, 0xffffff - 4 do
    local b0, b1, b2, b3 = mem:read_u8(a), mem:read_u8(a+1), mem:read_u8(a+2), mem:read_u8(a+3)
    if (b0 == 0x01 and b1 == 0x54 and b2 == 0x06 and b3 == 0x13) or
       (b0 == 0x15 and b1 == 0x40 and b2 == 0x61) then
      hits[#hits+1] = string.format("%06x: %02x %02x %02x %02x", a, b0, b1, b2, b3)
    end
  end
  return hits
end

emu.register_frame_done(function()
  frame = frame + 1
  -- press start at 10s (free play is set via -dipswitch? default coinage:
  -- just insert a coin first at 8s to be safe, then start)
  -- lua field:set_value(1) = pressed, set_value(0) = released
  if frame == 480 then
    for _, f in pairs(sys.fields) do if f.mask == 0x01 then f:set_value(1) end end
  end
  if frame == 484 then
    for _, f in pairs(sys.fields) do if f.mask == 0x01 then f:set_value(0) end end
  end
  if frame == 600 and start1 then start1:set_value(1) end
  if frame == 604 and start1 then start1:set_value(0) end

  -- watch the dat region for changes (cheap, every frame)
  local r = region_hex()
  if r ~= last_region then
    print(string.format("REGION f=%d t=%.1f: %s", frame, emu.time(), r))
    last_region = r
  end
  -- full scan every 10 seconds
  if frame % 600 == 0 then
    local hits = scan_bcd()
    print(string.format("SCAN f=%d hits=%d", frame, #hits))
    for _, h in ipairs(hits) do print("  " .. h) end
  end
end)
