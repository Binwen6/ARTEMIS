#!/usr/bin/env bash
# =============================================================================
# ARTEMIS per-asset GIF pipeline
# For every .npy under the configured asset directories, run the raymarching
# binary in single_asset mode and produce one GIF per file.
#
# Output layout:
#   gallery/demo/per_asset/<set>/<stem>.gif
#
# Env knobs:
#   FPS                 GIF framerate (default 15)
#   GIF_WIDTH           GIF width, keeps aspect (default 800)
#   SKIP_BUILD=1        skip cmake build
#   KEEP_FRAMES=1       keep intermediate PPMs under _frames/
#   OUT_DIR             output root (default gallery/demo/per_asset)
#   ASSET_SETS          space-separated set names (default: "xjtu point_cloud_1B")
#   ASSET_DIR_<name>    absolute path (relative paths are resolved from build/)
#                       for the binary (e.g. "/../assets/xjtu")
#   ASSET_DIR_<name>_abs filesystem absolute path used for file enumeration
#   LIMIT_<name>        max number of assets to process (debug aid)
#
# Per-asset timeline: 210 frames @15fps = 14s
#   phase_01_flocking    (2s)
#   phase_02_settle      (4s)
#   phase_03_orbit       (5s)
#   phase_04_mode_switch (3s)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLGL_DIR="${PROJECT_ROOT}/CLGLInterop"
BUILD_DIR="${CLGL_DIR}/build"
EXE="${BUILD_DIR}/examples/raymarching"

FPS="${FPS:-15}"
GIF_WIDTH="${GIF_WIDTH:-800}"
OUT_DIR="${OUT_DIR:-${PROJECT_ROOT}/gallery/demo/per_asset}"

ASSET_SETS="${ASSET_SETS:-xjtu point_cloud_1B}"

# Binary-relative paths (used for ARTEMIS_ASSET_DIR): resolved via getcwd+concat
# inside read_npz.cpp, so they must begin with "/" and be interpretable from
# BUILD_DIR. Absolute paths are used for filesystem enumeration by this script.
ASSET_DIR_xjtu_default="/../assets/xjtu"
ASSET_DIR_xjtu_abs_default="${CLGL_DIR}/assets/xjtu"

ASSET_DIR_point_cloud_1B_default="/../assets/point-cloud-1B"
ASSET_DIR_point_cloud_1B_abs_default="${CLGL_DIR}/assets/point-cloud-1B"

log() { printf "\033[1;36m[per-asset]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[per-asset:warn]\033[0m %s\n" "$*" >&2; }
err() { printf "\033[1;31m[per-asset:error]\033[0m %s\n" "$*" >&2; }

command -v ffmpeg >/dev/null || { err "ffmpeg not found on PATH"; exit 2; }

resolve() {
  local var="$1"
  local default_var="${var}_default"
  local val="${!var:-}"
  if [[ -z "${val}" ]]; then
    val="${!default_var:-}"
  fi
  printf '%s' "${val}"
}

# ---- build ----------------------------------------------------------------
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

mkdir -p "${OUT_DIR}"

# ---- main loop ------------------------------------------------------------
total_ok=0; total_fail=0

for set_name in ${ASSET_SETS}; do
  asset_dir_rel="$(resolve "ASSET_DIR_${set_name}")"
  asset_dir_abs="$(resolve "ASSET_DIR_${set_name}_abs")"

  if [[ -z "${asset_dir_rel}" || -z "${asset_dir_abs}" ]]; then
    warn "set '${set_name}' missing ASSET_DIR_${set_name}[/_abs] — skipping"
    continue
  fi
  if [[ ! -d "${asset_dir_abs}" ]]; then
    warn "${asset_dir_abs} is not a directory — skipping"
    continue
  fi

  set_out="${OUT_DIR}/${set_name}"
  frames_root="${set_out}/_frames"
  mkdir -p "${set_out}"

  log "=== set: ${set_name} ==="
  log "    binary_dir=${asset_dir_rel}"
  log "    filesystem=${asset_dir_abs}"

  npy_files=()
  while IFS= read -r _f; do
    npy_files+=("${_f}")
  done < <(find "${asset_dir_abs}" -maxdepth 1 -name '*.npy' | sort)
  nfiles=${#npy_files[@]}
  log "found ${nfiles} .npy file(s)"

  limit_var="LIMIT_${set_name}"
  limit="${!limit_var:-0}"
  if [[ "${limit}" -gt 0 && "${limit}" -lt "${nfiles}" ]]; then
    log "LIMIT_${set_name}=${limit} — truncating"
    npy_files=("${npy_files[@]:0:${limit}}")
    nfiles=${limit}
  fi

  idx=0
  for npy in "${npy_files[@]}"; do
    idx=$((idx + 1))
    stem="$(basename "${npy}" .npy)"
    gif_out="${set_out}/${stem}.gif"

    if [[ -f "${gif_out}" && "${FORCE:-0}" != "1" ]]; then
      log "[${idx}/${nfiles}] ${stem}: already exists — skipping (FORCE=1 to regenerate)"
      total_ok=$((total_ok + 1))
      continue
    fi

    frames_dir="${frames_root}/${stem}"
    rm -rf "${frames_dir}"
    mkdir -p "${frames_dir}"

    log "[${idx}/${nfiles}] ${stem}: rendering 210 frames"

    (
      cd "${BUILD_DIR}"
      ARTEMIS_DEMO=1 \
      ARTEMIS_DEMO_MODE=single_asset \
      ARTEMIS_DEMO_OUTDIR="${frames_dir}" \
      ARTEMIS_ASSET_DIR="${asset_dir_rel}" \
      ARTEMIS_ASSET_FOCUS="${stem}" \
      "${EXE}" > "${frames_dir}/_binary.log" 2>&1
    ) || {
      warn "binary failed for ${stem} — see ${frames_dir}/_binary.log"
      total_fail=$((total_fail + 1))
      continue
    }

    nframes=$(ls "${frames_dir}"/frame_*.ppm 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${nframes}" -lt 10 ]]; then
      warn "${stem}: only ${nframes} frames written — skipping encode"
      total_fail=$((total_fail + 1))
      continue
    fi

    palette="${frames_dir}/_palette.png"
    log "[${idx}/${nfiles}] ${stem}: encoding (${nframes} frames) -> ${gif_out}"

    ffmpeg -y -hide_banner -loglevel error \
      -framerate "${FPS}" -i "${frames_dir}/frame_%05d.ppm" \
      -vf "scale=${GIF_WIDTH}:-2:flags=lanczos,palettegen=stats_mode=diff" \
      "${palette}"

    ffmpeg -y -hide_banner -loglevel error \
      -framerate "${FPS}" -i "${frames_dir}/frame_%05d.ppm" \
      -i "${palette}" \
      -lavfi "scale=${GIF_WIDTH}:-2:flags=lanczos [v]; [v][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
      -loop 0 "${gif_out}"

    total_ok=$((total_ok + 1))

    if [[ "${KEEP_FRAMES:-0}" != "1" ]]; then
      rm -rf "${frames_dir}"
    fi
  done

  if [[ "${KEEP_FRAMES:-0}" != "1" ]]; then
    rmdir "${frames_root}" 2>/dev/null || true
  fi
  log "${set_name}: done. GIFs in ${set_out}"
done

log "ALL DONE. ok=${total_ok} fail=${total_fail}"
log "output root: ${OUT_DIR}"
