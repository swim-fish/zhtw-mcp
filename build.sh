#!/usr/bin/env bash
# Ubuntu/Linux Bash port of the top-level Makefile and build.ps1.

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT
readonly BINARY_NAME="zhtw-mcp"
readonly RELEASE_BIN="$REPO_ROOT/target/release/$BINARY_NAME"
readonly S2T_DATA="$REPO_ROOT/src/engine/s2t_data.rs"
readonly OPENCC_DIR="$REPO_ROOT/data/opencc"
readonly GEN_SCRIPT="$REPO_ROOT/scripts/gen-s2t-tables.py"
readonly CHECK_SCRIPT="$REPO_ROOT/scripts/check-ruleset.py"
readonly MAX_SIZE_BYTES=$((20 * 1024 * 1024))

usage() {
    cat <<'EOF'
Usage: ./build.sh [target] [--yes]

Targets:
  all          Generate s2t_data.rs if needed, then build the release binary.
  clean        Remove Cargo build artifacts.
  distclean    Clean and remove generated S2T/OpenCC data.
  check        Run tests, Clippy, formatting checks, and ruleset linting.
  check-size   Build and verify that the release binary is at most 20 MiB.
  indent       Format Rust and Python sources and normalize the ruleset.
  corpus       Run the corpus evaluation test with output enabled.
  install      Build, install, and register detected MCP clients.
  uninstall    Remove the installed binary and MCP registrations.
  status       Report binary, process, and MCP registration state.
  ext-chrome   Build the Chrome extension WASM bundle.
  help         Show this help.

Options:
  -y, --yes    Skip the uninstall confirmation prompt.

The default target is "all".
EOF
}

die() {
    printf '[ERROR]  %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found on PATH."
}

get_python() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
    elif command -v python >/dev/null 2>&1; then
        command -v python
    else
        die "Python 3 is required but was not found on PATH."
    fi
}

ensure_s2t_data() {
    if [[ -f "$S2T_DATA" && ! "$GEN_SCRIPT" -nt "$S2T_DATA" ]]; then
        return
    fi

    printf '[INFO]   Generating %s\n' "$S2T_DATA"
    "$(get_python)" "$GEN_SCRIPT"
    require_command rustfmt
    rustfmt "$S2T_DATA"
}

invoke_all() {
    ensure_s2t_data
    require_command cargo
    cargo build --release
}

invoke_clean() {
    require_command cargo
    cargo clean
}

invoke_distclean() {
    invoke_clean
    rm -f -- "$S2T_DATA"
    rm -rf -- "$OPENCC_DIR"
}

invoke_check() {
    ensure_s2t_data
    require_command cargo
    cargo test
    cargo clippy -- -D warnings
    cargo fmt --check
    "$(get_python)" "$CHECK_SCRIPT" --lint
}

invoke_check_size() {
    invoke_all
    [[ -f "$RELEASE_BIN" ]] || die "Release binary not found at $RELEASE_BIN"

    local size
    size="$(stat --format='%s' "$RELEASE_BIN")"
    if ((size > MAX_SIZE_BYTES)); then
        die "FAIL: release binary $size bytes exceeds 20 MiB budget ($MAX_SIZE_BYTES)"
    fi
    printf '[INFO]   OK: release binary %s bytes (budget: %s)\n' "$size" "$MAX_SIZE_BYTES"
}

invoke_indent() {
    ensure_s2t_data
    require_command cargo
    cargo fmt

    local python
    python="$(get_python)"
    "$python" "$CHECK_SCRIPT"
    "$python" "$CHECK_SCRIPT" --lint

    require_command black
    local scripts=("$REPO_ROOT"/scripts/*.py)
    ((${#scripts[@]} == 0)) || black "${scripts[@]}"
}

invoke_corpus() {
    ensure_s2t_data
    require_command cargo
    cargo test --test corpus-evaluation -- --nocapture
}

invoke_ext_chrome() {
    require_command rustup
    require_command wasm-pack
    ensure_s2t_data

    if ! rustup target list --installed | grep -Fxq 'wasm32-unknown-unknown'; then
        rustup target add wasm32-unknown-unknown
    fi

    wasm-pack build "$REPO_ROOT" \
        --target web \
        --out-dir extension/dist \
        --out-name zhtw_mcp_wasm \
        --no-opt \
        --no-default-features \
        --features browser-wasm
}

invoke_deploy() {
    local action="$1"
    shift
    "$REPO_ROOT/scripts/deploy.sh" "$action" "$@"
}

main() {
    local target="${1:-all}"
    [[ $# -eq 0 ]] || shift

    cd -- "$REPO_ROOT"

    case "$target" in
        all)        [[ $# -eq 0 ]] || die "Target 'all' does not accept arguments."; invoke_all ;;
        clean)      [[ $# -eq 0 ]] || die "Target 'clean' does not accept arguments."; invoke_clean ;;
        distclean)  [[ $# -eq 0 ]] || die "Target 'distclean' does not accept arguments."; invoke_distclean ;;
        check)      [[ $# -eq 0 ]] || die "Target 'check' does not accept arguments."; invoke_check ;;
        check-size) [[ $# -eq 0 ]] || die "Target 'check-size' does not accept arguments."; invoke_check_size ;;
        indent)     [[ $# -eq 0 ]] || die "Target 'indent' does not accept arguments."; invoke_indent ;;
        corpus)     [[ $# -eq 0 ]] || die "Target 'corpus' does not accept arguments."; invoke_corpus ;;
        install)
            [[ $# -eq 0 ]] || die "Target 'install' does not accept arguments."
            invoke_all
            invoke_deploy install
            ;;
        uninstall)
            case "${1:-}" in
                "")         invoke_deploy uninstall ;;
                -y|--yes)   [[ $# -eq 1 ]] || die "Too many arguments for 'uninstall'."; invoke_deploy uninstall --yes ;;
                *)          die "Unknown uninstall option: $1" ;;
            esac
            ;;
        status)     [[ $# -eq 0 ]] || die "Target 'status' does not accept arguments."; invoke_deploy status ;;
        ext-chrome) [[ $# -eq 0 ]] || die "Target 'ext-chrome' does not accept arguments."; invoke_ext_chrome ;;
        help|-h|--help) usage ;;
        *) die "Unknown target: $target. Run './build.sh help' for usage." ;;
    esac
}

main "$@"
