#!/usr/bin/env bash
#
# Build .deb and .rpm packages from a completed release bundle.
#
# Prerequisites (must already be done before calling this):
#   flutter build linux --release   -> build/linux/x64/release/bundle/
#
# Requires: fpm, rpm (for the rpm target), ImageMagick (`convert`).
#
# Output: dist/gravity-music_<version>_amd64.deb
#         dist/gravity-music-<version>-1.x86_64.rpm
#
# Version is taken from $PKG_VERSION if set (CI passes the git tag), else from
# pubspec.yaml.

set -euo pipefail

APP_NAME="gravity-music"
APP_ID="com.example.saraharmony"      # matches GTK application-id + window app_id
DISPLAY_NAME="Gravity Music"
BIN_NAME="saraharmony"                 # binary name from linux/CMakeLists.txt
MAINTAINER="Anuragh K P <kpanuragh@gmail.com>"
DESCRIPTION="A modern, minimal YouTube audio player."
HOMEPAGE="https://github.com/kpanuragh/Gravity-Music"
LICENSE="MIT"

# Repo root = two levels up from this script (linux/packaging/).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE="$ROOT/build/linux/x64/release/bundle"
ICON_SRC="$ROOT/assets/app_icon.png"

if [ ! -x "$BUNDLE/$BIN_NAME" ]; then
  echo "error: release bundle not found at $BUNDLE" >&2
  echo "run 'flutter build linux --release' first." >&2
  exit 1
fi

# Version: env override (CI tag) -> pubspec.yaml -> fallback. Strip a leading
# 'v' and any '+build' suffix so it is a valid deb/rpm version.
VERSION="${PKG_VERSION:-$(grep -E '^version:' "$ROOT/pubspec.yaml" | head -1 | sed -E 's/version:[[:space:]]*//; s/\+.*//')}"
VERSION="${VERSION#v}"
VERSION="${VERSION:-0.0.0}"
echo "Packaging $APP_NAME version $VERSION"

# ── Stage an FHS install tree ───────────────────────────────────────────────
STAGE="$ROOT/build/pkg-stage"
rm -rf "$STAGE"
install -d "$STAGE/opt/$APP_NAME"
cp -r "$BUNDLE/." "$STAGE/opt/$APP_NAME/"
chmod 755 "$STAGE/opt/$APP_NAME/$BIN_NAME"

# Launcher wrapper on PATH.
#
# The app uses audio_service + MPRIS, which require a D-Bus *session* bus during
# AudioService.init(); without one the window stays blank. Some Wayland sessions
# (e.g. a minimal Hyprland/Sway setup) export no session bus to launcher-spawned
# apps. If none is reachable, start a private one with dbus-run-session so the
# app still launches (MPRIS then lives on that bus). When a real session bus
# exists it is used as-is, so MPRIS stays visible system-wide.
install -d "$STAGE/usr/bin"
cat > "$STAGE/usr/bin/$APP_NAME" <<EOF
#!/bin/sh
BIN=/opt/$APP_NAME/$BIN_NAME
if [ -n "\$DBUS_SESSION_BUS_ADDRESS" ] || [ -S "\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/bus" ]; then
  exec "\$BIN" "\$@"
else
  exec dbus-run-session -- "\$BIN" "\$@"
fi
EOF
chmod 755 "$STAGE/usr/bin/$APP_NAME"

# Desktop entry.
install -d "$STAGE/usr/share/applications"
cat > "$STAGE/usr/share/applications/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$DISPLAY_NAME
GenericName=Music Player
Comment=$DESCRIPTION
Exec=$APP_NAME
Icon=$APP_ID
Terminal=false
Categories=AudioVideo;Audio;Player;
Keywords=music;audio;youtube;player;
StartupWMClass=$APP_ID
StartupNotify=true
EOF

# Hicolor icons resized from the app icon.
for sz in 512 256 128 64 48; do
  install -d "$STAGE/usr/share/icons/hicolor/${sz}x${sz}/apps"
  convert "$ICON_SRC" -resize "${sz}x${sz}" \
    "$STAGE/usr/share/icons/hicolor/${sz}x${sz}/apps/$APP_ID.png"
done

# ── Maintainer scripts (refresh desktop/icon caches) ────────────────────────
SCRIPTS="$ROOT/build/pkg-scripts"
rm -rf "$SCRIPTS"; mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/after-install.sh" <<'EOF'
#!/bin/sh
update-desktop-database -q /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
EOF
cp "$SCRIPTS/after-install.sh" "$SCRIPTS/after-remove.sh"
chmod 755 "$SCRIPTS/after-install.sh" "$SCRIPTS/after-remove.sh"

OUT="$ROOT/dist"
mkdir -p "$OUT"

FPM_COMMON=(
  -s dir
  -n "$APP_NAME"
  -v "$VERSION"
  --maintainer "$MAINTAINER"
  --description "$DESCRIPTION"
  --url "$HOMEPAGE"
  --license "$LICENSE"
  --category "sound"
  --after-install "$SCRIPTS/after-install.sh"
  --after-remove "$SCRIPTS/after-remove.sh"
  -C "$STAGE"
)

# ── .deb (Debian/Ubuntu) ────────────────────────────────────────────────────
# libmpv2 (newer) | libmpv1 (older) — media_kit dlopens libmpv at runtime.
fpm "${FPM_COMMON[@]}" \
  -t deb \
  --architecture amd64 \
  --depends "libmpv2 | libmpv1" \
  --depends "libgtk-3-0" \
  --depends "dbus" \
  --deb-no-default-config-files \
  -p "$OUT/${APP_NAME}_${VERSION}_amd64.deb" \
  .

# ── .rpm (Fedora/RHEL) ──────────────────────────────────────────────────────
# Fedora ships libmpv in mpv-libs. (openSUSE uses libmpv2 — install manually
# there if needed.)
fpm "${FPM_COMMON[@]}" \
  -t rpm \
  --architecture x86_64 \
  --depends "mpv-libs" \
  --depends "gtk3" \
  --depends "dbus" \
  -p "$OUT/${APP_NAME}-${VERSION}-1.x86_64.rpm" \
  .

echo
echo "Built packages:"
ls -la "$OUT"
