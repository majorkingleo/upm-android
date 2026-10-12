#!/usr/bin/env bash
#
# install-android-toolchain.sh — Android build toolchain for upm-android
# on CachyOS / Arch Linux.
#
#   ./scripts/install-android-toolchain.sh                   # headless SDK + tools
#   ./scripts/install-android-toolchain.sh --with-studio     # + Android Studio
#   ./scripts/install-android-toolchain.sh --dry-run         # only print what would happen
#
# Run as your normal user; sudo is invoked where needed. Every step is
# idempotent, so re-running the script is safe.

set -euo pipefail

# ---------------------------------------------------------------------------
# What gets installed
# ---------------------------------------------------------------------------
REPO_PACKAGES=(jdk21-openjdk android-tools android-udev curl unzip)
JDK_DIR_NAME=java-21-openjdk

# API level the app compiles against (compileSdkVersion in build.gradle).
PLATFORM=36
BUILD_TOOLS=36.0.0

SDK_PACKAGES=(
  "platform-tools"
  "platforms;android-${PLATFORM}"
  "build-tools;${BUILD_TOOLS}"
  "cmdline-tools;latest"
)

# The emulator image matches compileSdk 36 (a plain google_apis x86_64 image).
EMULATOR_PACKAGES=(
  "emulator"
  "system-images;android-36;google_apis;x86_64"
)

REPO_XML="https://dl.google.com/android/repository/repository2-3.xml"
REPO_BASE="https://dl.google.com/android/repository"
CMDLINE_TOOLS_FALLBACK="commandlinetools-linux-16111833_latest.zip"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
WITH_STUDIO=0
EMULATOR_MODE=auto          # auto | yes | no
ASSUME_YES=0
DRY_RUN=0
SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"

TMP_DIR=""
SDKMANAGER=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
else
  BOLD=''; DIM=''; RED=''; GRN=''; YEL=''; RST=''
fi

step()    { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RST"; }
info()    { printf '    %s\n' "$*"; }
ok()      { printf '    %s%s%s\n' "$GRN" "$*" "$RST"; }
warn()    { printf '%s[warn]%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()     { printf '%s[error]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# Run a command unless --dry-run was given.
run() {
  if (( DRY_RUN )); then
    printf '    %s(dry-run)%s %s\n' "$DIM" "$RST" "$*"
    return 0
  fi
  "$@"
}

confirm() {
  (( ASSUME_YES )) && return 0
  local answer
  read -r -p "    $1 [y/N] " answer || return 1
  [[ ${answer,,} == y* ]]
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
Install the Android build toolchain for upm-android on CachyOS / Arch.

Usage: scripts/install-android-toolchain.sh [options]

Options:
  --with-studio     Also install Android Studio from the AUR.
  --with-emulator   Install emulator + system image even without /dev/kvm.
  --no-emulator     Never install emulator + system image.
  --sdk-dir DIR     Android SDK location (default: $ANDROID_HOME, $ANDROID_SDK_ROOT
                    or ~/Android/Sdk).
  --yes, -y         Do not ask anything; accept the recommended answers.
  --dry-run         Print the steps without changing the system.
  -h, --help        Show this help.

What it does, in order:
  pacman packages -> JDK 21 as default -> udev rules -> Android Studio (optional)
  -> command line tools -> SDK packages -> licenses -> emulator -> environment
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --with-studio)   WITH_STUDIO=1 ;;
      --with-emulator) EMULATOR_MODE=yes ;;
      --no-emulator)   EMULATOR_MODE=no ;;
      --sdk-dir)
        shift
        (( $# )) || die "--sdk-dir needs an argument"
        SDK_DIR="$1"
        ;;
      --yes|-y)        ASSUME_YES=1 ;;
      --dry-run)       DRY_RUN=1 ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
  SDK_DIR="${SDK_DIR/#\~/$HOME}"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
require_arch() {
  (( EUID == 0 )) && die "run this as your normal user, not as root — the SDK belongs in your home directory"
  need pacman
  # shellcheck disable=SC1091
  [[ -r /etc/os-release ]] && . /etc/os-release
  info "distro : ${PRETTY_NAME:-unknown}"
  info "SDK dir: $SDK_DIR"
  case "${ID:-}:${ID_LIKE:-}" in
    *cachyos*|*arch*) ;;
    *) warn "this script targets CachyOS/Arch — continuing anyway" ;;
  esac
}

