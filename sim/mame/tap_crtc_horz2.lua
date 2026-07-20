-- Follow-up: for the NON-delay-loop writes to 0x478890 (constants from
-- the 0x87xx/0x88xx routines), capture the CRTC unlock state (last value
-- written to 0x4788A0) at the moment of each write, plus a frame stamp
-- maintained outside the tap (frame_number() inside taps segfaults).

local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]

local unlock = 0
local cur_frame = 0
local lines = 0

_G._unlock_tap = mem:install_write_tap(0x4788a0, 0x4788a1, "unlock_tap",
  function(offset, data, mask)
    unlock = data
  end)

_G._horz_tap2 = mem:install_write_tap(0x478890, 0x478891, "horz_tap2",
  function(offset, data, mask)
    local pc = cpu.state["CURPC"].value
    if pc >= 0x8700 then   -- skip the 0x86xx delay loop
      lines = lines + 1
      if lines <= 60 then
        print(string.format("HORZ2 f=%d pc=%06x data=%04x unlock=%04x",
          cur_frame, pc, data, unlock))
      end
    end
  end)

-- also log vertical writes for interleaving context
_G._vert_tap = mem:install_write_tap(0x478880, 0x478881, "vert_tap",
  function(offset, data, mask)
    local pc = cpu.state["CURPC"].value
    print(string.format("VERT2 f=%d pc=%06x data=%04x unlock=%04x",
      cur_frame, pc, data, unlock))
  end)

local n = 0
emu.register_frame_done(function()
  n = n + 1
  cur_frame = n
  if n == 450 then
    print(string.format("HORZ2 done nonloop_writes=%d", lines))
    manager.machine:exit()
  end
end)
