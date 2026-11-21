#!/usr/bin/env bash
# Standalone LaTeX initializer for Linux/WSL (GNU userland + Bash).
# Permanent silent compilation is installed into .vscode/build-latex.sh.
# No .bat or .ps1 file is required, and no Bash initializer is required later.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT="$SCRIPT_DIR"
TEX_FILE=''
TEX_BIN=''
DIAGNOSE=0
NO_SETTINGS=0
NO_PAUSE=0
CONFIGURE_ONLY=0
PROJECT_ONLY=0
MODE=build
STAGE='initialization'
STATUS_LOG=''
SOURCE_FILE=''
SOURCE_DIR=''
BUILD_DIR=''
LATEXMK=''
XELATEX=''
DETECTED_BIN=''
PDF_PATH=''

usage() {
  cat <<'EOF'
LaTeX Once-Setup V6 - Independent Bash initializer
Usage: bash setup-latex.sh [options] [document.tex]
  --file, -TexFile FILE      Explicit root document (.tex)
  --project, -ProjectRoot D  Project directory (default: script directory)
  --tex-bin, -TeXBin DIR    Directory containing latexmk and xelatex
  --diagnose-only           Test XeLaTeX without compiling user documents
  --no-settings             Do not modify .vscode/settings.json
  --configure-only          Configure without TeX; archive/clean old cache
  --mode build|clean|clean-all
  --project-only            Skip an existing parent workspace
  --sudo                    Explicitly request sudo for this project
  --no-pause                Unattended: skip root selection and final Enter
  -h, --help                Show this help

Run once, then delete the installer if desired. Keep .vscode/ after setup.
The Bash version is for Linux / WSL with native TeX tools.
Use the independent .bat or .ps1 version for native Windows VS Code.
EOF
}
log() { printf '%s\n' "$*"; if [[ -n "$STATUS_LOG" ]]; then printf '%s\n' "$*" >> "$STATUS_LOG"; fi; }
fail() { log "[ERROR] $STAGE: $*" >&2; return 1; }
unique_backup() {
  local path="$1" n=0 candidate="${1}.backup-$(date +%Y%m%d-%H%M%S)-$$"
  while [[ -e "$candidate" ]]; do n=$((n+1)); candidate="${path}.backup-$(date +%Y%m%d-%H%M%S)-$$-${n}"; done
  printf '%s\n' "$candidate"
}
abspath_file() { local dir base; dir=$(dirname -- "$1") || return 1; base=$(basename -- "$1") || return 1; (cd -- "$dir" && printf '%s/%s\n' "$(pwd -P)" "$base"); }

parse_args() {
  while (($#)); do
    case "$1" in
      --file|-TexFile|-File|-f) (($# >= 2)) || { echo 'Missing document after --file' >&2; return 2; }; TEX_FILE="$2"; shift 2 ;;
      --project|-ProjectRoot|-p) (($# >= 2)) || { echo 'Missing directory after --project' >&2; return 2; }; PROJECT="$2"; shift 2 ;;
      --tex-bin|-TeXBin) (($# >= 2)) || { echo 'Missing directory after --tex-bin' >&2; return 2; }; TEX_BIN="$2"; shift 2 ;;
      --diagnose-only|-DiagnoseOnly) DIAGNOSE=1; shift ;;
      --no-settings|-NoSettings) NO_SETTINGS=1; shift ;;
      --no-pause|-NoPause) NO_PAUSE=1; shift ;;
      --configure-only|-ConfigureOnly) CONFIGURE_ONLY=1; shift ;;
      --clean-only|-CleanOnly) MODE=clean; shift ;;
      --project-only|-ProjectOnly) PROJECT_ONLY=1; shift ;;
      --mode|-Mode) (($# >= 2)) || return 2; MODE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; if (($#)); then TEX_FILE="$1"; shift; fi ;;
      -*) echo "Unknown option: $1" >&2; return 2 ;;
      *) TEX_FILE="$1"; shift ;;
    esac
  done
  return 0
}

