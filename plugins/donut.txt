# sysdash plugin: spinning ASCII donut
# A port of the classic donut.c (Andy Sloane's obfuscated "donut math") to the
# sysdash animation API. Bash has no fast floating point, so each frame is
# computed by one awk process using the same torus / z-buffer / luminance maths.
#
# Install:  sysdash i https://example.com/donut.sh
# Run:      sysdash live        (animates at 30 fps; other modes show a still frame)
SYSDASH_PLUGIN_ID="donut"
SYSDASH_PLUGIN_NAME="Donut"
SYSDASH_PLUGIN_SPAN="half"
SYSDASH_PLUGIN_FPS="30"

# sysdash_plugin_donut_frame WIDTH FRAME MS
sysdash_plugin_donut_frame() {
  local w=${1:-72} n=${2:-0} ms=${3:-0} gw gh lead row caption
  gw=$((w - 4)); [ "$gw" -gt 64 ] && gw=64; [ "$gw" -lt 24 ] && gw=24
  gh=$((gw * 22 / 80)); [ "$gh" -lt 8 ] && gh=8          # keep the original 80x22 proportions
  printf -v lead '%*s' $(((w - 4 - gw) / 2)) ''

  while IFS= read -r row; do
    box_line "${lead}${row}"
  done < <(awk -v W="$gw" -v H="$gh" -v MS="$ms" \
               -v C1="$DIM" -v C2="$ACC" -v C3="$BOLD$ACC2" -v RS_="$RST" '
    BEGIN {
      L = ".,-~:;=!*#$@"
      A = 1.0 + MS * 0.0012                      # original: A += 0.04 per frame (~30 fps)
      B = 0.5 + MS * 0.0006                      # original: B += 0.02 per frame
      sA = sin(A); cA = cos(A); sB = sin(B); cB = cos(B)
      xs = W * 30 / 80; ys = H * 15 / 22; cx = W / 2; cy = H / 2
      dj = 0.07 * 80 / W; di = 0.02 * 80 / W      # coarser sampling on smaller grids
      for (k = 0; k < W * H; k++) { b[k] = 0; z[k] = 0 }
      for (j = 0; j < 6.28; j += dj) {
        d = cos(j); f = sin(j); h = d + 2
        for (i = 0; i < 6.28; i += di) {
          c = sin(i); l = cos(i)
          D = 1 / (c * h * sA + f * cA + 5)
          t = c * h * cA - f * sA
          x = int(cx + xs * D * (l * h * cB - t * sB))
          y = int(cy + ys * D * (l * h * sB + t * cB))
          o = x + W * y
          N = int(8 * ((f * sA - c * d * cA) * cB - c * d * sA - f * cA - l * d * sB))
          if (H > y && y > 0 && x > 0 && W > x && D > z[o]) {
            z[o] = D; if (N > 11) N = 11; b[o] = (N > 0 ? N : 0) + 1
          }
        }
      }
      for (y = 0; y < H; y++) {
        s = ""; cur = -1
        for (x = 0; x < W; x++) {
          v = b[x + W * y]
          if (v == 0) { s = s " "; continue }
          tone = (v <= 4) ? 1 : (v <= 8 ? 2 : 3)
          if (tone != cur) { s = s (tone == 1 ? C1 : (tone == 2 ? C2 : C3)); cur = tone }
          s = s substr(L, v, 1)
        }
        print s RS_
      }
    }')

  if [ "${SYSDASH_LIVE:-0}" = 1 ]; then caption="${DIM}frame ${n}${RST}"
  else caption="${DIM}still frame ${SEP} run ${RST}sysdash live${DIM} to animate${RST}"; fi
  box_center "$caption"
}
