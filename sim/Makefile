# M1/M2 verification loops: oracle vs SV, diffed per scene.
SCENES     := scene1 scene2 scene3 scene4
BLITSCENES := blit1 blit2
NBLITS     := 24
BUILD      := build
VERILATOR ?= verilator

.PHONY: all scenes model verify blit-verify clean

all: verify blit-verify

$(BUILD)/scenes.stamp: oracle/make_scene.py oracle/i4220_oracle.py
	mkdir -p $(BUILD)
	cd oracle && python3 make_scene.py ../$(BUILD)/scenes
	touch $@

scenes: $(BUILD)/scenes.stamp

$(BUILD)/obj_dir/Vi4220_model: tb/i4220_model.sv
	$(VERILATOR) --binary -Wall -Wno-UNUSEDSIGNAL -Wno-BLKSEQ \
		--Mdir $(BUILD)/obj_dir tb/i4220_model.sv --top-module i4220_model
model: $(BUILD)/obj_dir/Vi4220_model

verify: scenes model
	@fail=0; \
	for s in $(SCENES); do \
	  echo "=== $$s ==="; \
	  python3 oracle/i4220_oracle.py $(BUILD)/scenes/$$s $(BUILD)/$$s.oracle.ppm; \
	  $(BUILD)/obj_dir/Vi4220_model +SCENE=$(BUILD)/scenes/$$s +OUT=$(BUILD)/$$s.rtl.ppm; \
	  python3 diff_ppm.py $(BUILD)/$$s.oracle.ppm $(BUILD)/$$s.rtl.ppm || fail=1; \
	done; \
	exit $$fail

$(BUILD)/blitscenes.stamp: oracle/make_blit_scene.py
	mkdir -p $(BUILD)
	cd oracle && python3 make_blit_scene.py ../$(BUILD)/blitscenes
	touch $@

$(BUILD)/obj_blit/Vtb_blitter: tb/tb_blitter.sv ../rtl/i4220_blitter.sv
	$(VERILATOR) --binary --timing -Wall -Wno-UNUSEDSIGNAL --timescale 1ns/1ps \
		--Mdir $(BUILD)/obj_blit ../rtl/i4220_blitter.sv tb/tb_blitter.sv \
		--top-module tb_blitter

blit-verify: $(BUILD)/blitscenes.stamp $(BUILD)/obj_blit/Vtb_blitter
	@fail=0; \
	for s in $(BLITSCENES); do \
	  echo "=== $$s ==="; \
	  python3 oracle/i4220_blitter_oracle.py $(BUILD)/blitscenes/$$s; \
	  mkdir -p $(BUILD)/$$s.rtl; \
	  $(BUILD)/obj_blit/Vtb_blitter +SCENE=$(BUILD)/blitscenes/$$s \
	      +NBLITS=$(NBLITS) +OUTDIR=$(BUILD)/$$s.rtl; \
	  for l in 0 1 2; do \
	    python3 diff_hex.py $(BUILD)/blitscenes/$$s/vram$$l.out.hex \
	        $(BUILD)/$$s.rtl/vram$$l.out.hex || fail=1; \
	  done; \
	  if ! cmp -s $(BUILD)/blitscenes/$$s/irqs.out $(BUILD)/$$s.rtl/irqs.out; then \
	    echo "FAIL: IRQ count differs: oracle=$$(cat $(BUILD)/blitscenes/$$s/irqs.out) rtl=$$(cat $(BUILD)/$$s.rtl/irqs.out)"; fail=1; \
	  else echo "PASS: IRQ count $$(cat $(BUILD)/$$s.rtl/irqs.out)"; fi; \
	done; \
	exit $$fail

$(BUILD)/obj_render/Vtb_render: tb/tb_render.sv ../rtl/i4220_render.sv
	$(VERILATOR) --binary --timing -Wall -Wno-UNUSEDSIGNAL --timescale 1ns/1ps \
		--Mdir $(BUILD)/obj_render ../rtl/i4220_render.sv tb/tb_render.sv \
		--top-module tb_render

# real scanline RTL vs oracle on the synthetic scenes
render-verify: $(BUILD)/scenes.stamp $(BUILD)/obj_render/Vtb_render
	@fail=0; \
	for s in $(SCENES); do \
	  echo "=== render $$s ==="; \
	  [ -f $(BUILD)/$$s.oracle.ppm ] || python3 oracle/i4220_oracle.py $(BUILD)/scenes/$$s $(BUILD)/$$s.oracle.ppm; \
	  $(BUILD)/obj_render/Vtb_render +SCENE=$(BUILD)/scenes/$$s \
	      +OUT=$(BUILD)/$$s.render.ppm +GFXSIZE=524288; \
	  python3 diff_ppm.py $(BUILD)/$$s.oracle.ppm $(BUILD)/$$s.render.ppm || fail=1; \
	done; exit $$fail

MAME_FRAMES := 500 900 1500

# real scanline RTL vs real MAME snapshots
mame-verify: $(BUILD)/obj_render/Vtb_render
	@[ -f $(BUILD)/mame/gfxrom.hex ] || python3 -c "import pathlib; \
d=pathlib.Path('$(BUILD)/mame'); \
d.joinpath('gfxrom.hex').write_text('\n'.join('%02x'%b for b in d.joinpath('gfxrom.bin').read_bytes())+'\n')"
	@fail=0; \
	for f in $(MAME_FRAMES); do \
	  echo "=== mame frame $$f ==="; \
	  python3 mame/dump_to_hex.py $(BUILD)/mame/frame_$$f; \
	  ln -sf ../gfxrom.hex $(BUILD)/mame/frame_$$f/gfxrom.hex; \
	  $(BUILD)/obj_render/Vtb_render +SCENE=$(BUILD)/mame/frame_$$f \
	      +OUT=$(BUILD)/mame/frame_$$f/render.ppm +GFXSIZE=4194304; \
	  python3 diff_ppm.py $(BUILD)/mame/frame_$$f/snap.ppm \
	      $(BUILD)/mame/frame_$$f/render.ppm || fail=1; \
	done; exit $$fail

$(BUILD)/obj_vdp/Vtb_vdp: tb/tb_vdp.sv ../rtl/i4220_vdp.sv ../rtl/i4220_render.sv ../rtl/i4220_blitter.sv
	$(VERILATOR) --binary --timing -Wall -Wno-UNUSEDSIGNAL --timescale 1ns/1ps \
		--Mdir $(BUILD)/obj_vdp ../rtl/i4220_render.sv ../rtl/i4220_blitter.sv \
		../rtl/i4220_vdp.sv tb/tb_vdp.sv --top-module tb_vdp

# full VDP top (bus-loaded, free-running timing, scan-out capture) vs MAME
vdp-verify: $(BUILD)/obj_vdp/Vtb_vdp
	@fail=0; \
	for f in $(MAME_FRAMES); do \
	  echo "=== vdp frame $$f ==="; \
	  $(BUILD)/obj_vdp/Vtb_vdp +SCENE=$(BUILD)/mame/frame_$$f \
	      +OUT=$(BUILD)/mame/frame_$$f/vdp.ppm +GFXSIZE=4194304; \
	  python3 diff_ppm.py $(BUILD)/mame/frame_$$f/snap.ppm \
	      $(BUILD)/mame/frame_$$f/vdp.ppm || fail=1; \
	done; exit $$fail

clean:
	rm -rf $(BUILD)
