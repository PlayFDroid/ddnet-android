#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
TMP_DIR="${BUILD_DIR}/tmp"

DDNET_VERSION="${1:-${DDNET_VERSION:-}}"

if [ -z "${DDNET_VERSION}" ] || [ "${DDNET_VERSION}" = "latest" ]; then
    echo "==> Fetching latest DDNet release version from ddnet.org..."
    DDNET_VERSION=$(curl -sL https://ddnet.org/downloads/ | grep -o 'DDNet-[0-9][0-9.]*\.apk' | head -n 1 | sed 's/DDNet-//' | sed 's/\.apk//')
    if [ -z "${DDNET_VERSION}" ]; then
        DDNET_VERSION="20.2.1"
    fi
fi

echo "==> Target DDNet version: ${DDNET_VERSION}"

mkdir -p "${BUILD_DIR}"
mkdir -p "${TMP_DIR}"

APK_URL="https://ddnet.org/downloads/DDNet-${DDNET_VERSION}.apk"
DOWNLOADED_APK="${BUILD_DIR}/DDNet-${DDNET_VERSION}-upstream.apk"

if [ ! -f "${DOWNLOADED_APK}" ]; then
    echo "==> Downloading upstream APK: ${APK_URL}"
    curl -fL -o "${DOWNLOADED_APK}" "${APK_URL}"
else
    echo "==> Using cached upstream APK: ${DOWNLOADED_APK}"
fi

# Locate Android SDK
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "${SDK_ROOT}" ]; then
    if [ -d "/usr/local/lib/android/sdk" ]; then
        SDK_ROOT="/usr/local/lib/android/sdk"
    elif [ -d "$HOME/android-sdk" ]; then
        SDK_ROOT="$HOME/android-sdk"
    fi
fi

# Locate strip tool
STRIP_TOOL=""
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME}" ]; then
    STRIP_TOOL=$(find "${ANDROID_NDK_HOME}" -name "llvm-strip" 2>/dev/null | head -n 1)
elif [ -n "${SDK_ROOT}" ] && [ -d "${SDK_ROOT}/ndk" ]; then
    STRIP_TOOL=$(find "${SDK_ROOT}/ndk" -name "llvm-strip" 2>/dev/null | head -n 1)
fi

if [ -z "${STRIP_TOOL}" ]; then
    STRIP_TOOL=$(which llvm-strip 2>/dev/null || which strip 2>/dev/null || true)
fi

if [ -z "${STRIP_TOOL}" ]; then
    echo "ERROR: llvm-strip or strip not found!" >&2
    exit 1
fi
echo "==> Using strip tool: ${STRIP_TOOL}"

# Locate zipalign
ZIPALIGN_TOOL=""
if [ -n "${SDK_ROOT}" ] && [ -d "${SDK_ROOT}/build-tools" ]; then
    ZIPALIGN_TOOL=$(find "${SDK_ROOT}/build-tools" -name "zipalign" 2>/dev/null | sort -V | tail -n 1)
fi
if [ -z "${ZIPALIGN_TOOL}" ]; then
    ZIPALIGN_TOOL=$(which zipalign 2>/dev/null || true)
fi
if [ -z "${ZIPALIGN_TOOL}" ]; then
    echo "ERROR: zipalign not found!" >&2
    exit 1
fi
echo "==> Using zipalign tool: ${ZIPALIGN_TOOL}"

# Locate apksigner
APKSIGNER_TOOL=""
if [ -n "${SDK_ROOT}" ] && [ -d "${SDK_ROOT}/build-tools" ]; then
    APKSIGNER_TOOL=$(find "${SDK_ROOT}/build-tools" -name "apksigner" 2>/dev/null | sort -V | tail -n 1)
fi
if [ -z "${APKSIGNER_TOOL}" ]; then
    APKSIGNER_TOOL=$(which apksigner 2>/dev/null || true)
fi

UNPACK_DIR="${TMP_DIR}/unpacked"
rm -rf "${UNPACK_DIR}"
mkdir -p "${UNPACK_DIR}"

echo "==> Unpacking upstream APK..."
unzip -q -o "${DOWNLOADED_APK}" -d "${UNPACK_DIR}"

# Remove existing signatures
rm -rf "${UNPACK_DIR}/META-INF"

# Strip all .so libraries
echo "==> Stripping unneeded symbols from native libraries..."
SO_COUNT=0
while IFS= read -r -d '' so_file; do
    "${STRIP_TOOL}" --strip-unneeded "${so_file}"
    SO_COUNT=$((SO_COUNT + 1))
done < <(find "${UNPACK_DIR}/lib" -type f -name "*.so" -print0)
echo "==> Stripped ${SO_COUNT} shared libraries."

