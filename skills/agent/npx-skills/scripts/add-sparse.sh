#!/usr/bin/env bash
# Install skills from a large repository through a partial, sparse git clone.
set -euo pipefail

die() { printf 'add-sparse: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: add-sparse.sh --source <source> --sparse <path> --skill <name> [options]

Runs `npx skills add` with a temporary PATH git wrapper that clones with
--filter=blob:none --sparse and checks out only the given paths.

Required:
  --source <source>    GitHub URL, owner/repo, or any git URL
  --sparse <path>      Repo-relative directory to check out; repeatable
  --skill <name>       Skill name to install; repeatable

Options:
  --mirror <prefix>    Transport prefix, e.g. https://ghfast.top/https://github.com/
                       (default: empty; never written to the lock)
  --agent <agent>      Target agent directories (default: codex)
  -g, --global         Install for the user instead of the project
  --timeout-ms <n>     SKILLS_CLONE_TIMEOUT_MS for the CLI (default: 600000)
  --dry-run            Print the resolved command without running it
  -h, --help           Show this help
EOF
}

value() {
  [ $# -ge 2 ] || die "$1 needs a value"
  printf '%s' "$2"
}

source=""
sparse=()
skills=()
mirror=""
agent=codex
timeout_ms=600000
global=0
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --source) source=$(value "$@"); shift 2 ;;
    --sparse) sparse+=("$(value "$@")"); shift 2 ;;
    --skill) skills+=("$(value "$@")"); shift 2 ;;
    --mirror) mirror=$(value "$@"); shift 2 ;;
    --agent) agent=$(value "$@"); shift 2 ;;
    --timeout-ms) timeout_ms=$(value "$@"); shift 2 ;;
    -g | --global) global=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$source" ] || die "--source is required"
[ ${#sparse[@]} -gt 0 ] || die "--sparse is required"
[ ${#skills[@]} -gt 0 ] || die "--skill is required"
[ -n "$agent" ] || die "--agent cannot be empty"

case "$timeout_ms" in
  '' | *[!0-9]*) die "--timeout-ms must be a positive integer: $timeout_ms" ;;
esac

for path in "${sparse[@]}"; do
  case "$path" in
    '' | /* | .. | ../* | */.. | */../*)
      die "--sparse must be a repo-relative path: $path" ;;
    *[[:space:]]*)
      die "--sparse paths cannot contain whitespace: $path" ;;
  esac
done

if [ -n "$mirror" ]; then
  case "$mirror" in
    */) ;;
    *) mirror="$mirror/" ;;
  esac
fi

real_git=$(command -v git) || die "git not found in PATH"

cmd=(npx --yes skills add "$source")
for skill in "${skills[@]}"; do
  cmd+=(-s "$skill")
done
cmd+=(-a "$agent" -y)
if [ "$global" -eq 1 ]; then
  cmd+=(-g)
fi

sparse_paths="${sparse[*]}"

if [ "$dry_run" -eq 1 ]; then
  printf 'PATH=<wrapper-dir>:$PATH REAL_GIT=%q GIT_SPARSE_PATHS=%q MIRROR_PREFIX=%q SKILLS_CLONE_TIMEOUT_MS=%q ' \
    "$real_git" "$sparse_paths" "$mirror" "$timeout_ms"
  printf '%q ' "${cmd[@]}"
  printf '\n'
  exit 0
fi

wrap=$(mktemp -d "${TMPDIR:-/tmp}/npx-skills-wrap.XXXXXX")
trap 'rm -rf "$wrap"' EXIT

cat > "$wrap/git" <<'WRAPPER'
#!/usr/bin/env bash
set -u

: "${REAL_GIT:?REAL_GIT is not set}"
: "${GIT_SPARSE_PATHS:?GIT_SPARSE_PATHS is not set}"
MIRROR=${MIRROR_PREFIX:-}

cfg=()
if [ -n "$MIRROR" ]; then
  cfg=(-c "url.$MIRROR.insteadOf=https://github.com/")
fi

out=()
is_clone=0
for a in "$@"; do
  out+=("$a")
  if [ "$a" = "clone" ]; then
    is_clone=1
    out+=(--filter=blob:none --sparse)
  fi
done

if [ "$is_clone" -eq 0 ]; then
  exec "$REAL_GIT" "${cfg[@]}" "$@"
fi

"$REAL_GIT" "${cfg[@]}" "${out[@]}"
rc=$?
dir="${out[${#out[@]}-1]}"
if [ "$rc" -eq 0 ] && [ -d "$dir/.git" ]; then
  # shellcheck disable=SC2086  # one or more repo-relative paths, split on purpose
  "$REAL_GIT" "${cfg[@]}" -C "$dir" sparse-checkout set $GIT_SPARSE_PATHS
fi
exit "$rc"
WRAPPER
chmod +x "$wrap/git"

PATH="$wrap:$PATH" \
  REAL_GIT="$real_git" \
  GIT_SPARSE_PATHS="$sparse_paths" \
  MIRROR_PREFIX="$mirror" \
  SKILLS_CLONE_TIMEOUT_MS="$timeout_ms" \
  "${cmd[@]}"