install_repo_packages() {
  step "Repository packages"
  info "${REPO_PACKAGES[*]}"
  run sudo pacman -S --needed --noconfirm "${REPO_PACKAGES[@]}"
}

select_jdk() {
  step "JDK 21"
  local current
  current="$(archlinux-java get 2>/dev/null || true)"
  if [[ "$current" == "$JDK_DIR_NAME" ]]; then
    ok "already the system default: $current"
    return 0
  fi

  warn "system default JDK is '${current:-none}', but the Android Gradle Plugin wants JDK 21"
  [[ "$current" == java-25* ]] && warn "JDK 25 in particular is too new for the AGP/Gradle combination"

  if confirm "make $JDK_DIR_NAME the system default?"; then
    run sudo archlinux-java set "$JDK_DIR_NAME"
  else
    warn "kept '${current:-none}' — pin the build instead: org.gradle.java.home=/usr/lib/jvm/$JDK_DIR_NAME in gradle.properties"
  fi
}

setup_udev() {
  step "udev rules for USB debugging"
  run sudo udevadm control --reload-rules
  run sudo udevadm trigger

  local rules=/usr/lib/udev/rules.d/51-android.rules
  [[ -r "$rules" ]] || { warn "$rules not found — is android-udev installed?"; return 0; }

  local group
  group="$(grep -oE 'GROUP="[^"]+"' "$rules" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  [[ -n "$group" ]] || { ok "rules installed"; return 0; }
  getent group "$group" >/dev/null || { ok "rules installed (group $group does not exist)"; return 0; }

  local user
  user="$(id -un)"
  if id -nG "$user" | tr ' ' '\n' | grep -qx "$group"; then
    ok "$user is already in group '$group'"
  else
    warn "$user is not in group '$group' — adb needs root until you re-login"
    if confirm "add $user to group $group?"; then
      run sudo usermod -aG "$group" "$user"
      warn "log out and back in for the new group to take effect"
    fi
  fi
}

aur_helper() {
  local helper
  for helper in paru yay; do
    command -v "$helper" >/dev/null 2>&1 && { printf '%s' "$helper"; return 0; }
  done
  return 1
}

install_studio() {
  (( WITH_STUDIO )) || return 0
  step "Android Studio (AUR)"
  local aur
  aur="$(aur_helper)" || die "no AUR helper found (paru/yay) — install one or drop --with-studio"
  info "android-studio is AUR-only here; JetBrains Toolbox is the alternative"
  run "$aur" -S --needed --noconfirm android-studio
  info "Android Studio ships its own JBR (JDK 21) and manages the same SDK dir"
}

resolve_cmdline_tools_url() {
  local zip
  zip="$(curl -fsSL "$REPO_XML" \
    | awk '/path="cmdline-tools;latest"/{found=1} found' \
    | grep -oE 'commandlinetools-linux-[0-9]+_latest\.zip' \
    | head -1 || true)"
  [[ -n "$zip" ]] || { warn "could not read the current cmdline-tools name from $REPO_XML — using the fallback"; zip="$CMDLINE_TOOLS_FALLBACK"; }
  printf '%s/%s' "$REPO_BASE" "$zip"
}

ensure_sdkmanager() {
  step "Android command line tools"
  SDKMANAGER="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
  if [[ -x "$SDKMANAGER" ]]; then
    ok "present: $SDKMANAGER"
    return 0
  fi

  local url
  url="$(resolve_cmdline_tools_url)"
  info "$url"
  if (( DRY_RUN )); then
    printf '    %s(dry-run)%s download + unpack into %s\n' "$DIM" "$RST" "$SDK_DIR/cmdline-tools/latest"
    return 0
  fi

  TMP_DIR="$(mktemp -d)"
  curl -fsSL -o "$TMP_DIR/cmdline-tools.zip" "$url"
  unzip -q "$TMP_DIR/cmdline-tools.zip" -d "$TMP_DIR"
  [[ -d "$TMP_DIR/cmdline-tools" ]] || die "unexpected archive layout in $url"

  mkdir -p "$SDK_DIR/cmdline-tools"
  rm -rf "$SDK_DIR/cmdline-tools/latest"
  mv "$TMP_DIR/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
  ok "$SDKMANAGER"
}

install_sdk_packages() {
  step "SDK licenses"
  if (( DRY_RUN )); then
    printf '    %s(dry-run)%s yes | sdkmanager --sdk_root=%s --licenses\n' "$DIM" "$RST" "$SDK_DIR"
  else
    # `yes` gets SIGPIPE once sdkmanager exits, which is expected.
    yes | "$SDKMANAGER" --sdk_root="$SDK_DIR" --licenses >/dev/null 2>&1 \
      || warn "license step reported a failure — re-run 'sdkmanager --licenses' manually"
  fi

  step "SDK packages"
  info "android-${PLATFORM}, build-tools ${BUILD_TOOLS}, platform-tools, cmdline-tools"
  run "$SDKMANAGER" --sdk_root="$SDK_DIR" --install "${SDK_PACKAGES[@]}"
}

install_emulator() {
  local has_kvm=1
  [[ -e /dev/kvm ]] || has_kvm=0

  case "$EMULATOR_MODE" in
    no) return 0 ;;
    auto)
      if (( ! has_kvm )); then
        warn "no /dev/kvm — skipping emulator and system image (use --with-emulator to force)"
        return 0
      fi
      ;;
  esac

  step "Emulator and system image"
  info "${EMULATOR_PACKAGES[*]}"
  run "$SDKMANAGER" --sdk_root="$SDK_DIR" --install "${EMULATOR_PACKAGES[@]}"

  if (( has_kvm )); then
    local user
    user="$(id -un)"
    id -nG "$user" | tr ' ' '\n' | grep -qx kvm \
      && ok "$user is in group 'kvm'" \
      || warn "$user is not in group 'kvm' — the emulator will refuse to start until you are (re-login required)"
  fi
}

