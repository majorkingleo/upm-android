#!/usr/bin/env bash
#
# install-on-device.sh — build the debug APK and install it on a physical device.
#
#   scripts/install-on-device.sh                  # the only device attached
#   scripts/install-on-device.sh --launch         # and start the app afterwards
#   scripts/install-on-device.sh --serial <id>    # pick one of several devices
#
# Emulators are ignored on purpose: for those there is scripts/emulator-run.sh,
# which also boots and configures one. The device list decides the serial, because
# both adb and Gradle refuse to choose once a second device is attached.
#
# Installing keeps the app's data — the account database survives.

set -euo pipefail

APP_ID="com.u17od.upm"
ACTIVITY="${APP_ID}/.AppEntryActivity"

# The Android Gradle Plugin does not accept JDK 25, and this machine has it too.
JAVA_HOME_ANDROID="/usr/lib/jvm/java-21-openjdk"

SERIAL=""
LAUNCH=0

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '[error] %s\n' "$*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --launch) LAUNCH=1 ;;
        --serial)
            shift
            (( $# )) || die "--serial needs a device id"
            SERIAL="$1"
            ;;
        *) die "unknown option: $1 (see the header of this script)" ;;
    esac
    shift
done

cd "$(dirname "$0")/.."
command -v adb >/dev/null 2>&1 || die "adb is not on PATH — install android-tools"

# The id of the one attached device, or a reason why there is no clear choice.
pick_serial() {
    local found count
    found="$(adb devices | awk '$1 !~ /^emulator-/ && $2 == "device" { print $1 }')"
    count="$(printf '%s\n' "$found" | grep -c '^[^[:space:]]' || true)"

    if (( count == 0 )); then
        adb devices -l >&2
        die "no physical device is ready — unlock it, confirm the USB prompt, and try again
      for an emulator instead: scripts/emulator-run.sh"
    fi
    if (( count > 1 )); then
        printf '%s\n' "$found" >&2
        die "more than one device is attached — pass --serial"
    fi
    printf '%s' "$found"
}

if [[ -z "$SERIAL" ]]; then
    SERIAL="$(pick_serial)"
else
    state="$(adb -s "$SERIAL" get-state 2>/dev/null || true)"
    [[ "$state" == "device" ]] || die "$SERIAL is not ready (adb says: ${state:-unknown})"
fi

model="$(adb -s "$SERIAL" shell getprop ro.product.model | tr -d '\r\n')"
release="$(adb -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r\n')"
step "Device $SERIAL"
info "$model, Android $release"

step "Installing the debug build"
# ANDROID_SERIAL names the device for Gradle too; it refuses to pick one itself.
env JAVA_HOME="$JAVA_HOME_ANDROID" ANDROID_SERIAL="$SERIAL" ./gradlew --console=plain installDebug
APK="$(find build/outputs/apk/debug -name '*.apk' -print -quit 2>/dev/null || true)"
info "APK: ${APK:-unknown}"

if (( LAUNCH )); then
    step "Starting the app"
    adb -s "$SERIAL" shell am start -n "$ACTIVITY" >/dev/null
    info "started $ACTIVITY"
fi

step "Done"
