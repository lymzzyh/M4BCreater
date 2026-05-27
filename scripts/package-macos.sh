#!/usr/bin/env bash
set -euo pipefail

APP_NAME="M4BCreater"
BUNDLE_ID="com.m4bcreater.app"
VERSION="0.1.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_PATH="${DIST_DIR}/${APP_NAME}.app"
DMG_ROOT="${DIST_DIR}/dmg-root"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"

cd "${ROOT_DIR}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE="${BIN_DIR}/${APP_NAME}"
RESOURCE_BUNDLE="${BIN_DIR}/${APP_NAME}_${APP_NAME}.bundle"
APP_ICON="${ROOT_DIR}/Sources/M4BCreater/Resources/AppIcon.icns"

if [[ ! -x "${EXECUTABLE}" ]]; then
  echo "Missing release executable: ${EXECUTABLE}" >&2
  exit 1
fi

if [[ ! -d "${RESOURCE_BUNDLE}" ]]; then
  echo "Missing SwiftPM resource bundle: ${RESOURCE_BUNDLE}" >&2
  exit 1
fi

if [[ ! -f "${APP_ICON}" ]]; then
  echo "Missing app icon: ${APP_ICON}" >&2
  exit 1
fi

rm -rf "${APP_PATH}" "${DMG_ROOT}" "${DMG_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources" "${DMG_ROOT}"

cp "${EXECUTABLE}" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
cp -R "${RESOURCE_BUNDLE}" "${APP_PATH}/${APP_NAME}_${APP_NAME}.bundle"
cp "${APP_ICON}" "${APP_PATH}/Contents/Resources/AppIcon.icns"
rm -rf "${APP_PATH}/${APP_NAME}_${APP_NAME}.bundle/AppIcon.icns" \
       "${APP_PATH}/${APP_NAME}_${APP_NAME}.bundle/AppIcon.png" \
       "${APP_PATH}/${APP_NAME}_${APP_NAME}.bundle"/icon_*.png
chmod +x "${APP_PATH}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_PATH}/${APP_NAME}_${APP_NAME}.bundle/ffmpeg" "${APP_PATH}/${APP_NAME}_${APP_NAME}.bundle/ffprobe"

cat > "${APP_PATH}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST

cp -R "${APP_PATH}" "${DMG_ROOT}/${APP_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "App: ${APP_PATH}"
echo "DMG: ${DMG_PATH}"
