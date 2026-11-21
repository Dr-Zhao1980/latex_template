#!/usr/bin/env bash
# Permanent Linux/WSL runner. Requires Bash and util-linux flock.
set -euo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
MAIN=${1:-}; ROOT=${2:-$BASE}; TEX_BIN=${3:-}; MODE=${4:-build}
BUILD=''; OWN_LOCK=0
failure() {
  local rc=$?; ((rc != 0)) || return 0
  if ((OWN_LOCK)) && [[ -d "$BUILD" && ! -L "$BUILD" ]]; then
    printf 'FAILED exit=%s %s\nInspect latexmk.stdout.log and latexmk.stderr.log\n' "$rc" "$(date -Iseconds)" > "$BUILD/last-${MODE/build/build}-status.txt" || :
  fi
}
trap failure EXIT
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -d "$ROOT" ]] || die "Project directory missing: $ROOT"
ROOT=$(cd -- "$ROOT" && pwd -P)
if [[ -z "$MAIN" && -f "$ROOT/.vscode/latex-main.txt" ]]; then IFS= read -r MAIN < "$ROOT/.vscode/latex-main.txt" || :; fi
MAIN=${MAIN:-main.tex}
[[ "$MAIN" = /* ]] || MAIN="$ROOT/$MAIN"
[[ "$(cd -- "$(dirname -- "$MAIN")" && pwd -P)" == "$ROOT" ]] || die 'Main document must be in the initialized project directory.'
LEAF=$(basename -- "$MAIN"); STEM=${LEAF%.tex}
case "$MODE" in build|clean|clean-all) ;; *) die "Unknown mode: $MODE" ;; esac
[[ "$MODE" != build || -f "$MAIN" ]] || die "Source missing: $MAIN"
BUILD="$ROOT/build"
[[ ! -L "$BUILD" && ! -L "$ROOT/.vscode" ]] || die 'build/.vscode must not be symbolic links.'
mkdir -p -- "$ROOT/.vscode" "$BUILD"
[[ ! -L "$ROOT/.vscode/.latex-operation.lock" ]] || die 'Lock must not be a symbolic link.'
command -v flock >/dev/null || die 'Install util-linux (flock) for safe build/clean locking.'
exec 9> "$ROOT/.vscode/.latex-operation.lock"
flock -w "${LATEX_LOCK_TIMEOUT:-120}" 9 || { printf 'Another build/setup/clean is running.\n' >&2; exit 75; }
OWN_LOCK=1
PROBE=$(mktemp "$BUILD/.permission.XXXXXXXX")
printf 'modify' >> "$PROBE"; cat -- "$PROBE" >/dev/null; rm -- "$PROBE"
# Migrate recognized root/section artifacts once, with collision-free archives.
ARCHIVE="$BUILD/legacy/$(date +%Y%m%d-%H%M%S)-$$"
while IFS= read -r -d '' file; do
  name=$(basename -- "$file")
  case "$name" in
    *.log|*.out) [[ -f "${file%.*}.tex" ]] || continue ;;
    *.aux|*.toc|*.synctex|*.synctex.gz|*.fls|*.fdb_latexmk|*.xdv|*.bbl|*.bcf|*.blg|*.run.xml|*.lof|*.lot|*.idx|*.ind|*.ilg) ;;
    *) continue ;;
  esac
  relative=${file#"$ROOT"/}; target="$ARCHIVE/$relative"
  mkdir -p -- "$(dirname -- "$target")"
  mv -n -- "$file" "$target" || printf 'WARN: Cannot archive %s\n' "$file" >&2
done < <(find "$ROOT" -type d \( -name build -o -name .vscode -o -name .git -o -name node_modules -o -name .venv \) -prune -o -type f -print0)
if [[ "$MODE" != build ]]; then
  failed=0
  while IFS= read -r -d '' file; do
    name=$(basename -- "$file")
    case "$name" in setup-*|latexmk.*|last-*-status.txt|latex-diagnostic*) continue ;; esac
    case "$name" in
      *.aux|*.out|*.toc|*.synctex|*.synctex.gz|*.fls|*.fdb_latexmk|*.xdv|*.dvi|*.bbl|*.bcf|*.blg|*.run.xml|*.lof|*.lot|*.lol|*.nav|*.snm|*.vrb|*.idx|*.ind|*.ilg|*.acn|*.acr|*.alg|*.glg|*.glo|*.gls|*.nlo|*.nls|*.thm|*.maf|*.mtc|*.mtc[0-9]*|*.spl|*.brf) ;;
      *.pdf|*.log) [[ "$MODE" == clean-all ]] || continue ;;
      *) continue ;;
    esac
    rm -- "$file" || failed=1
  done < <(find "$BUILD" -type d \( -name legacy -o -name settings-backups \) -prune -o -type f -print0)
  ((failed == 0)) || die 'Some generated files could not be cleaned.'
  printf 'SUCCESS %s %s\n' "$MODE" "$(date -Iseconds)" > "$BUILD/last-clean-status.txt"
  exit 0
fi
if [[ -z "$TEX_BIN" && -f "$ROOT/.vscode/latex-bin.txt" ]]; then IFS= read -r TEX_BIN < "$ROOT/.vscode/latex-bin.txt" || :; fi
[[ -z "$(find "$BUILD" -type l -print -quit)" ]] || die 'Output tree contains a symbolic link.'
if [[ -n "$TEX_BIN" && -x "$TEX_BIN/latexmk" && -x "$TEX_BIN/xelatex" ]]; then export PATH="$TEX_BIN:$PATH"; fi
for tool in latexmk xelatex xdvipdfmx; do command -v "$tool" >/dev/null || die "Missing $tool. Install native Linux TeX Live or specify --tex-bin during initialization."; done
# Never load root/user latexmkrc, whose custom commands can scatter outputs.
while IFS= read -r -d '' file; do
  relative=${file#"$ROOT"/}; relative=$(dirname -- "$relative")
  [[ ! -L "$BUILD/$relative" ]] || die "Linked auxiliary directory: $relative"
  mkdir -p -- "$BUILD/$relative"
done < <(find "$ROOT" -type d \( -name build -o -name .vscode -o -name .git -o -name node_modules -o -name .venv \) -prune -o -type f -name '*.tex' -print0)
cd -- "$ROOT"
latexmk -norc -pdfxe -synctex=1 -interaction=nonstopmode -halt-on-error -file-line-error -outdir=build -auxdir=build "./$LEAF" > "$BUILD/latexmk.stdout.log" 2> "$BUILD/latexmk.stderr.log"
[[ -s "$BUILD/$STEM.pdf" ]] || die 'No PDF was generated.'
TEMP_PDF=$(mktemp "$BUILD/.publish.XXXXXXXX")
trap 'rc=$?; rm -f -- "${TEMP_PDF:-}"; exit "$rc"' HUP INT TERM
cp -- "$BUILD/$STEM.pdf" "$TEMP_PDF"
if ! mv -f -- "$TEMP_PDF" "$ROOT/$STEM.pdf"; then rm -f -- "$TEMP_PDF"; die 'Cannot publish PDF (permissions/file lock).'; fi
printf 'SUCCESS %s\nPDF: %s\n' "$(date -Iseconds)" "$ROOT/$STEM.pdf" > "$BUILD/last-build-status.txt"
printf 'PDF: %s\n' "$ROOT/$STEM.pdf"