pick_root_document() {
  STAGE='detecting root document'
  local -a candidates=() root_docs=() fallback=()
  local path head magic possible item i
  if [[ -n "$TEX_FILE" ]]; then
    if [[ "$TEX_FILE" = /* ]]; then path="$TEX_FILE"; else path="$PROJECT/$TEX_FILE"; fi
    [[ -f "$path" && "$path" == *.tex ]] || { fail "Requested .tex file does not exist: $path"; return 1; }
    path=$(abspath_file "$path") || return 1
    head=$(head -n 30 -- "$path")
    if ! grep -Eq '\\documentclass' <<< "$head"; then
      magic=$(printf '%s\n' "$head" | sed -nE 's/^[[:space:]]*%[[:space:]]*!TeX[[:space:]]+root[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$/\1/Ip' | head -n 1)
      if [[ -n "$magic" ]]; then
        magic="${magic%\"}"; magic="${magic#\"}"; magic="${magic%\'}"; magic="${magic#\'}"
        if [[ "$magic" = /* ]]; then possible="$magic"; else possible="$(dirname -- "$path")/$magic"; fi
        if [[ -f "$possible" ]]; then path=$(abspath_file "$possible") || return 1; log "Magic root directive: $path"; fi
      fi
    fi
    SOURCE_FILE="$path"
    return 0
  fi
  # Depth is limited; build/, .vscode/, git and dependency folders are skipped.
  while IFS= read -r -d '' item; do
    head=$(head -n 140 -- "$item")
    if grep -Eq '^[[:space:]]*\\document(class|style)(\[|\{)' <<< "$head"; then
      root_docs+=("$item")
    else
      fallback+=("$item")
    fi
  done < <(find "$PROJECT" -maxdepth 5 \( -type d \( -name build -o -name .vscode -o -name .git -o -name node_modules -o -name .venv -o -name _minted-main \) -prune \) -o \( -type f -name '*.tex' -print0 \) 2>/dev/null)
  if ((${#root_docs[@]})); then candidates=("${root_docs[@]}"); else candidates=("${fallback[@]}"); fi
  if ((${#candidates[@]}==0)); then fail 'No TeX root found. Put main.tex beside the installer or pass --file.'; return 1; fi
  if ((${#candidates[@]}==1)); then SOURCE_FILE="${candidates[0]}"; return 0; fi
  for item in "${candidates[@]}"; do
    if [[ "$item" == "$PROJECT/main.tex" ]]; then SOURCE_FILE="$item"; return 0; fi
  done
  if ((NO_PAUSE==0)) && [[ -t 0 ]]; then
    log 'Multiple root documents detected:'
    for i in "${!candidates[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${candidates[i]}"; done
    printf 'Select root [1-%d]: ' "${#candidates[@]}" >&2
    read -r i || return 1
    if [[ "$i" =~ ^[0-9]+$ ]] && ((i>=1 && i<=${#candidates[@]})); then SOURCE_FILE="${candidates[i-1]}"; return 0; fi
  fi
  fail 'Multiple roots. Specify --file filename.tex (or use an interactive terminal).'
}

resolve_tools() {
  STAGE='locating TeX tools'
  local bin path
  local -a bins=()
  if [[ -n "$TEX_BIN" ]]; then
    if [[ -f "$TEX_BIN" ]]; then TEX_BIN=$(dirname -- "$TEX_BIN"); fi
    bins+=("$TEX_BIN")
  fi
  path=$(type -P latexmk 2>/dev/null || type -P latexmk.exe 2>/dev/null || true)
  if [[ -n "$path" ]]; then bins+=("$(dirname -- "$path")"); fi
  for bin in /usr/bin /usr/local/bin /opt/homebrew/bin /Library/TeX/texbin \
             /opt/texlive/*/bin/* /usr/local/texlive/*/bin/* "$HOME"/texlive/*/bin/*; do
    [[ -d "$bin" ]] && bins+=("$bin")
  done
  for bin in "${bins[@]}"; do
    if [[ -x "$bin/latexmk" && -x "$bin/xelatex" && -x "$bin/xdvipdfmx" ]]; then
      LATEXMK="$bin/latexmk"; XELATEX="$bin/xelatex"; DETECTED_BIN="$bin"; break
    fi
  done
  [[ -n "$LATEXMK" && -n "$XELATEX" ]] || { fail 'Need native Linux latexmk, xelatex, xdvipdfmx on PATH, or pass --tex-bin DIR.'; return 1; }
  export PATH="$DETECTED_BIN:$PATH"
  log "latexmk: $LATEXMK"
  log "xelatex: $XELATEX"
}

test_toolchain() {
  STAGE='testing isolated XeLaTeX'
  local temp rc
  temp=$(mktemp -d "$BUILD_DIR/.healthcheck.XXXXXXXX") || return 1
  mkdir -p "$temp/build"
  printf '\\documentclass{article}\n\\begin{document}\nXeLaTeX is working.\n\\end{document}\n' > "$temp/healthcheck.tex"
  (cd "$temp" && "$LATEXMK" -norc -pdfxe -interaction=nonstopmode -halt-on-error -file-line-error -outdir=build healthcheck.tex) > "$BUILD_DIR/setup-env.stdout.log" 2> "$BUILD_DIR/setup-env.stderr.log"
  rc=$?
  if ((rc!=0)) || [[ ! -s "$temp/build/healthcheck.pdf" ]]; then
    fail "XeLaTeX environment test failed (exit $rc): inspect $BUILD_DIR/setup-env.stdout.log"
    rm -rf -- "$temp"
    return 1
  fi
  rm -rf -- "$temp"
  log '[OK] Minimal XeLaTeX environment test passed.'
}

# The file below is the complete permanent build script, embedded in this installer.
# It is deliberately self-contained. No files from this installer are referenced.
install_runner() {
  STAGE='installing permanent silent build runner'
  local vs="$SOURCE_DIR/.vscode" target tmp backup
  mkdir -p "$vs" "$BUILD_DIR/settings-backups" || return 1
  target="$vs/build-latex.sh"
  tmp=$(mktemp "$BUILD_DIR/.build-latex.XXXXXXXX") || return 1
  cat > "$tmp" <<'PERMANENT_RUNNER'
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
PERMANENT_RUNNER
  if [[ -f "$target" ]] && cmp -s -- "$tmp" "$target"; then
    log "Permanent runner unchanged: $target"
    rm -f -- "$tmp"
  else
    if [[ -e "$target" ]]; then backup=$(unique_backup "$BUILD_DIR/settings-backups/build-latex.sh"); cp -p -- "$target" "$backup" || return 1; fi
    mv -f -- "$tmp" "$target" || return 1
    chmod 755 "$target" || return 1
    log "Installed permanent runner: $target"
  fi
}

# Python3 is optional when no old VS Code settings exist. With an existing
# settings.json it is used to safely retain other user/editor preferences.
update_settings() {
  local folder="$1" vs="$1/.vscode" settings="$1/.vscode/settings.json" backup target
  mkdir -p "$vs" "$BUILD_DIR/settings-backups" || return 1
  if [[ -f "$settings" ]]; then
    backup=$(unique_backup "$BUILD_DIR/settings-backups/$(basename -- "$folder")-settings.json")
    cp -p -- "$settings" "$backup" || return 1
    log "Backed up existing settings: $backup"
  fi
  if command -v python3 >/dev/null 2>&1; then
    LATEX_SETUP_SETTINGS_PATH="$settings" LATEX_SETUP_TEX_BIN="$DETECTED_BIN" python3 - <<'PY'
import json, os, pathlib, re, sys
path = pathlib.Path(os.environ['LATEX_SETUP_SETTINGS_PATH'])
text = path.read_text(encoding='utf-8-sig') if path.exists() else '{}'

def strip_jsonc(text):
    out = []; inside = False; escaped = False; i = 0
    while i < len(text):
        c = text[i]
        if inside:
            out.append(c)
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': inside = False
        elif c == '"': inside = True; out.append(c)
        elif c == '/' and i + 1 < len(text) and text[i+1] == '/':
            while i < len(text) and text[i] not in '\r\n': i += 1
            continue
        elif c == '/' and i + 1 < len(text) and text[i+1] == '*':
            i += 2
            while i + 1 < len(text) and text[i:i+2] != '*/': i += 1
            i += 2
            continue
        else: out.append(c)
        i += 1
    text = ''.join(out)
    # Remove JSONC trailing commas without touching strings.
    out = []; inside = False; escaped = False
    for i, c in enumerate(text):
        if inside:
            out.append(c)
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': inside = False
        elif c == '"': inside = True; out.append(c)
        elif c == ',':
            j = i + 1
            while j < len(text) and text[j].isspace(): j += 1
            if j < len(text) and text[j] in '}]': continue
            out.append(c)
        else: out.append(c)
    return ''.join(out)

try:
    settings = json.loads(strip_jsonc(text)) if text.strip() else {}
    if not isinstance(settings, dict): raise ValueError('settings.json must contain an object')
except (ValueError, json.JSONDecodeError) as exc:
    raise SystemExit('Invalid existing VS Code settings.json (original retained): ' + str(exc))
settings['latex-workshop.latex.tools'] = [{
    'name': 'permanent-silent-xelatex-bash',
    'command': 'bash',
    'args': ['%DIR%/.vscode/build-latex.sh', '%DOC_EXT%', '%DIR%'],
    'cwd': '%DIR%',
}]
settings['latex-workshop.latex.recipes'] = [{
    'name': 'XeLaTeX | silent build + root PDF',
    'tools': ['permanent-silent-xelatex-bash'],
}]
settings.update({
    'latex-workshop.latex.outDir': '%DIR%/build',
    'latex-workshop.latex.auxDir': '%DIR%/build',
    'latex-workshop.latex.recipe.default': 'first',
    'latex-workshop.latex.autoBuild.run': 'onSave',
    'latex-workshop.latex.autoClean.run': 'never',
    'latex-workshop.latex.build.fromFolder': '',
    'latex-workshop.latex.build.enableMagicComments': False,
    'latex-workshop.latex.build.forceRecipeUsage': True,
    'latex-workshop.latex.autoBuild.cleanAndRetry.enabled': False,
    'latex-workshop.view.pdf.viewer': 'tab',
})
settings.pop('latex-workshop.latex.external.build.command', None)
settings.pop('latex-workshop.latex.external.build.args', None)
import tempfile
fd, name = tempfile.mkstemp(prefix='.settings-', suffix='.json', dir=str(path.parent))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(settings, stream, indent=2, ensure_ascii=False)
        stream.write('\n')
    os.replace(name, path)
finally:
    if os.path.exists(name): os.unlink(name)
PY
    return $?
  fi
  if [[ -f "$settings" ]]; then
    fail 'python3 not found. Install python3 to safely merge existing VS Code settings.'
    return 1
  fi
  # This fallback requires no Python when there was no settings file at all.
  cat > "$settings" <<'JSON_FALLBACK'
{
  "latex-workshop.latex.tools": [{"name":"permanent-silent-xelatex-bash","command":"bash","args":["%DIR%/.vscode/build-latex.sh","%DOC_EXT%","%DIR%"],"cwd":"%DIR%"}],
  "latex-workshop.latex.recipes": [{"name":"XeLaTeX | silent build + root PDF","tools":["permanent-silent-xelatex-bash"]}],
  "latex-workshop.latex.outDir":"%DIR%/build",
  "latex-workshop.latex.auxDir":"%DIR%/build",
  "latex-workshop.latex.recipe.default":"first",
  "latex-workshop.latex.autoBuild.run":"onSave",
  "latex-workshop.latex.autoClean.run":"never",
  "latex-workshop.latex.build.enableMagicComments":false,
  "latex-workshop.latex.build.forceRecipeUsage":true,
  "latex-workshop.latex.autoBuild.cleanAndRetry.enabled":false,
  "latex-workshop.view.pdf.viewer":"tab"
}
JSON_FALLBACK
}

# Archive stale outputs from source directory. Keep old root PDFs as deliverables.
archive_initial_aux() {
  local stem="$1" name ext file folder
  folder="$BUILD_DIR/legacy/$(date +%Y%m%d-%H%M%S)-initializer-$$"
  shopt -s nullglob
  for file in "$SOURCE_DIR"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    name=$(basename -- "$file")
    [[ "$name" == "$stem".* ]] || continue
    ext=${name#"$stem".}
    case "$ext" in
      aux|log|out|toc|synctex|synctex.gz|fls|fdb_latexmk|xdv|dvi|ps|bbl|bcf|blg|run.xml|lof|lot|lol|nav|snm|vrb|idx|ind|ilg|acn|acr|alg|glg|glo|gls|ist|nlo|nls|thm|maf|mtc|mtc0|spl|brf)
        mkdir -p "$folder" || return 1
        mv -- "$file" "$folder/$name" || log "[WARN] Could not archive $file"
        ;;
    esac
  done
  shopt -u nullglob
}

write_report() {
  local result="$1" detail="$2"
  [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]] || return 0
  {
    printf 'LaTeX Once-Setup V6 diagnostic report\n'
    printf 'Result: %s\n' "$result"
    printf 'Date: %s\n' "$(date '+%F %T')"
    printf 'Stage: %s\n' "$STAGE"
    printf 'Reason: %s\n' "$detail"
    printf 'Source: %s\n' "$SOURCE_FILE"
    printf 'latexmk: %s\n' "$LATEXMK"
    printf 'xelatex: %s\n' "$XELATEX"
    printf 'PDF: %s\n' "$PDF_PATH"
    printf 'Status log: %s\n' "$STATUS_LOG"
  } > "$BUILD_DIR/latex-diagnostic-report.txt"
}

main() {
  parse_args "$@" || return $?
  case "$MODE" in build|clean|clean-all) ;; *) fail 'Mode must be build, clean or clean-all'; return 2 ;; esac
  STAGE='locating project directory'
  [[ -d "$PROJECT" ]] || { fail "Project directory not found: $PROJECT"; return 1; }
  PROJECT=$(cd -- "$PROJECT" && pwd -P) || return 1
  if [[ -n "$TEX_FILE" && "$TEX_FILE" = /* && -f "$TEX_FILE" ]]; then
    case "$TEX_FILE" in "$PROJECT"/*) ;; *) PROJECT=$(cd -- "$(dirname -- "$TEX_FILE")" && pwd -P) ;; esac
  fi
  if ((DIAGNOSE==0)); then
    pick_root_document || return 1
    SOURCE_DIR=$(cd -- "$(dirname -- "$SOURCE_FILE")" && pwd -P) || return 1
  else
    SOURCE_DIR="$PROJECT"
  fi
  STAGE='creating build directory'
  BUILD_DIR="$SOURCE_DIR/build"
  [[ ! -L "$BUILD_DIR" && ! -L "$SOURCE_DIR/.vscode" ]] || { fail 'build/.vscode must not be symlinks'; return 1; }
  [[ ! -e "$BUILD_DIR" || -d "$BUILD_DIR" ]] || { fail "build is a file: $BUILD_DIR"; return 1; }
  mkdir -p "$BUILD_DIR" || { fail "Cannot create $BUILD_DIR"; return 1; }
  local probe
  probe=$(mktemp "$SOURCE_DIR/.latex-permission.XXXXXXXX") || { fail 'Project not writable; use a writable directory or explicitly --sudo.'; return 1; }
  printf 'modify' >> "$probe" && cat "$probe" >/dev/null && rm -- "$probe" || return 1
  STATUS_LOG="$BUILD_DIR/setup-latex-status.log"
  printf 'LaTeX Once-Setup V6 (Bash) - %s\n' "$(date '+%F %T')" > "$STATUS_LOG"
  log "Source: ${SOURCE_FILE:-none (diagnostic only)}"
  log "Build folder: $BUILD_DIR"
  mkdir -p "$SOURCE_DIR/.vscode" || return 1
  command -v flock >/dev/null || { fail 'util-linux flock is required'; return 1; }
  [[ ! -L "$SOURCE_DIR/.vscode/.latex-operation.lock" ]] || { fail 'Unsafe lock symlink'; return 1; }
  exec 8> "$SOURCE_DIR/.vscode/.latex-operation.lock"
  flock -w 120 8 || { fail 'Another build/setup/clean is running'; return 75; }
  if ((CONFIGURE_ONLY==0)) && [[ "$MODE" == build ]]; then
    resolve_tools || return 1
    test_toolchain || return 1
  fi
  if ((DIAGNOSE==1)); then
    STAGE='diagnosis complete'
    log '[OK] Environment tested; no user document compiled.'
    return 0
  fi
  STAGE='preparing permanent build configuration'
  install_runner || { fail 'Could not install permanent build script.'; return 1; }
  printf '%s\n' "$(basename -- "$SOURCE_FILE")" > "$SOURCE_DIR/.vscode/latex-main.txt"
  if [[ -n "$DETECTED_BIN" || -n "$TEX_BIN" ]]; then printf '%s\n' "${DETECTED_BIN:-$TEX_BIN}" > "$SOURCE_DIR/.vscode/latex-bin.txt"; fi
  if ((NO_SETTINGS==0)) && [[ "$MODE" == build ]]; then
    update_settings "$SOURCE_DIR" || { fail 'Could not configure project VS Code settings.'; return 1; }
    local parent
    parent=$(dirname -- "$SOURCE_DIR")
    if ((PROJECT_ONLY==0)) && [[ "$parent" != / && -d "$parent/.vscode" ]]; then
      update_settings "$parent" || { fail 'Could not configure existing parent VS Code workspace.'; return 1; }
    fi
  fi
  flock -u 8; exec 8>&-
  STAGE='compiling user document'
  local operation="$MODE"
  ((CONFIGURE_ONLY==0)) || operation=clean
  bash "$SOURCE_DIR/.vscode/build-latex.sh" "$SOURCE_FILE" "$SOURCE_DIR" "$DETECTED_BIN" "$operation" > "$BUILD_DIR/setup-compile.stdout.log" 2> "$BUILD_DIR/setup-compile.stderr.log"
  local rc=$?
  if ((rc!=0)); then
    tail -n 20 -- "$BUILD_DIR/setup-compile.stderr.log" >&2 || :
    fail "Compilation exited $rc (see $BUILD_DIR/latexmk.stdout.log)."
    return "$rc"
  fi
  PDF_PATH="$SOURCE_DIR/$(basename -- "$SOURCE_FILE" .tex).pdf"
  STAGE='completed'
  log "[OK] Final PDF: $PDF_PATH"
  log '[OK] From now on, only .vscode/ is required for VS Code compilation.'
  return 0
}

# An explicit sudo request is scoped to this invocation; never chmod 777 or change global policy.
NO_PAUSE=${LATEX_SETUP_NO_PAUSE:-0}
SUDO_REQUEST=0
forward=()
for option in "$@"; do
  case "$option" in --sudo) SUDO_REQUEST=1 ;; --no-pause|-NoPause) NO_PAUSE=1; forward+=("$option") ;; *) forward+=("$option") ;; esac
done
finish() {
  local status=$?
  # Explicit sudo is limited to the selected project, and must not leave root-owned caches.
  if ((EUID==0)) && [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" && -n "$SOURCE_DIR" && "$SOURCE_DIR" != / ]]; then
    local directory
    for directory in "$SOURCE_DIR/.vscode" "$SOURCE_DIR/build"; do
      [[ ! -d "$directory" || -L "$directory" ]] && continue
      case "$directory" in "$SOURCE_DIR/.vscode"|"$SOURCE_DIR/build")
        if ! chown -hR -- "$SUDO_UID:$SUDO_GID" "$directory"; then printf 'ERROR: Could not restore output ownership: %s\n' "$directory" >&2; status=1; fi ;;
      esac
    done
    if ! chown -- "$SUDO_UID:$SUDO_GID" "$SOURCE_DIR"; then printf 'ERROR: Could not restore project directory ownership.\n' >&2; status=1; fi
  fi
  if ((NO_PAUSE==0)) && [[ -t 0 ]]; then read -r -p 'Press Enter to close / 按 Enter 关闭窗口...' _ || :; fi
  exit "$status"
}
trap finish EXIT
if ((SUDO_REQUEST==1 && EUID!=0)); then
  sudo -- bash "${BASH_SOURCE[0]}" "${forward[@]}" --no-pause
  exit $?
fi
main "${forward[@]}"
rc=$?
if ((rc==0)); then write_report PASS 'Completed successfully'; else write_report FAIL 'See status log and stderr'; fi
exit "$rc"
