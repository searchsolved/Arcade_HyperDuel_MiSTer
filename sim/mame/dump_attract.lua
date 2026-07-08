-- Dump a screenshot every DUMP_EVERY frames for DUMP_TOTAL frames.
-- Used for lockstep attract-parity testing against the sim's PPM output.
--
-- Usage:
--   DUMP_DIR=build/mame/attract DUMP_EVERY=30 DUMP_TOTAL=620 \
--     mame hyprduel -rompath roms -video none -sound none -nothrottle \
--     -autoboot_script sim/mame/dump_attract.lua
--
-- Writes: <outdir>/mame_<N>.png for each dumped frame (N = frame number).
-- Frame count starts from 0 at the first vsync after boot.
-- Pin all handles with _G to prevent Lua GC from eating taps/callbacks.

local outdir    = os.getenv("DUMP_DIR") or "build/mame/attract"
local every     = tonumber(os.getenv("DUMP_EVERY") or "30")
local total     = tonumber(os.getenv("DUMP_TOTAL") or "620")
local screen    = manager.machine.screens[":screen"]
local frame_num = 0

os.execute("mkdir -p " .. outdir)

_G._attract_cb = emu.add_machine_frame_notifier(function()
  if frame_num <= total then
    if frame_num % every == 0 then
      local path = string.format("%s/mame_%04d.png", outdir, frame_num)
      screen:snapshot(path)
      print(string.format("attract: dumped frame %d -> %s", frame_num, path))
    end
    frame_num = frame_num + 1
    if frame_num > total then
      print(string.format("attract: done, %d frames", total))
      manager.machine:exit()
    end
  end
end)

print(string.format("attract: dumping every %d frames up to %d into %s",
                     every, total, outdir))
