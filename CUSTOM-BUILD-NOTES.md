# Custom Bambu Studio — deterministic left/right placement

Fork of BambuStudio 02.08.03.66 that replaces CLI auto-arrange with fixed
left/right placement, built for slicing insole pairs in sequential-print mode.

Branch: `custom/revert-autoplace-to-nov2025`
Remote: `github` → `ErikdeJustPLT/BambuStudio-Custom`
(`origin` is upstream `bambulab/BambuStudio` — do not push there)

---

## Why this exists

The template prints `by object` (sequential). In that mode arrange inflates every
item by the extruder clearance **on both axes**. The hulls are 82.8 × 262mm and
the H2D plate is 350 × 320, so portrait orientation leaves only 58mm of slack in
Y — any meaningful clearance and it no longer fits. Arrange therefore rotated
parts 90°, which swaps the footprint to 262 × 83mm, which meant a pair no longer
fit side by side, which split the job across **two plates**.

This was never an orientation preference. The rotation was a symptom; the split
plate was the actual cost.

Reverting `Arrange.cpp` to November 2025 did **not** fix it — the old binary
rotates too when `allow_rotations` is set, and that option has defaulted to
`true` since 2023. The fix was to stop using generic nesting for this case.

---

## What changed

| file | change |
|---|---|
| `src/BambuStudio.cpp` | `arrange_left_right()` + call site replacing `arrangement::arrange()` for printable objects |
| `src/libslic3r/Arrange.cpp` | restored verbatim to tag `v02.04.00.70`; the earlier hand-reconstructed revert is gone |
| `Dockerfile` | full build + slim runtime stage |
| `bambu-headless` | Xvfb wrapper, installed as `AppRun` |
| `.gitattributes` | forces LF on `bambu-headless` so its shebang survives a Windows checkout |
| `src/libslic3r/Format/bbs_3mf.cpp` | fixed a stale clamp that corrupted `filament_volume_maps` values above `1`; see *Bug fixes* |
| `src/BambuStudio.cpp` | `arrange_left_right()` insets both X extremes by 5mm (`ARRANGE_LR_X_MARGIN`); see *Bug fixes* |

### The placement rule

- never rotates — import orientation is trusted
- always one plate
- outermost items flush to the plate's X extremes (1 item is centred)
- centred in Y
- Y length validated against the **raw** plate, no clearance — parts sit side by
  side, never front-to-back, so clearance does not apply along Y
- more than 2 printable objects is an error: the template's own part must be set
  non-printable

`get_bed_shape()` returns the intersection of both extruders' printable areas
(25–325 on the H2D, not the full 0–350), so placement automatically respects
both extruders' reach.

---

## Images on the server (192.168.1.8)

| image | size | purpose |
|---|---|---|
| `custom-bambu-slicer:v02.08.03.66-lr-slim` | 1.42GB | production — `SLICER_IMAGE` in `main/config/config.json` points here; includes both *Bug fixes* below |
| `custom-bambu-slicer:v02.08.03.66-lr-slim-pre-margin-fix` | 1.42GB | rollback: the slim image as it was before the 2026-09-17 margin fix, kept in case the 5mm margin needs reverting |
| `bambu-build-env:02.08.03.66-lr` | 12.3GB | saved build environment |

The running container `adoring_euclid` (from the `bambu-build-env` image, `docker ps` on the
server) already has both 2026-09-17 fixes compiled at `/tmp/BambuStudio-Custom/build/src/
bambu-studio` — reuse it for the next incremental rebuild instead of starting a fresh
`bambu-build-env` container from scratch.

### Restoring the build environment

```bash
docker run -it --name bambu-build \
  -v /root/Erwin_Converter/storage:/root/Erwin_Converter/storage \
  -v /srv/automation/configs:/srv/automation/configs \
  bambu-build-env:02.08.03.66-lr bash
```

Source at `/tmp/BambuStudio-Custom`, deps at `/root/deps_install`. Rebuild after
a source change:

```bash
cd /tmp/BambuStudio-Custom/build && cmake --build . -j$(nproc)
```

Minutes, not hours — the deps are already built. Rebuilding from scratch via the
Dockerfile takes several hours, most of it OpenCASCADE, OpenVDB and wxWidgets.

