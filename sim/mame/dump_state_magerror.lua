-- Dump I4220 state + screenshot at chosen frames of a running magerror.
-- Identical to dump_state.lua but with the VDP base at 0x800000 instead
-- of 0x400000 (magerror_map relocates the VDP window).
--
-- Usage:
--   DUMP_DIR=<outdir> DUMP_FRAMES=200,400,600 mame magerror \
--     -rompath roms -video none -sound none -nothrottle \
--     -autoboot_script sim/mame/dump_state_magerror.lua

local outdir = os.getenv("DUMP_DIR") or "build/mame_magerror"
local frames_env = os.getenv("DUMP_FRAMES") or "600"
local targets = {}
for f in string.gmatch(frames_env, "([^,]+)") do
  targets[tonumber(f)] = true
end

local mem = manager.machine.devices[":maincpu"].spaces["program"]
local screen = manager.machine.screens[":screen"]

local screen_ctrl = 0
local tap = mem:install_write_tap(0x8788ac, 0x8788ad, "ctrl_tap",
  function(offset, data, mask)
    screen_ctrl = data
  end)
_G._magerror_tap = tap

local function dump_range(path, first, last)
  local f = assert(io.open(path, "wb"))
  f:write(mem:read_range(first, last, 16, 2))
  f:close()
end

local function r16(a) return mem:read_u16(a) end

local function dump_frame(n)
  local d = string.format("%s/frame_%d", outdir, n)
  os.execute(string.format("mkdir -p '%s'", d))

  dump_range(d .. "/vram0.bin",     0x800000, 0x81ffff)
  dump_range(d .. "/vram1.bin",     0x820000, 0x83ffff)
  dump_range(d .. "/vram2.bin",     0x840000, 0x85ffff)
  dump_range(d .. "/palette.bin",   0x872000, 0x873fff)
  dump_range(d .. "/spriteram.bin", 0x874000, 0x874fff)
  dump_range(d .. "/tiletable.bin", 0x878000, 0x8787ff)

  local f = assert(io.open(d .. "/regs.txt", "w"))
  f:write(string.format("sprite_count=0x%x\n",      r16(0x879700)))
  f:write(string.format("sprite_priority=0x%x\n",   r16(0x879702)))
  f:write(string.format("sprite_yoffset=0x%x\n",    r16(0x879704)))
  f:write(string.format("sprite_xoffset=0x%x\n",    r16(0x879706)))
  f:write(string.format("sprite_color_code=0x%x\n", r16(0x879708)))
  f:write(string.format("layer_priority=0x%x\n",    r16(0x879710)))
  f:write(string.format("background_color=0x%x\n",  r16(0x879712)))
  f:write(string.format("screen_yoffset=0x%x\n",    r16(0x878850)))
  f:write(string.format("screen_xoffset=0x%x\n",    r16(0x878852)))
  f:write(string.format("screen_ctrl=0x%x\n",       screen_ctrl))
  for layer = 0, 2 do
    f:write(string.format("window_y%d=0x%x\n", layer, r16(0x878860 + layer * 4)))
    f:write(string.format("window_x%d=0x%x\n", layer, r16(0x878862 + layer * 4)))
    f:write(string.format("scroll_y%d=0x%x\n", layer, r16(0x878870 + layer * 4)))
    f:write(string.format("scroll_x%d=0x%x\n", layer, r16(0x878872 + layer * 4)))
  end
  f:close()

  screen:snapshot(d .. "/snap.png")
  emu.print_info(string.format("dumped frame %d -> %s", n, d))
end

local remaining = 0
for _ in pairs(targets) do remaining = remaining + 1 end

emu.register_frame_done(function()
  local n = screen:frame_number()
  if targets[n] then
    dump_frame(n)
    targets[n] = nil
    remaining = remaining - 1
    if remaining == 0 then
      manager.machine:exit()
    end
  end
end)