# Filter ABIs if ABIS env is defined (e.g. ABIS="arm64-v8a,x86_64,x86")
if [ -n "${ABIS:-}" ]; then
    echo "==> Filtering ABIs to: ${ABIS}"
    IFS=',' read -r -a KEEP_ABIS <<< "${ABIS}"
    for abi_path in "${UNPACK_DIR}/lib"/*; do
        if [ -d "${abi_path}" ]; then
            abi_name=$(basename "${abi_path}")
            keep=0
            for k in "${KEEP_ABIS[@]}"; do
                if [ "${abi_name}" = "${k}" ]; then
                    keep=1
                    break
                fi
            done
            if [ $keep -eq 0 ]; then
                echo "    Removing ABI: ${abi_name}"
                rm -rf "${abi_path}"
            fi
        fi
    done
fi

UNALIGNED_APK="${TMP_DIR}/repacked.unaligned.apk"
FINAL_APK="${BUILD_DIR}/ddnet-${DDNET_VERSION}.apk"
SYMLINK_APK="${BUILD_DIR}/ddnet.apk"

rm -f "${UNALIGNED_APK}" "${FINAL_APK}" "${SYMLINK_APK}"

echo "==> Repacking APK..."
python3 -c "
import os, zipfile

unpack_dir = '${UNPACK_DIR}'
orig_apk = '${DOWNLOADED_APK}'
output_apk = '${UNALIGNED_APK}'

compress_map = {}
with zipfile.ZipFile(orig_apk, 'r') as zin:
    for info in zin.infolist():
        compress_map[info.filename] = info.compress_type

with zipfile.ZipFile(output_apk, 'w') as zout:
    for root, dirs, files in os.walk(unpack_dir):
        for f in sorted(files):
            fp = os.path.join(root, f)
            arcname = os.path.relpath(fp, unpack_dir)
            c_type = compress_map.get(arcname, zipfile.ZIP_DEFLATED)
            # resources.arsc MUST be stored uncompressed (ZIP_STORED) for Android 11+ (API 30+)
            if arcname == 'resources.arsc':
                c_type = zipfile.ZIP_STORED
            zout.write(fp, arcname, compress_type=c_type)
"

echo "==> Aligning APK..."
if "${ZIPALIGN_TOOL}" 2>&1 | grep -q -- "-P"; then
    echo "    Using 16 KB page-size alignment: zipalign -P 16 4"
    "${ZIPALIGN_TOOL}" -P 16 4 "${UNALIGNED_APK}" "${FINAL_APK}"
else
    echo "    Using standard page-size alignment: zipalign -p 4"
    "${ZIPALIGN_TOOL}" -p 4 "${UNALIGNED_APK}" "${FINAL_APK}"
fi
rm -f "${UNALIGNED_APK}"
rm -rf "${TMP_DIR}"

if [ -n "${APKSIGNER_TOOL}" ]; then
    echo "==> Signing APK..."
    if [ -n "${KEYSTORE_FILE:-}" ] && [ -f "${KEYSTORE_FILE}" ]; then
        echo "    Using custom keystore: ${KEYSTORE_FILE}"
        "${APKSIGNER_TOOL}" sign \
            --ks "${KEYSTORE_FILE}" \
            --ks-key-alias "${KEY_ALIAS}" \
            --ks-pass "pass:${KEYSTORE_PASSWORD}" \
            --key-pass "pass:${KEY_PASSWORD}" \
            "${FINAL_APK}"
    elif [ -f "$HOME/.android/debug.keystore" ]; then
        echo "    Using debug keystore: $HOME/.android/debug.keystore"
        "${APKSIGNER_TOOL}" sign \
            --ks "$HOME/.android/debug.keystore" \
            --ks-key-alias "androiddebugkey" \
            --ks-pass "pass:android" \
            --key-pass "pass:android" \
            "${FINAL_APK}"
    else
        echo "WARNING: No keystore found. Output APK is unsigned."
    fi

    echo "==> Verifying signature..."
    "${APKSIGNER_TOOL}" verify --verbose "${FINAL_APK}"
fi

echo "==> Verifying alignment..."
if "${ZIPALIGN_TOOL}" 2>&1 | grep -q -- "-P"; then
    "${ZIPALIGN_TOOL}" -c -v -P 16 4 "${FINAL_APK}" | grep -i "Verification" || true
else
    "${ZIPALIGN_TOOL}" -c -v 4 "${FINAL_APK}" | grep -i "Verification" || true
fi

cp -f "${FINAL_APK}" "${SYMLINK_APK}"

FINAL_SIZE=$(du -h "${FINAL_APK}" | cut -f1)
echo "=========================================================="
echo "SUCCESS! Created optimized DDNet APK:"
echo "Path: ${FINAL_APK} (${FINAL_SIZE})"
echo "Path: ${SYMLINK_APK} (${FINAL_SIZE})"
echo "=========================================================="
