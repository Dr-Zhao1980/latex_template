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
  --no-pause                Do not ask to select a root document
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
    if [[ -x "$bin/latexmk" && -x "$bin/xelatex" ]]; then
      LATEXMK="$bin/latexmk"; XELATEX="$bin/xelatex"; DETECTED_BIN="$bin"; break
    elif [[ -x "$bin/latexmk.exe" && -x "$bin/xelatex.exe" ]]; then
      LATEXMK="$bin/latexmk.exe"; XELATEX="$bin/xelatex.exe"; DETECTED_BIN="$bin"; break
    fi
  done
  [[ -n "$LATEXMK" && -n "$XELATEX" ]] || { fail 'Need latexmk and xelatex on PATH, or pass --tex-bin DIR.'; return 1; }
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
# Permanent LaTeX Workshop silent builder for Linux/WSL (Bash).
# Usage: bash .vscode/build-latex.sh [main.tex] [project_dir] [tex_bin]
# Generated by setup-latex.sh; do not delete this file when cleaning build/.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BASE_DIR="$(cd -- "$SELF_DIR/.." && pwd -P)"
MAIN_FILE="${1:-main.tex}"
PROJECT_ROOT="${2:-$BASE_DIR}"
TEX_BIN="${3:-}"
ROOT=''
BUILD=''
STEM=''

report_failure() {
  local message="$1" rc="${2:-1}"
  if [[ -n "$BUILD" ]]; then
    mkdir -p "$BUILD" 2>/dev/null || :
    { printf 'FAILED %s\n' "$(date '+%F %T')"; printf '%s\n' "$message"; printf 'Inspect latexmk.stdout.log, latexmk.stderr.log and the TeX .log file.\n'; } > "$BUILD/last-build-status.txt" 2>/dev/null || :
  fi
  printf '[CleanBuild ERROR] %s\n' "$message" >&2
  exit "$rc"
}

archive_root_aux() {
  local name ext file dir target n
  dir="$BUILD/legacy/$(date +%Y%m%d-%H%M%S)-$$"
  shopt -s nullglob
  for file in "$ROOT"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    name=$(basename -- "$file")
    [[ "$name" == "$STEM".* ]] || continue
    ext=${name#"$STEM".}
    case "$ext" in
      aux|log|out|toc|synctex|synctex.gz|fls|fdb_latexmk|xdv|dvi|ps|bbl|bcf|blg|run.xml|lof|lot|lol|nav|snm|vrb|idx|ind|ilg|acn|acr|alg|glg|glo|gls|ist|nlo|nls|thm|maf|mtc|mtc0|spl|brf)
        mkdir -p "$dir" || continue
        target="$dir/$name"; n=0
        while [[ -e "$target" ]]; do n=$((n+1)); target="$dir/$name.$n"; done
        mv -- "$file" "$target" 2>/dev/null || :
        ;;
    esac
  done
  shopt -u nullglob
}

mirror_include_dirs() {
  local sub rel count=0
  # TeX's -output-directory can write subfolder auxiliary files for \include{}.
  while IFS= read -r -d '' sub; do
    rel="${sub#"$ROOT"/}"
    [[ "$rel" != "$sub" ]] || continue
    mkdir -p "$BUILD/$rel" || :
    count=$((count + 1))
    ((count < 600)) || break
  done < <(find "$ROOT" -maxdepth 7 \( -type d \( -name build -o -name .vscode -o -name .git -o -name node_modules -o -name .venv -o -name dist -o -name target \) -prune \) -o \( -type d -mindepth 1 -print0 \) 2>/dev/null)
}

[[ -d "$PROJECT_ROOT" ]] || report_failure "Missing project directory: $PROJECT_ROOT"
if [[ "$MAIN_FILE" = /* ]]; then SRC="$MAIN_FILE"; else SRC="$PROJECT_ROOT/$MAIN_FILE"; fi
[[ -f "$SRC" && "$SRC" == *.tex ]] || report_failure "Missing LaTeX source: $SRC"
SRC_DIR=$(cd -- "$(dirname -- "$SRC")" && pwd -P) || report_failure "Cannot resolve LaTeX source directory"
SRC="$SRC_DIR/$(basename -- "$SRC")"
ROOT="$SRC_DIR"
STEM="$(basename -- "$SRC" .tex)"
LEAF="$(basename -- "$SRC")"
[[ "$ROOT" != */build ]] || report_failure 'The LaTeX source must not be inside build/.'
BUILD="$ROOT/build"
if [[ -e "$BUILD" && ! -d "$BUILD" ]]; then report_failure "build is a file, not a directory: $BUILD"; fi
mkdir -p "$BUILD" || report_failure "Cannot create build directory: $BUILD"

