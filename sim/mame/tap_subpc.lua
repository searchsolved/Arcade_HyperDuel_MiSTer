-- Sample the sub CPU's PC and SR once per frame to see what it does after
-- the YM2151 traffic stops (audio bug diagnosis). Prints every 10th frame
-- plus a fine window around TAP_FOCUS (default 120-140).
--
-- Usage:
--   TAP_FRAMES=470 mame hyprduel -rompath roms -video none -sound none \
--     -nothrottle -skip_gameinfo -autoboot_script sim/mame/tap_subpc.lua

local total_frames = tonumber(os.getenv("TAP_FRAMES") or "470")
local focus_lo = tonumber(os.getenv("TAP_FOCUS_LO") or "120")
local focus_hi = tonumber(os.getenv("TAP_FOCUS_HI") or "145")

local screen = manager.machine.screens[":screen"]
local sub = manager.machine.devices[":sub"]
local main = manager.machine.devices[":maincpu"]

local function reg(dev, name)
  local e = dev.state[name]
  if e then return e.value end
  return -1
end

emu.register_frame_done(function()
  local n = screen:frame_number()
  if n % 10 == 0 or (n >= focus_lo and n <= focus_hi) then
    print(string.format("PCS %d sub_pc=%06x sub_sr=%04x main_pc=%06x",
                        n, reg(sub, "PC"), reg(sub, "CUR_SR") ~= -1
                          and reg(sub, "CUR_SR") or reg(sub, "SR"),
                        reg(main, "PC")))
  end
  if n >= total_frames then manager.machine:exit() end
end)
