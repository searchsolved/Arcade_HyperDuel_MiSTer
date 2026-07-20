local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local cur_frame = 0
local nw = 0
_G._sc_tap = mem:install_write_tap(0x4788ac, 0x4788ad, "sc_tap",
  function(offset, data, mask)
    nw = nw + 1
    if nw <= 25 then
      print(string.format("SCRC f=%d pc=%06x data=%04x", cur_frame, cpu.state["CURPC"].value, data))
    end
  end)
local n = 0
emu.register_frame_done(function()
  n = n + 1
  cur_frame = n
  if n == 460 then print(string.format("SCRC done writes=%d", nw)); manager.machine:exit() end
end)
