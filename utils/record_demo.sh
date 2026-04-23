#!/usr/bin/env bash
# =============================================================================
# ARTEMIS demo GIF pipeline
#   1. (Re)build the raymarching executable
#   2. For every configured ASSET_SET: run the binary with ARTEMIS_DEMO=1 and
#      ARTEMIS_ASSET_DIR pointing at that set; dump per-stage PPM sequences
#   3. ffmpeg palette-based PPM -> GIF for each stage
#   4. Clean intermediate frames, leave GIFs in <OUT_DIR>/<set>/
#
# Stages produced per asset set:
#   stage_01_flocking      — random swarm flocking, no target
#   stage_02_settle        — particles converging to a point-cloud target
#   stage_03_orbit         — full 360° orbit around settled form
#   stage_04_mode_switch   — alternating ray-trace / ray-march on same asset
#   stage_05_asset_switch  — cycling through multiple point-cloud assets
#
# Env knobs:
#   FPS                    target GIF fps (default 15)
#   GIF_WIDTH              scale width (default 800, keeps aspect)
#   KEEP_FRAMES=1          don't delete PPMs after GIF build
#   SKIP_BUILD=1           skip cmake build step
#   OUT_DIR                override output dir (default gallery/demo)
#   ASSET_SETS             space-separated list of set names to run; each set
#                          <name> reads ASSET_DIR_<name> / PRIMARY_<name> /
#                          ALT_A_<name> / ALT_B_<name> (falling back to the
#                          defaults below). Default: "xjtu point_cloud_1B"
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLGL_DIR="${PROJECT_ROOT}/CLGLInterop"
BUILD_DIR="${CLGL_DIR}/build"
EXE="${BUILD_DIR}/examples/raymarching"

FPS="${FPS:-15}"
GIF_WIDTH="${GIF_WIDTH:-800}"
OUT_DIR="${OUT_DIR:-${PROJECT_ROOT}/gallery/demo}"

ASSET_SETS="${ASSET_SETS:-xjtu point_cloud_1B}"

# Per-set defaults (override with ASSET_DIR_<name>, PRIMARY_<name>, ...)
ASSET_DIR_xjtu_default="/../assets/xjtu"
PRIMARY_xjtu_default="logo_3d_fixed,logo_3d,logo"
ALT_A_xjtu_default="shui_si_yuan,fei_ta,qian_hao"
ALT_B_xjtu_default="lou,shua_shu"
ROTATION_xjtu_default="logo_3d_fixed,shui_si_yuan,lou,fei_ta,qian_hao,shua_shu"

ASSET_DIR_point_cloud_1B_default="/../assets/point-cloud-1B"
PRIMARY_point_cloud_1B_default="pikachu,shrek,panda"
ALT_A_point_cloud_1B_default="eiffel,tornado,whale"
ALT_B_point_cloud_1B_default="jellyfish,octopus,rubiks"
ROTATION_point_cloud_1B_default="pikachu,shrek,panda,tornado,jellyfish,rubiks"

DWELL_FRAMES="${DWELL_FRAMES:-30}"

STAGES=(
  "stage_01_flocking"
  "stage_02_settle"
  "stage_03_orbit"
  "stage_04_mode_switch"
  "stage_05_asset_switch"
)

log() { printf "\033[1;36m[demo]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[demo:error]\033[0m %s\n" "$*" >&2; }

command -v ffmpeg >/dev/null || { err "ffmpeg not found on PATH"; exit 2; }

# --- Stage 1: build ---------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  log "building raymarching executable"
  if [[ ! -d "${BUILD_DIR}" ]]; then
    mkdir -p "${BUILD_DIR}"
    ( cd "${BUILD_DIR}" && cmake -DCMAKE_BUILD_TYPE=Release .. )
  fi
  ( cd "${BUILD_DIR}" && cmake --build . --parallel )
else
  log "SKIP_BUILD=1 — using existing binary"
fi