### Building the slim image from scratch

```bash
git clone -b custom/revert-autoplace-to-nov2025 \
  https://github.com/ErikdeJustPLT/BambuStudio-Custom.git /opt/bambustudio-src
cd /opt/bambustudio-src && docker build -t custom-bambu-slicer:<tag> .
```

---

## Running it

```bash
docker run --rm \
  -v /root/Erwin_Converter/storage:/root/Erwin_Converter/storage \
  -v /srv/automation/configs:/srv/automation/configs \
  custom-bambu-slicer:v02.08.03.66-lr-slim \
  /opt/bambu/squashfs-root/AppRun \
  /srv/automation/configs/<template>.3mf \
  <left>.stl <right>.stl \
  --slice 0 --export-3mf <out>.3mf --debug 2 --allow-newer-file
```

Template first, then models, then flags — same shape as `build_slicer_cmd()`.

---

## Pipeline integration

One line in `main/config/config.json`:

```json
"SLICER_IMAGE": "custom-bambu-slicer:v02.08.03.66-lr-slim",
```

`SLICER_BIN` stays `/opt/bambu/squashfs-root/AppRun` — the image puts the
wrapper at that exact path so it is a drop-in for the AppImage-based images.
No change needed in `bambu_slicer.py`.

Two-pass mode is not needed any more. It existed to bridge an old arrange image
to a newer slicer; arrange and slice are now the same binary.

---

## Bug fixes

Both fixed 2026-09-17, verified against the real failing job (order S126143067, `H2D Production
0.6`, `nozzle_volume_type: ['Standard', 'TPU High Flow']`), and shipped in
`custom-bambu-slicer:v02.08.03.66-lr-slim` on the server.

### `filament_volume_maps` clamp corrupting non-Standard nozzle types (fixed, but wasn't the actual failure cause)

**Symptom initially blamed on this:** slicing a project where an extruder's `nozzle_volume_type`
was anything other than `Standard`/`High Flow` (e.g. `TPU High Flow`) logged
`Invalid T command (T1001)`, `Invalid T command (T65535)`, `Invalid T command (T65279)`, then
`plate 1: found gcode unprintable!`.

**Root cause of the *clamp bug itself* (real, worth fixing):**
`src/libslic3r/Format/bbs_3mf.cpp`, `PlateData::parse_filament_info()`. The `filament_volume_maps`
3mf-metadata loader clamped any value `> 1` down to `0` (Standard) — a check written back when
`NozzleVolumeType` only had two members. The enum has since grown `nvtHybrid=2`,
`nvtTPUHighFlow=3`, `nvtE3DHighFlow=5` (`src/libslic3r/PrintConfig.hpp`), so a plate whose
object-level metadata legitimately said `3` (TPU High Flow) was silently rewritten to `0` on
load, no warning logged.

**Fix:** validate against `get_valid_nozzle_volume_type()` (the real enum set) instead of the
stale `> 1` check; an actually-invalid value still falls back to Standard, but now logs a warning
instead of failing silently.

**But this turned out not to be why the job failed.** Rebuilding with only this fix and
re-running the same order reproduced the *exact same* `Invalid T command` errors. Pulling
`machine_start_gcode`/`machine_end_gcode` straight out of the template's `project_settings.config`
showed `T1001` (after a `; Hotend Type Detection` comment) and `T65535`/`T65279` (in AMS
filament-park/retract sentinels, `M620 S65535` / `M620 S65279`) are **literal, intentional BBL
firmware commands baked into the H2D machine profile**, not corrupted values. `GCodeProcessor::
process_T` (`src/libslic3r/GCode/GCodeProcessor.cpp:5850-5858`) only whitelists `T1000`, `T1100`,
and `T255` as special no-op sentinels; it doesn't know about `T1001`/`T65535`/`T65279`, so it logs
them as invalid every single H2D run even though they're fine. Cosmetic log noise, not fatal by
itself, and NOT specific to TPU High Flow — the clamp fix above is still correct and worth
keeping, it just wasn't the bug that failed this job. See the next entry for the actual cause.

