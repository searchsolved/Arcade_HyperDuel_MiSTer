-- Third pass: log every write to the CRTC unlock register (0x4788A0)
-- with PC, and sample the unlock state seen by the 0x86xx delay-loop
-- writes (first 3 and every 100000th), to establish the true bracket
-- structure around the 655k writes.

local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]

local unlock = 0xDEAD
local cur_frame = 0
local nloop = 0

_G._unlock_tap3 = mem:install_write_tap(0x4788a0, 0x4788a1, "unlock_tap3",
  function(offset, data, mask)
    unlock = data
    local pc = cpu.state["CURPC"].value
    print(string.format("UNLK f=%d pc=%06x data=%04x", cur_frame, pc, data))
  end)

_G._horz_tap3 = mem:install_write_tap(0x478890, 0x478891, "horz_tap3",
  function(offset, data, mask)
    local pc = cpu.state["CURPC"].value
    if pc < 0x8700 then
      nloop = nloop + 1
      if nloop <= 3 or nloop % 100000 == 0 then
        print(string.format("LOOPW n=%d f=%d pc=%06x data=%04x unlock=%04x",
          nloop, cur_frame, pc, data, unlock))
      end
    end
  end)

local n = 0
emu.register_frame_done(function()
  n = n + 1
  cur_frame = n
  if n == 450 then
    print(string.format("HORZ3 done loop_writes=%d", nloop))
    manager.machine:exit()
  end
end)
