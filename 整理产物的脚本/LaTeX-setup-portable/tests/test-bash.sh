#!/usr/bin/env bash
# Portable logic tests with simulated TeX. This is NOT a native Linux TeX test.
set -euo pipefail
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/latex-bash-tests.XXXXXXXX")
trap 'case "$TEST_ROOT" in "${TMPDIR:-/tmp}"/latex-bash-tests.*) rm -rf -- "$TEST_ROOT" ;; esac' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/项目 空格(甲)/chapters"
BIN="$TEST_ROOT/bin"; PROJECT="$TEST_ROOT/项目 空格(甲)"
cat > "$BIN/latexmk" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
last=''
for arg in "$@"; do last="$arg"; done
[[ " $* " == *' -outdir=build '* ]] || exit 77
[[ " $* " == *' -norc '* ]] || exit 78
stem=$(basename -- "$last" .tex)
mkdir -p build
printf 'simulated stdout\n'; printf 'simulated stderr\n' >&2
if grep -q 'FAIL_TEST' "$last"; then exit 12; fi
if [[ ! -s "build/$stem.pdf" || "$last" -nt "build/$stem.pdf" ]]; then
 printf '%%PDF-simulation %s\n' "$(cat "$last")" > "build/$stem.pdf"
fi
printf 'aux\n' > "build/$stem.aux"
printf 'sync\n' > "build/$stem.synctex.gz"
MOCK
for tool in xelatex xdvipdfmx; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$tool"; done
if ! command -v flock >/dev/null; then
 printf '#!/usr/bin/env bash\n# MOCK ONLY: Git Bash has no native Linux flock.\nexit 0\n' > "$BIN/flock"
 printf 'NOTE: flock is simulated; locking is not validated by this run.\n'
fi
chmod 755 "$BIN/"*
export PATH="$BIN:$PATH" LATEX_SETUP_NO_PAUSE=1
printf '\\documentclass{article}\n\\begin{document}Hello\\end{document}\n' > "$PROJECT/main.tex"
printf 'old aux\n' > "$PROJECT/chapters/old.aux"
cp -- "$REPO/setup-latex.sh" "$PROJECT/setup-latex.sh"
bash "$PROJECT/setup-latex.sh" --tex-bin "$BIN" --project-only --no-pause > "$TEST_ROOT/setup.log" 2>&1 || { cat "$TEST_ROOT/setup.log"; exit 1; }
[[ -s "$PROJECT/main.pdf" && -s "$PROJECT/build/main.pdf" && -f "$PROJECT/.vscode/settings.json" ]]
[[ ! -f "$PROJECT/chapters/old.aux" ]]
printf 'PASS: Bash standalone setup, output placement, settings, legacy archive (simulated TeX)\n'
rm -- "$PROJECT/setup-latex.sh"
[[ "$PROJECT/build" == "$TEST_ROOT/"*/build ]] || exit 90
rm -rf -- "$PROJECT/build"; rm -- "$PROJECT/main.pdf"
bash "$PROJECT/.vscode/build-latex.sh"
[[ -s "$PROJECT/main.pdf" && -s "$PROJECT/build/main.synctex.gz" ]]
before=$(cksum < "$PROJECT/main.pdf")
printf 'FAIL_TEST\n' >> "$PROJECT/main.tex"
set +e
bash "$PROJECT/.vscode/build-latex.sh"
rc=$?
set -e
[[ "$rc" == 12 && "$(cksum < "$PROJECT/main.pdf")" == "$before" ]]
grep -q 'FAILED exit=12' "$PROJECT/build/last-build-status.txt"
printf 'PASS: Bash rebuild without installer/build; failure status and PDF preservation (simulated TeX)\n'
bash "$PROJECT/.vscode/build-latex.sh" '' "$PROJECT" '' clean
[[ -f "$PROJECT/main.pdf" && -f "$PROJECT/build/main.pdf" && ! -f "$PROJECT/build/main.aux" ]]
bash "$PROJECT/.vscode/build-latex.sh" '' "$PROJECT" '' clean-all
[[ -f "$PROJECT/main.pdf" && ! -f "$PROJECT/build/main.pdf" && -f "$PROJECT/build/latexmk.stdout.log" ]]
printf 'PASS: Bash clean and clean-all preserve published PDF and diagnostics (simulated TeX)\n'
printf 'ALL PASSED: 3 simulated Bash groups; native Linux/WSL validation still required\n'