### `arrange_left_right()` placing parts flush against the unprintable-area boundary (the actual fix)

**Root cause:** the real failure was `gcode_result->gcode_check_result.error_code = 1`, set at
`src/libslic3r/GCode/GCodeProcessor.cpp:1900` when a toolpath drawn by one extruder overlaps
*that extruder's own declared unprintable area*. `get_bed_shape()` already trims the plate to the
intersection of both extruders' reachable areas, but `arrange_left_right()`'s "flush to the X
extremes" placement put a part's edge right on that boundary — next to the idle nozzle's
parking/exclusion zone on the H2D — which the checker flagged for order S126143067's `TPU High
Flow`-on-extruder-2 configuration.

**Fix:** `src/BambuStudio.cpp`, `arrange_left_right()` — inset both X extremes by a 5mm margin
(`ARRANGE_LR_X_MARGIN`) before flushing parts to them, so parts sit just inside the safe area
instead of touching it.

**Verified:** rebuilt in the `bambu-build-env` container, re-ran order S126143067's exact
template + STLs through both the raw binary and the full production-shaped `docker run --rm -v
... -v ... <image> AppRun <template> <left>.stl <right>.stl --slice 0 --export-3mf ... --debug 2
--allow-newer-file` invocation (matching `build_slicer_cmd()` in `bambu_slicer.py`) — exits clean,
3mf exports, no `gcode unprintable` error. The `Invalid T command` lines described above still
print (harmless, unrelated, see previous entry) but no longer accompany a failure.

**Not yet re-validated on other orders.** 5mm was picked as a reasonable first guess, not derived
from the H2D's actual exclusion-zone geometry. If a part that previously fit tightly now reports
"exceeds plate depth" or two parts no longer fit side by side, that's this margin — the fix is in
one place (`ARRANGE_LR_X_MARGIN`) and easy to tune down. Re-run a batch of real orders before
fully trusting this in production; the rollback image
`custom-bambu-slicer:v02.08.03.66-lr-slim-pre-margin-fix` is there if needed.

### Rebuilding after a source change

The container `adoring_euclid` (from `bambu-build-env:02.08.03.66-lr`) already has the source
checked out and both fixes compiled — reuse it:

```bash
docker exec -it adoring_euclid bash
cd /tmp/BambuStudio-Custom
git pull github custom/revert-autoplace-to-nov2025   # or docker cp a patched file in directly
cd build && cmake --build . -j$(nproc)                # minutes, not hours -- deps are prebuilt
```

To repackage the slim image from an already-built binary without paying for a full
`docker build` of the main `Dockerfile` (whose `git clone` layer is cached by instruction text,
not by repo content, so a plain rebuild would silently reuse a stale clone unless you pass
`--no-cache` and eat the multi-hour dependency rebuild):

```bash
mkdir -p /tmp/slim_ctx/lib
docker cp adoring_euclid:/tmp/BambuStudio-Custom/build/src/bambu-studio /tmp/slim_ctx/
docker cp adoring_euclid:/tmp/BambuStudio-Custom/resources /tmp/slim_ctx/
for f in $(docker exec adoring_euclid bash -c 'ls /root/deps_install/usr/local/lib/*.so*' | xargs -n1 basename); do
  docker cp adoring_euclid:/root/deps_install/usr/local/lib/$f /tmp/slim_ctx/lib/$f
