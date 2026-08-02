#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKTREE_NAME="$(basename "$(dirname "$REPO_ROOT")")"
TEMP_BASE="${TMPDIR:-/tmp}"
TEST_HOME="$(mktemp -d "${TEMP_BASE%/}/cctop-tests-${WORKTREE_NAME}.XXXXXX")"
TEST_RUN_ID="$TEST_HOME"
TEST_HOST_APP="$REPO_ROOT/menubar/build/Build/Products/Debug/CctopMenubar.app"
TEST_HOST_EXECUTABLE="$TEST_HOST_APP/Contents/MacOS/CctopMenubar"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
test_started=0

test_host_pids() {
    /bin/ps eww -axo pid=,command= 2>/dev/null \
        | /usr/bin/awk -v executable="$TEST_HOST_EXECUTABLE" -v run_id="CCTOP_XCODE_TEST_RUN_ID=$TEST_RUN_ID" '
            {
                pid = $1
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                executable_matches = index($0, executable) == 1 &&
                    (length($0) == length(executable) || substr($0, length(executable) + 1, 1) == " ")
            }
            executable_matches && index($0, run_id) {
                print pid
            }
        '
}

any_test_host_pids() {
    /bin/ps eww -axo pid=,command= 2>/dev/null \
        | /usr/bin/awk -v executable="$TEST_HOST_EXECUTABLE" '
            {
                pid = $1
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                executable_matches = index($0, executable) == 1 &&
                    (length($0) == length(executable) || substr($0, length(executable) + 1, 1) == " ")
            }
            executable_matches &&
                (index($0, "CCTOP_XCODE_TEST_HOST=1") || index($0, "XCTestConfigurationFilePath=")) {
                print pid
            }
        '
}

wait_for_test_host_exit() {
    local attempt
    local pids
    for attempt in {1..20}; do
        pids="$(test_host_pids)"
        [[ -z "$pids" ]] && return 0
        sleep 0.1
    done
    return 1
}

cleanup() {
    local command_status=$?
    local cleanup_status=0
    local pids
    trap - EXIT
    set +e

    pids="$(test_host_pids)"
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null
        if ! wait_for_test_host_exit; then
            pids="$(test_host_pids)"
            kill -KILL $pids 2>/dev/null
            wait_for_test_host_exit || cleanup_status=1
        fi
    fi

    # Xcode can register this exact shared test-host bundle while launching it. Remove that registration;
    # callers preserving a developer runtime must restore and verify the lane-owned app afterward.
    if [[ $test_started -eq 1 && -x "$LSREGISTER" && -d "$TEST_HOST_APP" ]]; then
        "$LSREGISTER" -u "$TEST_HOST_APP" >/dev/null 2>&1 || cleanup_status=1
    fi

    case "$TEST_HOME" in
        "${TEMP_BASE%/}"/cctop-tests-*) rm -rf -- "$TEST_HOME" || cleanup_status=1 ;;
        *) cleanup_status=1 ;;
    esac

    if [[ $command_status -ne 0 ]]; then
        exit "$command_status"
    fi
    exit "$cleanup_status"
}
trap cleanup EXIT

if [[ "$#" -lt 9 || "$1" != "test" ]]; then
    echo "run-swift-tests-isolated.sh only supports the repository Debug test invocation" >&2
    exit 2
fi

project=""
scheme=""
configuration=""
derived_data=""
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index++)); do
    argument="${arguments[$index]}"
    case "$argument" in
        test|CODE_SIGN_IDENTITY=-|-only-testing:*|-skip-testing:*) ;;
        -project|-scheme|-configuration|-derivedDataPath)
            ((++index))
            [[ $index -lt ${#arguments[@]} ]] || exit 2
            value="${arguments[$index]}"
            case "$argument" in
                -project) project="$value" ;;
                -scheme) scheme="$value" ;;
                -configuration) configuration="$value" ;;
                -derivedDataPath) derived_data="$value" ;;
            esac
            ;;
        *)
            echo "Unsupported isolated Swift test argument: $argument" >&2
            exit 2
            ;;
    esac
done

if [[ "$project" != "menubar/CctopMenubar.xcodeproj" || "$scheme" != "CctopMenubar" ||
      "$configuration" != "Debug" || "$derived_data" != "menubar/build" ]]; then
    echo "run-swift-tests-isolated.sh requires the repository CctopMenubar Debug test product" >&2
    exit 2
fi

existing_test_hosts="$(any_test_host_pids)"
if [[ -n "$existing_test_hosts" ]]; then
    echo "Refusing to start with an existing exact-path CctopMenubar test host: $existing_test_hosts" >&2
    exit 1
fi

mkdir -p "$TEST_HOME/Library/Preferences"
export HOME="$TEST_HOME"
export CFFIXED_USER_HOME="$TEST_HOME"
export CCTOP_XCODE_TEST_HOST=1
export CCTOP_XCODE_TEST_RUN_ID="$TEST_RUN_ID"
export LLVM_PROFILE_FILE="$TEST_HOME/default-%p.profraw"

cd "$REPO_ROOT"
test_started=1
xcodebuild "$@"