[[ -x "${EXE}" ]] || { err "executable not found at ${EXE}"; exit 3; }

# --- Stage 2/3: loop over asset sets ----------------------------------------
mkdir -p "${OUT_DIR}"

# Resolve a per-set env value: lookup ${var_name}, else fall back to the
# configured default (e.g. PRIMARY_point_cloud_1B_default).
resolve() {
  local var="$1"     # e.g. PRIMARY_xjtu
  local default_var="${var}_default"
  local val="${!var:-}"
  if [[ -z "${val}" ]]; then
    val="${!default_var:-}"
  fi
  printf '%s' "${val}"
}

for set_name in ${ASSET_SETS}; do
  asset_dir="$(resolve "ASSET_DIR_${set_name}")"
  primary="$(resolve "PRIMARY_${set_name}")"
  alt_a="$(resolve "ALT_A_${set_name}")"
  alt_b="$(resolve "ALT_B_${set_name}")"
  rotation="$(resolve "ROTATION_${set_name}")"

  if [[ -z "${asset_dir}" ]]; then
    err "asset set '${set_name}' has no ASSET_DIR_${set_name} configured — skipping"
    continue
  fi

  set_out="${OUT_DIR}/${set_name}"
  frames_dir="${set_out}/_frames"
  mkdir -p "${set_out}"
  rm -rf "${frames_dir}"
  mkdir -p "${frames_dir}"

  log "=== asset set: ${set_name} ==="
  log "    ASSET_DIR=${asset_dir}"
  log "    PRIMARY=${primary}"
  log "    ALT_A=${alt_a}"
  log "    ALT_B=${alt_b}"
  log "    ROTATION=${rotation} (dwell=${DWELL_FRAMES})"
  log "running demo; frames -> ${frames_dir}"

  (
    cd "${BUILD_DIR}"
    ARTEMIS_DEMO=1 \
    ARTEMIS_DEMO_OUTDIR="${frames_dir}" \
    ARTEMIS_ASSET_DIR="${asset_dir}" \
    ARTEMIS_DEMO_PRIMARY="${primary}" \
    ARTEMIS_DEMO_ALT_A="${alt_a}" \
    ARTEMIS_DEMO_ALT_B="${alt_b}" \
    ARTEMIS_DEMO_ROTATION="${rotation}" \
    ARTEMIS_DEMO_DWELL="${DWELL_FRAMES}" \
    "${EXE}"
  )

  for stage in "${STAGES[@]}"; do
    stage_dir="${frames_dir}/${stage}"
    if [[ ! -d "${stage_dir}" ]] || [[ -z "$(ls -A "${stage_dir}" 2>/dev/null)" ]]; then
      err "stage ${stage} produced no frames — skipping"
      continue
    fi

    palette="${frames_dir}/${stage}.palette.png"
    gif_out="${set_out}/${stage}.gif"
    log "encoding ${stage} -> ${gif_out}"

    ffmpeg -y -hide_banner -loglevel error \
      -framerate "${FPS}" -i "${stage_dir}/frame_%05d.ppm" \
      -vf "scale=${GIF_WIDTH}:-2:flags=lanczos,palettegen=stats_mode=diff" \
      "${palette}"

    ffmpeg -y -hide_banner -loglevel error \
      -framerate "${FPS}" -i "${stage_dir}/frame_%05d.ppm" \
      -i "${palette}" \
      -lavfi "scale=${GIF_WIDTH}:-2:flags=lanczos [v]; [v][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
      -loop 0 "${gif_out}"
  done

  if [[ "${KEEP_FRAMES:-0}" != "1" ]]; then
    log "cleaning intermediate frames for ${set_name} (set KEEP_FRAMES=1 to retain)"
    rm -rf "${frames_dir}"
  fi

  log "${set_name} done. GIFs in: ${set_out}"
  ls -lh "${set_out}"/*.gif 2>/dev/null || true
done

log "all asset sets done. root: ${OUT_DIR}"
