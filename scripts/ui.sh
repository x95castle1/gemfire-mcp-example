# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# Shared look for the fzf menus' summary panels (make chaos / call / load / logs).
# Source it:  . "$(dirname "$0")/ui.sh"
#
# Colours follow one rule everywhere:
#   heading      bold, coloured by risk: red = destroys something, yellow = disrupts, green = safe / repair
#   section      bold magenta ("What it does", "Expect", "MCP signals", ...)
#   commands     yellow       log text   green, quoted     MCP signals   cyan tags      asides   dim
# Set NO_COLOR=1 for plain text (https://no-color.org).
# ─────────────────────────────────────────────────────────────────────────────

if [ -n "${NO_COLOR:-}" ]; then
  ui_b='' ui_d='' ui_r='' ui_red='' ui_yel='' ui_grn='' ui_mag='' ui_cyn='' ui_tag=''
else
  ui_b=$'\e[1m' ui_d=$'\e[2m' ui_r=$'\e[0m'
  ui_red=$'\e[31m' ui_yel=$'\e[33m' ui_grn=$'\e[32m' ui_mag=$'\e[35m' ui_cyn=$'\e[36m'
  ui_tag=$'\e[30;46m'   # black on cyan, for signal tags
fi

# ui_title <danger|warn|safe> <NAME> [subtitle]
ui_title() {
  local c
  case "$1" in danger) c=$ui_red ;; warn) c=$ui_yel ;; *) c=$ui_grn ;; esac
  printf '%s%s%s%s' "$ui_b" "$c" "$2" "$ui_r"
  [ -n "${3:-}" ] && printf '  %s%s%s' "$ui_d" "$3" "$ui_r"
  printf '\n'
}
ui_section() { printf '\n%s%s%s%s\n' "$ui_b" "$ui_mag" "$1" "$ui_r"; }
# ui_field <label> <text...>: a section label and its value on one line
ui_field()   { local l=$1; shift; printf '%s%s%-12s%s %s\n' "$ui_b" "$ui_mag" "$l" "$ui_r" "$*"; }
ui_bullet()  { printf '  • %s\n' "$*"; }
ui_line()    { printf '  %s\n' "$*"; }
ui_blank()   { printf '\n'; }

# Inline pieces: they print without a newline, for use inside $( ) in bullets and lines
ui_cmd()  { printf '%s%s%s' "$ui_yel" "$*" "$ui_r"; }
ui_log()  { printf '%s"%s"%s' "$ui_grn" "$*" "$ui_r"; }
ui_dim()  { printf '%s%s%s' "$ui_d" "$*" "$ui_r"; }
ui_bold() { printf '%s%s%s' "$ui_b" "$*" "$ui_r"; }
ui_tags() { local t; for t in "$@"; do printf '%s %s %s ' "$ui_tag" "$t" "$ui_r"; done; }

# Remove colour codes (a preview command may get a coloured list item as its argument)
ui_strip() { printf '%s' "$1" | sed $'s/\e\\[[0-9;]*m//g'; }

# Colour a log stream: WARN yellow, ERROR/SEVERE/FATAL red (works for GemFire and Spring log formats)
ui_colorize_log() {
  if [ -n "${NO_COLOR:-}" ]; then cat; return; fi
  sed -E \
    -e "s/^(.*(ERROR|\\[error|\\[severe|\\[fatal|SEVERE|FATAL).*)$/${ui_red}\\1${ui_r}/" \
    -e "s/^(.*( WARN |\\[warn|WARNING).*)$/${ui_yel}\\1${ui_r}/"
}

# fzf with the common look: colours on, rounded preview border, and a panel title that follows the
# cursor ("make chaos · kill"). ui_fzf <menu name> [more fzf options...]
ui_fzf() {
  local menu=$1; shift
  fzf --ansi --reverse --preview-window=right,62%,wrap,border-rounded \
      --color=preview-label:bold \
      --bind="focus:transform-preview-label:echo ' $menu · {1} '" "$@"
}
