#!/usr/bin/env sh
set -eu

APP_NAME="ecrits"
TARGET="macos_silicon"
TARGET_SLUG="macos-silicon"
OUT_DIR="${BURRITO_OUT:-burrito_out}"
SERVER_PORT="${ECRITS_RELEASE_PORT:-4084}"
APP_BASE_URL="${ECRITS_RELEASE_APP_BASE_URL:-http://localhost:${SERVER_PORT}}"
SECRET_KEY_BASE="${ECRITS_RELEASE_SECRET_KEY_BASE:-}"

run_mix() {
  if command -v mise >/dev/null 2>&1; then
    mise exec -- mix "$@"
  else
    mix "$@"
  fi
}

if [ -z "$SECRET_KEY_BASE" ]; then
  if command -v openssl >/dev/null 2>&1; then
    SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')"
  else
    echo "SECRET_KEY_BASE must be set when openssl is unavailable" >&2
    exit 1
  fi
fi

VERSION="$(awk -F'"' '/version:/ { print $2; exit }' mix.exs)"
PACKAGE_DIR="${OUT_DIR}/${APP_NAME}-${TARGET_SLUG}-${VERSION}"
ZIP_PATH="${PACKAGE_DIR}.zip"
SHA_PATH="${ZIP_PATH}.sha256"
BURRITO_BINARY="${OUT_DIR}/${APP_NAME}_${TARGET}"

export MIX_ENV=prod
export BURRITO_TARGET="$TARGET"

rm -rf "_build/prod/rel/${APP_NAME}"
run_mix assets.deploy
run_mix release --overwrite

if [ ! -x "$BURRITO_BINARY" ]; then
  echo "Expected Burrito binary not found: ${BURRITO_BINARY}" >&2
  exit 1
fi

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"
cp "$BURRITO_BINARY" "${PACKAGE_DIR}/${APP_NAME}"
chmod 0755 "${PACKAGE_DIR}/${APP_NAME}"

(
  umask 077
  {
    printf 'PHX_SERVER=1\n'
    printf 'SERVER_PORT=%s\n' "$SERVER_PORT"
    printf 'PORT=%s\n' "$SERVER_PORT"
    printf 'APP_BASE_URL=%s\n' "$APP_BASE_URL"
    printf 'SECRET_KEY_BASE=%s\n' "$SECRET_KEY_BASE"
  } > "${PACKAGE_DIR}/.env.prod"
)

cat > "${PACKAGE_DIR}/README.txt" <<EOF
Ecrits ${VERSION} for macOS arm64

Run:
  ./ecrits

Default URL:
  ${APP_BASE_URL}

Runtime settings live in .env.prod next to the executable.
EOF

rm -f "$ZIP_PATH" "$SHA_PATH"
(
  cd "$OUT_DIR"
  zip -qry "$(basename "$ZIP_PATH")" "$(basename "$PACKAGE_DIR")"
)
shasum -a 256 "$ZIP_PATH" > "$SHA_PATH"

if [ "${KEEP_BURRITO_WRAPPER:-0}" != "1" ]; then
  rm -f "$BURRITO_BINARY"
fi

printf 'release=%s\n' "$ZIP_PATH"
printf 'sha256=%s\n' "$SHA_PATH"