# Serialize competing builds when util-linux flock is available.
if command -v flock >/dev/null 2>&1; then
  exec 9> "$BUILD/.build.lock"
  flock -w 120 9 || report_failure 'Another compilation is still running (build lock timeout).'
fi

if [[ -n "$TEX_BIN" && -d "$TEX_BIN" ]]; then export PATH="$TEX_BIN:$PATH"; fi
LATEXMK=$(type -P latexmk 2>/dev/null || type -P latexmk.exe 2>/dev/null || true)
if [[ -z "$LATEXMK" ]]; then report_failure 'latexmk missing. Check TeX installation and PATH.'; fi
if ! type -P xelatex >/dev/null 2>&1 && ! type -P xelatex.exe >/dev/null 2>&1; then
  report_failure 'xelatex missing. Check TeX installation and PATH.'
fi
mirror_include_dirs
archive_root_aux
INPUT="$LEAF"
[[ "$INPUT" != -* ]] || INPUT="./$INPUT"
(cd "$ROOT" && "$LATEXMK" -norc -pdfxe -synctex=1 -interaction=nonstopmode -file-line-error -halt-on-error -outdir=build -auxdir=build "$INPUT") > "$BUILD/latexmk.stdout.log" 2> "$BUILD/latexmk.stderr.log"
RC=$?
archive_root_aux
if (( RC != 0 )); then report_failure "latexmk failed (exit $RC); inspect $BUILD/latexmk.stdout.log" "$RC"; fi
if [[ ! -s "$BUILD/$STEM.pdf" ]]; then report_failure "Missing PDF: $BUILD/$STEM.pdf"; fi

# Publish from build/ in a single rename, keeping the old good root PDF on failure.
PUBLISH_TEMP="$BUILD/.publish-$STEM-$$.pdf"
cp -f -- "$BUILD/$STEM.pdf" "$PUBLISH_TEMP" || report_failure 'Could not stage the final PDF.'
mv -f -- "$PUBLISH_TEMP" "$ROOT/$STEM.pdf" || report_failure 'Could not publish the final PDF.'
{
  printf 'SUCCESS %s\n' "$(date '+%F %T')"
  printf 'PDF: %s\n' "$ROOT/$STEM.pdf"
} > "$BUILD/last-build-status.txt"
exit 0
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
    'args': ['%DIR%/.vscode/build-latex.sh', '%DOC_EXT%', '%DIR%', os.environ['LATEX_SETUP_TEX_BIN']],
    'cwd': '%DIR%',
}]
settings['latex-workshop.latex.recipes'] = [{
    'name': 'XeLaTeX | silent clean build + root PDF',
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
  "latex-workshop.latex.recipes": [{"name":"XeLaTeX | silent clean build + root PDF","tools":["permanent-silent-xelatex-bash"]}],
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
  [[ ! -e "$BUILD_DIR" || -d "$BUILD_DIR" ]] || { fail "build is a file: $BUILD_DIR"; return 1; }
  mkdir -p "$BUILD_DIR" || { fail "Cannot create $BUILD_DIR"; return 1; }
  STATUS_LOG="$BUILD_DIR/setup-latex-status.log"
  printf 'LaTeX Once-Setup V6 (Bash) - %s\n' "$(date '+%F %T')" > "$STATUS_LOG"
  log "Source: ${SOURCE_FILE:-none (diagnostic only)}"
  log "Build folder: $BUILD_DIR"
  resolve_tools || return 1
  test_toolchain || return 1
  if ((DIAGNOSE==1)); then
    STAGE='diagnosis complete'
    log '[OK] Environment tested; no user document compiled.'
    return 0
  fi
  STAGE='preparing permanent build configuration'
  install_runner || { fail 'Could not install permanent build script.'; return 1; }
  if ((NO_SETTINGS==0)); then
    update_settings "$SOURCE_DIR" || { fail 'Could not configure project VS Code settings.'; return 1; }
    local parent
    parent=$(dirname -- "$SOURCE_DIR")
    if [[ "$parent" != / && -d "$parent/.vscode" ]]; then
      update_settings "$parent" || { fail 'Could not configure existing parent VS Code workspace.'; return 1; }
    fi
  fi
  archive_initial_aux "$(basename -- "$SOURCE_FILE" .tex)"
  STAGE='compiling user document'
  bash "$SOURCE_DIR/.vscode/build-latex.sh" "$SOURCE_FILE" "$SOURCE_DIR" "$DETECTED_BIN" > "$BUILD_DIR/setup-compile.stdout.log" 2> "$BUILD_DIR/setup-compile.stderr.log"
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

main "$@"
rc=$?
if ((rc==0)); then write_report PASS 'Completed successfully'; else write_report FAIL 'See status log and stderr'; fi
exit "$rc"
