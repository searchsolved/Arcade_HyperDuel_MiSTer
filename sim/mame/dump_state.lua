-- Dump I4220 state + screenshot at chosen frames of a running hyprduel.
--
-- Usage:
--   DUMP_DIR=<outdir> DUMP_FRAMES=500,900,1500 mame hyprduel \
--     -rompath roms -video none -sound none -nothrottle \
--     -autoboot_script sim/mame/dump_state.lua
--
-- Writes per frame: <outdir>/frame_<N>/{vram0,vram1,vram2,palette,
-- spriteram,tiletable}.bin (little-endian u16), regs.txt, snap.png.
--
-- screen_ctrl (0x4788AC) is write-only on the bus, so it is captured with
-- a write tap; all other registers are read back directly.

local outdir = os.getenv("DUMP_DIR") or "build/mame"
local frames_env = os.getenv("DUMP_FRAMES") or "600"
local targets = {}
for f in string.gmatch(frames_env, "([^,]+)") do
  targets[tonumber(f)] = true
end

local mem = manager.machine.devices[":maincpu"].spaces["program"]
local screen = manager.machine.screens[":screen"]

local screen_ctrl = 0
local tap = mem:install_write_tap(0x4788ac, 0x4788ad, "ctrl_tap",
  function(offset, data, mask)
    screen_ctrl = data
  end)

local function dump_range(path, first, last)
  local f = assert(io.open(path, "wb"))
  -- u16 values packed in host byte order (LE); step 2 = aligned words
  f:write(mem:read_range(first, last, 16, 2))
  f:close()
end

local function r16(a) return mem:read_u16(a) end

local function dump_frame(n)
  local d = string.format("%s/frame_%d", outdir, n)
  os.execute(string.format("mkdir -p '%s'", d))

  dump_range(d .. "/vram0.bin",     0x400000, 0x41ffff)
  dump_range(d .. "/vram1.bin",     0x420000, 0x43ffff)
  dump_range(d .. "/vram2.bin",     0x440000, 0x45ffff)
  dump_range(d .. "/palette.bin",   0x472000, 0x473fff)
  dump_range(d .. "/spriteram.bin", 0x474000, 0x474fff)
  dump_range(d .. "/tiletable.bin", 0x478000, 0x4787ff)

  local f = assert(io.open(d .. "/regs.txt", "w"))
  f:write(string.format("sprite_count=0x%x\n",      r16(0x479700)))
  f:write(string.format("sprite_priority=0x%x\n",   r16(0x479702)))
  f:write(string.format("sprite_yoffset=0x%x\n",    r16(0x479704)))
  f:write(string.format("sprite_xoffset=0x%x\n",    r16(0x479706)))
  f:write(string.format("sprite_color_code=0x%x\n", r16(0x479708)))
  f:write(string.format("layer_priority=0x%x\n",    r16(0x479710)))
  f:write(string.format("background_color=0x%x\n",  r16(0x479712)))
  f:write(string.format("screen_yoffset=0x%x\n",    r16(0x478850)))
  f:write(string.format("screen_xoffset=0x%x\n",    r16(0x478852)))
  f:write(string.format("screen_ctrl=0x%x\n",       screen_ctrl))
  for layer = 0, 2 do
    f:write(string.format("window_y%d=0x%x\n", layer, r16(0x478860 + layer * 4)))
    f:write(string.format("window_x%d=0x%x\n", layer, r16(0x478862 + layer * 4)))
    f:write(string.format("scroll_y%d=0x%x\n", layer, r16(0x478870 + layer * 4)))
    f:write(string.format("scroll_x%d=0x%x\n", layer, r16(0x478872 + layer * 4)))
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
