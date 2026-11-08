# DDNet Android (PlayFDroid Distribution)

[![Build & Release DDNet Android APK](https://github.com/PlayFDroid/ddnet-android/actions/workflows/build-release.yml/badge.svg)](https://github.com/PlayFDroid/ddnet-android/actions/workflows/build-release.yml)
[![F-Droid](https://img.shields.io/badge/F--Droid-PlayFDroid-blue.svg)](https://playfdroid.github.io/)

This repository automates the packaging and optimization of official [DDraceNetwork (DDNet)](https://ddnet.org) Android releases for decentralized distribution on the [PlayFDroid F-Droid repository](https://playfdroid.github.io/).

---

## Why this repository exists

Official DDNet Android APK releases (`DDNet-*.apk`) exceed 125 MB because native libraries (`libDDNet.so` and `libDDNet-Server.so`) are distributed with unstripped DWARF debug sections.

GitHub repository hosting and F-Droid index catalogs impose a strict **100 MB per-file limit**.

This packaging pipeline:
1. Downloads the official release APK directly from [ddnet/ddnet](https://github.com/ddnet/ddnet/releases).
2. Strips unneeded debug symbols from native binaries using Android NDK `llvm-strip`.
3. Repacks the APK using optimal Deflate compression.
4. Ensures **16 KB ELF page-size alignment** (`zipalign -P 16 4`) for Android 15/16+ compatibility.
5. Signs the package with the consistent PlayFDroid release key.

### Results

| Metric | Upstream APK | PlayFDroid Optimized |
| :--- | :--- | :--- |
| **File Size** | ~126 MB | **~77 MB** |
| **Architectures** | `arm64-v8a`, `x86_64`, `x86`, `armeabi-v7a` | `arm64-v8a`, `x86_64`, `x86`, `armeabi-v7a` |
| **F-Droid Compliant (< 100 MB)** | ❌ No |  **Yes** |
| **16 KB Page-Size Aligned** | Partial |  **Full** (`zipalign -P 16 4`) |
| **Features Included** | Client + Server + All Assets | Client + Server + All Assets |

---

## Manual Build / Reproduction

To build and optimize the APK locally:

```bash
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME=/path/to/android-ndk

./build-android.sh 20.2.1
```

The optimized package will be generated at `build/ddnet-20.2.1.apk`.

---

## Credits & Upstream

- **DDraceNetwork Project**: [https://ddnet.org](https://ddnet.org) / [GitHub: ddnet/ddnet](https://github.com/ddnet/ddnet)
- **Original Teeworlds**: Magnus Auvinen and Teeworlds Team
- **PlayFDroid**: [https://playfdroid.github.io](https://playfdroid.github.io)
