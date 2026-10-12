#!/usr/bin/env bash
#
# emulator-run.sh — boot the Android emulator with the app installed and running.
#
#   scripts/emulator-run.sh                 # create the AVD if needed, boot, install, launch
#   scripts/emulator-run.sh --create-only   # only create the AVD
#   scripts/emulator-run.sh --stop          # shut the running emulator down
#   scripts/emulator-run.sh --avd NAME      # use a different AVD
#
# The emulator is started detached on purpose: this script (and the VS Code task
# that calls it) has to finish after installing, while the emulator keeps
# running. That is also why closing it needs `--stop` or `adb emu kill` rather
# than the terminal the script was started from.
#
# Toolchain: run scripts/install-android-toolchain.sh first.

set -euo pipefail

AVD_NAME="upm-api36"
SYSTEM_IMAGE="system-images;android-36;google_apis;x86_64"
DEVICE_PROFILE="pixel_10"
APP_ID="com.u17od.upm"
ACTIVITY="${APP_ID}/.AppEntryActivity"
BOOT_TIMEOUT=300

# Cold boot only, so a snapshot left behind by an abrupt shutdown cannot break
# the next start. GPU: the host default (gfxstream) crashes this emulator during
# boot, and plain `swiftshader_indirect` boots but never renders the IME window
# (isVisible=true, HAS_DRAWN, no keyboard on screen), so ANGLE is the default.
# Override with EMULATOR_GPU=… — a test that needs no keyboard can use
# `swiftshader_indirect`, which is the more stable of the two.
EMULATOR_GPU="${EMULATOR_GPU:-angle_indirect}"
EMULATOR_FLAGS=(-no-boot-anim -no-snapshot -gpu "$EMULATOR_GPU")

# The Android Gradle Plugin does not accept JDK 25, and this machine has it too.
JAVA_HOME_ANDROID="/usr/lib/jvm/java-21-openjdk"

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
AVDMANAGER="${ANDROID_HOME}/cmdline-tools/latest/bin/avdmanager"
EMULATOR="${ANDROID_HOME}/emulator/emulator"
EMULATOR_LOG="${TMPDIR:-/tmp}/upm-emulator.log"

CREATE_ONLY=0
STOP=0

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '[error] %s\n' "$*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --create-only) CREATE_ONLY=1 ;;
        --stop) STOP=1 ;;
        --avd)
            shift
            (( $# )) || die "--avd needs a name"
            AVD_NAME="$1"
            ;;
        *) die "unknown option: $1 (try --help in the script header)" ;;
    esac
    shift
done

cd "$(dirname "$0")/.."
command -v adb >/dev/null 2>&1 || die "adb is not on PATH — install android-tools"
[[ -x "$EMULATOR" ]] || die "no emulator at $EMULATOR — run scripts/install-android-toolchain.sh"

avd_exists() { "$EMULATOR" -list-avds | grep -qx "$AVD_NAME"; }

create_avd() {
    if avd_exists; then
        info "AVD '$AVD_NAME' already exists"
        return 0
    fi

    [[ -x "$AVDMANAGER" ]] || die "no avdmanager at $AVDMANAGER"
    local image_dir="${ANDROID_HOME}/$(printf '%s' "$SYSTEM_IMAGE" | tr ';' '/')"
    if [[ ! -d "$image_dir" ]]; then
        die "system image missing: $image_dir
      install it with scripts/install-android-toolchain.sh, or:
      sdkmanager '$SYSTEM_IMAGE'"
    fi

    step "Creating AVD '$AVD_NAME'"
    # avdmanager asks whether a custom hardware profile should be defined; "no"
    # keeps the device profile passed in with --device.
    echo "no" | env JAVA_HOME="$JAVA_HOME_ANDROID" "$AVDMANAGER" create avd \
        --name "$AVD_NAME" \
        --package "$SYSTEM_IMAGE" \
        --device "$DEVICE_PROFILE" \
        --force
    info "created from $SYSTEM_IMAGE on $DEVICE_PROFILE"
}

emulator_serial() {
    # Any state counts, including "offline" while it is still booting.
    adb devices | awk '$1 ~ /^emulator-/ { print $1; exit }'
}

device_state() {
    adb devices | awk -v serial="$1" '$1 == serial { print $2; exit }'
}

stop_emulator() {
    local serial
    serial="$(emulator_serial)"
    if [[ -z "$serial" ]]; then
        info "no emulator is running"
        return 0
    fi
    step "Stopping $serial"
    adb -s "$serial" emu kill
    info "the emulator shuts down on its own; check with: adb devices"
}

boot_emulator() {
    local serial
    serial="$(emulator_serial)"
    if [[ -n "$serial" ]]; then
        info "an emulator is already running ($serial)"
    else
        step "Starting the emulator"
        local launcher=(nohup)
        if command -v setsid >/dev/null 2>&1; then
            launcher=(setsid nohup)
        fi
        "${launcher[@]}" "$EMULATOR" -avd "$AVD_NAME" "${EMULATOR_FLAGS[@]}" \
            >"$EMULATOR_LOG" 2>&1 </dev/null &
        info "log: $EMULATOR_LOG"
    fi

    step "Waiting for boot (max ${BOOT_TIMEOUT}s)"
    # Not `adb wait-for-device`: that returns as soon as *any* device is ready,
    # and a phone plugged in next to the emulator satisfies it immediately.
    local waited=0
    while [[ -z "$serial" ]]; do
        if (( waited >= BOOT_TIMEOUT )); then
            die "adb never saw an emulator — see $EMULATOR_LOG"
        fi
        sleep 5
        waited=$(( waited + 5 ))
        serial="$(emulator_serial)"
        printf '.'
    done
    [[ -n "$serial" ]] || die "adb does not see an emulator — see $EMULATOR_LOG"

    # Both have to hold: adb calls it "device", and the guest finished booting.
    # An emulator that died on the way is reported instead of waited for.
    local waited=0
    until [[ "$(device_state "$serial")" == "device" \
        && "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')" == "1" ]]; do
        if [[ -z "$(emulator_serial)" ]]; then
            die "the emulator disappeared while booting — see $EMULATOR_LOG"
        fi
        if (( waited >= BOOT_TIMEOUT )); then
            die "the emulator did not finish booting in ${BOOT_TIMEOUT}s — see $EMULATOR_LOG"
        fi
        sleep 5
        waited=$(( waited + 5 ))
        printf '.'
    done
    printf '\n'
    info "booted after ${waited}s, adb reports $serial as 'device'"
}

install_and_launch() {
    local serial
    serial="$(emulator_serial)"
    [[ -n "$serial" ]] || die "no emulator to install on"

    step "Installing the debug build"
    # ANDROID_SERIAL keeps the install on the emulator when a phone is attached
    # as well: Gradle refuses to choose between two devices.
    env JAVA_HOME="$JAVA_HOME_ANDROID" ANDROID_SERIAL="$serial" \
        ./gradlew --console=plain installDebug

    step "Starting the app"
    # Explicit -s for the same reason: a bare `adb shell` is ambiguous then.
    adb -s "$serial" shell am start -n "$ACTIVITY" >/dev/null
    info "started $ACTIVITY on $serial"
    info "screenshot: adb exec-out screencap -p > /tmp/emulator.png"
}

main() {
    if (( STOP )); then
        stop_emulator
        return 0
    fi
    create_avd
    if (( CREATE_ONLY )); then
        info "--create-only: stopping before the emulator starts"
        return 0
    fi
    boot_emulator
    install_and_launch
    step "Done"
    info "the emulator keeps running; UPM is installed and started"
}

main "$@"