done
cp bambu-headless Dockerfile.slim-repack /tmp/slim_ctx/   # from this repo checkout
cd /tmp/slim_ctx && docker build -f Dockerfile.slim-repack -t custom-bambu-slicer:<new-tag> .
```

`Dockerfile.slim-repack` (checked into this repo) mirrors the main `Dockerfile`'s runtime stage
but `COPY`s from that local context instead of a builder stage. Test with
`--security-opt label=disable` on a manual `docker run` if you hit `boost::filesystem::status:
Permission denied` on the bind-mounted config/storage dirs — those paths carry a pinned SELinux
MCS category (`ls -Z`), and an ad-hoc container gets a different one by default. The production
pipeline's own container apparently doesn't hit this (`bambu_slicer.py`'s `build_slicer_cmd()`
passes no `--security-opt` either), so this is specific to one-off manual testing, not something
to bake into the pipeline.

The toolchain itself (baked into `bambu-build-env:02.08.03.66-lr`, defined by the `Dockerfile`'s
builder stage) is: Ubuntu 24.04, `build-essential` (GCC/G++), CMake + Ninja, wxWidgets built with
`DEP_WX_GTK3=ON` / `SLIC3R_GTK=3` (GTK3, not Ubuntu's default GTK2), and the rest of the apt list
at the top of the `Dockerfile`. Dependencies (OpenCASCADE, OpenVDB, a source-built FFmpeg 7.0,
wxWidgets) are prebuilt once under `/root/deps_install` inside that image — that's the whole
reason to reuse it instead of rebuilding from the Dockerfile, which takes several hours.

---

## Gotchas (each cost real time to find)

**`SLIC3R_GUI=OFF` does not produce a CLI build.** `BambuStudio.cpp` includes
`<wx/stdpaths.h>` unconditionally and `src/CMakeLists.txt` references the
`BambuStudio` target in ~30 unguarded places. GUI=OFF gives a broken configure,
not a smaller binary. The CLI lives inside the GUI binary.

**`DEP_WX_GTK3=ON` and `SLIC3R_GTK=3` must be set together.** The default GTK2
build leaves `wxUSE_WEBVIEW=0`, because wxWebView under GTK2 needs WebKitGTK 1.x
which does not exist on Ubuntu 24.04. That produces ~70 `wxWebViewEvent` errors
in `libslic3r_gui`. No apt package fixes it; only the toolkit switch does.

**Install every apt dependency before building deps.** wxWidgets silently
compiles out features whose libraries are missing at *its* configure time —
GStreamer missing gives `wxUSE_MEDIACTRL=0` and a later wall of errors. Order
matters; the Dockerfile gets this right, incremental interactive installs do not.

**FFmpeg 7.0 comes from the deps build, not apt.** Ubuntu 24.04 ships 6.1, so
`libavcodec.so.61` has no apt equivalent and must be copied out of the builder
stage.

**`xvfb-run` hangs in a minimal container** while probing for a free server
number. `bambu-headless` starts Xvfb directly on `:99` instead.

**A virtual display is required even for `--help`** — `glfwInit` is called
unconditionally for thumbnails and aborts without one.

**`Unable to init glew library` / `skip thumbnail generating` is non-fatal.**
Slicing completes; only thumbnails are lost.

**Use `--slice 0`, not `--arrange 1`.** The template's printer profile is not
applied on the `--arrange` path, so you get a default build plate.

**Read the *first* `error:` in a build log, not the last.** A non-fatal GCC
`error:` does not stop compilation — it keeps instantiating templates and dumps
thousands of warnings afterwards, burying the real cause.

---

## Outstanding

**Validate the gcode.** Placement is confirmed byte-identical between the fat and
slim images, but this moves production from slicer 02.05.03.62 to 02.08.03.66.
Print one before it carries real work.

**Parts longer than the plate abort the job.** No strategy chosen yet — see the
TODO at the length check in `arrange_left_right()`. Rotating to X costs the
side-by-side layout and its clearance; diagonal placement complicates the
sequential-print clearance check; splitting or scaling changes the part.

**The second arrange call site is unchanged.** `src/BambuStudio.cpp` has another
`arrangement::arrange()` used only by `--load-assemble-list`, which this pipeline
does not use. Left alone because it could not be tested.

**`Invalid T command (T1001 / T65535 / T65279)` prints on every H2D run.** Root-caused,
see *Bug fixes* above — they're legitimate BBL firmware sentinels (hotend-type
detection, AMS filament park/retract) baked into the H2D `machine_start_gcode`/
`machine_end_gcode`, not corruption. `GCodeProcessor::process_T` only whitelists
`T1000`/`T1100`/`T255`; it doesn't know about these three, so it logs them as
invalid every time even though they're harmless. Not the UTF-8 BOM guessed
originally (which also would not have explained `T1001`), and not the
`filament_volume_maps` clamp either — cosmetic log noise, safe to ignore. Fixing
the whitelist in `GCodeProcessor.cpp` would clean up the log but isn't required
for correct slicing.