write_env() {
  step "Environment"
  local conf="$HOME/.config/environment.d/android-sdk.conf"
  if (( DRY_RUN )); then
    printf '    %s(dry-run)%s write %s\n' "$DIM" "$RST" "$conf"
  elif [[ -f "$conf" ]] && grep -qF "ANDROID_HOME=$SDK_DIR" "$conf"; then
    ok "already set in $conf"
  else
    mkdir -p "$(dirname "$conf")"
    {
      printf 'ANDROID_HOME=%s\n' "$SDK_DIR"
      printf 'ANDROID_SDK_ROOT=%s\n' "$SDK_DIR"
      printf 'PATH=$PATH:%s/platform-tools:%s/cmdline-tools/latest/bin:%s/emulator\n' "$SDK_DIR" "$SDK_DIR" "$SDK_DIR"
    } > "$conf"
    ok "wrote $conf (applies to the next login)"
  fi

  cat <<EOF

    for the current fish session:
      set -Ux ANDROID_HOME $SDK_DIR
      set -Ux ANDROID_SDK_ROOT $SDK_DIR
      fish_add_path $SDK_DIR/platform-tools $SDK_DIR/cmdline-tools/latest/bin $SDK_DIR/emulator
EOF
}

summary() {
  step "Result"

  local java_now
  java_now="$(archlinux-java get 2>/dev/null || echo 'unknown')"
  if command -v java >/dev/null 2>&1; then
    info "java   : $java_now — $(java -version 2>&1 | head -1)"
  else
    warn "java not found on PATH"
  fi

  if command -v adb >/dev/null 2>&1; then
    info "adb    : $(adb version 2>/dev/null | head -1)"
  else
    warn "adb not on PATH yet — re-login or use the fish lines above"
  fi

  if [[ -x "$SDKMANAGER" ]] && (( ! DRY_RUN )); then
    info "sdk    : $SDK_DIR"
    "$SDKMANAGER" --sdk_root="$SDK_DIR" --list_installed 2>/dev/null | sed 's/^/            /' || true
  fi

  if [[ -e /dev/kvm ]]; then
    ok "/dev/kvm present — the emulator can run"
  else
    warn "/dev/kvm missing — enable VT-x/AMD-V in firmware and load kvm_amd/kvm_intel, or use a physical device"
  fi

  cat <<EOF

    next steps
    ----------
    1. log out and back in (env vars, udev group), then check:  adb devices
    2. point the project at the SDK — either rely on ANDROID_HOME or write
         sdk.dir=$SDK_DIR
       into local.properties (not versioned).
    3. the Gradle wrapper is already committed (gradlew, Gradle 9.3.0) — nothing to do.
    4. if a build still picks JDK 25, pin it in gradle.properties:
         org.gradle.java.home=/usr/lib/jvm/$JDK_DIR_NAME
EOF
}

main() {
  parse_args "$@"
  require_arch
  install_repo_packages
  select_jdk
  setup_udev
  install_studio
  ensure_sdkmanager
  install_sdk_packages
  install_emulator
  write_env
  summary
}

main "$@"
