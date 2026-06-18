#!/usr/bin/env bash
set -euo pipefail

printf '\033[?25l'
cleanup() {
  printf '\033[r\033[m\033[?25h\033[%s;1H' "${rows:-1}"
}
trap cleanup EXIT INT TERM

read -r rows cols < <(stty size)
if (( rows < 12 || cols < 40 )); then
  echo "terminal is too small for the probe; use at least 40x12" >&2
  exit 1
fi

top_rows=5
primary_top=$((top_rows + 1))
line_count=$((rows * 5))
token="GHOSTTY_SCROLL_REGION_PROBE"

printf '\033[2J\033[H'
for row in $(seq 1 "$top_rows"); do
  printf '\033[%d;1H\033[48;5;238m\033[38;5;230m' "$row"
  printf 'TOP_MANAGED_SENTINEL row=%02d - this is the separately managed top pane' "$row"
  printf '\033[K\033[m'
done

printf '\033[%d;1H' "$primary_top"
printf 'Primary pane starts here. Scroll region is rows %d..%d. Token prefix: %s\033[K' \
  "$primary_top" "$rows" "$token"

printf '\033[%d;%dr' "$primary_top" "$rows"
printf '\033[%d;1H' "$rows"

for i in $(seq 1 "$line_count"); do
  printf '%s_%04d lower-region native-scrollback candidate\n' "$token" "$i"
  sleep 0.01
done

printf '\033[r'
printf '\033[%d;1H\033[48;5;22m\033[38;5;231m' "$((rows - 2))"
printf 'Probe complete. While this waits, test Ghostty native scrolling/search.\033[K\033[m'
printf '\033[%d;1H' "$((rows - 1))"
printf 'Search/scroll for %s_0001. Does the TOP_MANAGED_SENTINEL stay pinned while scrolled back?\033[K' "$token"
printf '\033[%d;1H' "$rows"
printf 'Press Enter to reset margins and exit. '
read -r _
