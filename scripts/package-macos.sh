#!/usr/bin/env bash
set -euo pipefail

APP_NAME="M4BCreater"
BUNDLE_ID="com.m4bcreater.app"
VERSION="1.0.0"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"

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

mkdir -p "${DIST_DIR}"
STAGING_DIR="$(mktemp -d "${DIST_DIR}/.package.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT
DMG_ROOT="${STAGING_DIR}/dmg-root"
DMG_PATH="${STAGING_DIR}/${APP_NAME}.dmg"
APP_PATH="${DMG_ROOT}/${APP_NAME}.app"
APP_RESOURCES="${APP_PATH}/Contents/Resources"
APP_RESOURCE_BUNDLE="${APP_RESOURCES}/${APP_NAME}_${APP_NAME}.bundle"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources" "${DMG_ROOT}"

cp "${EXECUTABLE}" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
cp -R "${RESOURCE_BUNDLE}" "${APP_RESOURCE_BUNDLE}"
cp "${APP_ICON}" "${APP_RESOURCES}/AppIcon.icns"
FFMPEG_RESOURCES="${APP_RESOURCE_BUNDLE}"
if [[ -d "${APP_RESOURCE_BUNDLE}/Contents/Resources" ]]; then
  FFMPEG_RESOURCES="${APP_RESOURCE_BUNDLE}/Contents/Resources"
fi
rm -rf "${FFMPEG_RESOURCES}/AppIcon.icns" \
       "${FFMPEG_RESOURCES}/AppIcon.png" \
       "${FFMPEG_RESOURCES}"/icon_*.png
chmod +x "${APP_PATH}/Contents/MacOS/${APP_NAME}"
chmod +x "${FFMPEG_RESOURCES}/ffmpeg" "${FFMPEG_RESOURCES}/ffprobe"

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
  <key>NSLocalNetworkUsageDescription</key>
  <string>M4BCreater 需要访问你配置的局域网 WebDAV 服务器，以浏览目录、读取音频和保存转换后的有声书。</string>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST

codesign --force --sign "${CODE_SIGN_IDENTITY}" "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"
ln -s /Applications "${DMG_ROOT}/Applications"
DMG_SIZE_MB="$(du -sk "${DMG_ROOT}" | awk '{ print int($1 / 1024) + 512 }')"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_ROOT}" \
  -size "${DMG_SIZE_MB}m" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${DIST_DIR}/${APP_NAME}.app"
mv "${APP_PATH}" "${DIST_DIR}/${APP_NAME}.app"
mv -f "${DMG_PATH}" "${DIST_DIR}/${APP_NAME}.dmg"

echo "App: ${DIST_DIR}/${APP_NAME}.app"
echo "DMG: ${DIST_DIR}/${APP_NAME}.dmg"
