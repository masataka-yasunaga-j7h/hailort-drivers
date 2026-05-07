#!/bin/bash
# Hailo PCIe ドライバ Android 16 GKI (6.12) ビルドスクリプト
# 対象: android-16.0.0_r4 + AAOS
#
# 前提条件:
#   - /home/mstk83long/aaos/ に AAOS ソースが存在すること
#   - aarch64-linux-gnu-* クロスコンパイラがインストール済みであること
#     (sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu)

set -e

# ==============================
# 設定
# ==============================
AAOS_ROOT="/home/mstk83long/aaos"
CLANG_DIR="${AAOS_ROOT}/prebuilts/clang/host/linux-x86/clang-r574158/bin"
LLVM_BINUTILS="${AAOS_ROOT}/prebuilts/clang/host/linux-x86/llvm-binutils-stable/bin"

# GKI カーネルソースの出力先
KERNEL_SRC_DIR="${HOME}/kernel-gki/common"

# Hailo ドライバのソースディレクトリ
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_DIR="${SCRIPT_DIR}/linux/pcie"

# ==============================
# ツールチェーン設定
# ==============================
export PATH="${CLANG_DIR}:${LLVM_BINUTILS}:${PATH}"

ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu-
MAKE_ARGS="ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} LLVM=1 LLVM_IAS=1"

# ==============================
# Step 1: GKI 6.12 カーネルソース取得
# ==============================
prepare_kernel_source() {
    if [ -d "${KERNEL_SRC_DIR}" ]; then
        echo "[INFO] カーネルソースは既に存在します: ${KERNEL_SRC_DIR}"
        echo "[INFO] 最新状態を確認中..."
        cd "${KERNEL_SRC_DIR}"
        git log --oneline -1
        return 0
    fi

    echo "[INFO] GKI android16-6.12 カーネルソースをダウンロード中..."
    echo "[INFO] (数分かかります)"
    mkdir -p "$(dirname "${KERNEL_SRC_DIR}")"
    git clone --depth=1 \
        https://android.googlesource.com/kernel/common \
        -b android16-6.12 \
        "${KERNEL_SRC_DIR}"
    echo "[INFO] カーネルソース取得完了"
}

# ==============================
# Step 2: カーネルヘッダのビルド (modules_prepare)
# ==============================
prepare_kernel_headers() {
    echo "[INFO] カーネル設定 (gki_defconfig) を適用中..."
    cd "${KERNEL_SRC_DIR}"

    make ${MAKE_ARGS} gki_defconfig

    echo "[INFO] カーネルヘッダをビルド中 (modules_prepare)..."
    make ${MAKE_ARGS} modules_prepare
    echo "[INFO] カーネルヘッダ準備完了"
}

# ==============================
# Step 3: Hailo PCIe ドライバのビルド
# ==============================
build_hailo_driver() {
    echo "[INFO] Hailo PCIe ドライバをビルド中..."
    cd "${DRIVER_DIR}"

    make ${MAKE_ARGS} KERNEL_DIR="${KERNEL_SRC_DIR}" all

    echo ""
    echo "[SUCCESS] ビルド完了!"
    echo "出力: ${DRIVER_DIR}/build/release/arm64/"
    ls "${DRIVER_DIR}/build/release/arm64/"*.ko 2>/dev/null || \
        find "${DRIVER_DIR}/build" -name "*.ko" 2>/dev/null

    echo ""
    echo "====================================================="
    echo " 次のステップ: デバイスへの展開"
    echo "====================================================="
    echo " # 1. ドライバのプッシュ"
    echo " adb root && adb remount"
    echo " adb shell 'mkdir -p /vendor/lib/modules/hailo'"
    echo " adb push ${DRIVER_DIR}/build/release/arm64/hailo1x_pci.ko /vendor/lib/modules/hailo/"
    echo ""
    echo " # 2. Hailo10H ファームウェアのプッシュ (hailo10h_fw_5.3.0/)"
    echo " adb shell 'mkdir -p /vendor/etc/firmware/hailo/hailo10h'"
    echo " adb push ${SCRIPT_DIR}/hailo10h_fw_5.3.0/. /vendor/etc/firmware/hailo/hailo10h/"
    echo ""
    echo " # 3. ドライバのロード"
    echo " adb shell 'insmod /vendor/lib/modules/hailo/hailo1x_pci.ko'"
    echo ""
    echo " # または自動起動設定"
    echo " adb shell \"echo 'insmod /vendor/lib/modules/hailo/hailo1x_pci.ko' >> /vendor/etc/init.insmod.cfg\""
    echo "======================================================"
    echo " ※ './build_android.sh deploy' で上記 adb コマンドを自動実行できます"
    echo "====================================================="
}

# ==============================
# デバイスへの展開 (adb)
# ==============================
deploy_to_device() {
    local fw_dir="${SCRIPT_DIR}/hailo10h_fw_5.3.0"
    local ko_file="${DRIVER_DIR}/build/release/arm64/hailo1x_pci.ko"

    if [ ! -f "${ko_file}" ]; then
        echo "[ERROR] .ko ファイルが見つかりません。先に './build_android.sh driver' を実行してください"
        exit 1
    fi
    if [ ! -d "${fw_dir}" ]; then
        echo "[ERROR] ファームウェアディレクトリが見つかりません: ${fw_dir}"
        echo "[ERROR] 先に ./download_firmware_hailo10h.sh を実行してください"
        exit 1
    fi

    echo "[INFO] adb root && adb remount ..."
    adb root
    adb remount

    echo "[INFO] ドライバをプッシュ中..."
    adb shell "mkdir -p /vendor/lib/modules/hailo"
    adb push "${ko_file}" /vendor/lib/modules/hailo/

    echo "[INFO] Hailo10H ファームウェアをプッシュ中..."
    adb shell "mkdir -p /vendor/etc/firmware/hailo/hailo10h"
    adb push "${fw_dir}/." /vendor/etc/firmware/hailo/hailo10h/

    echo "[INFO] ドライバをロード中..."
    adb shell "insmod /vendor/lib/modules/hailo/hailo1x_pci.ko"

    echo ""
    echo "[SUCCESS] デバイスへの展開完了!"
}

# ==============================
# クリーン
# ==============================
clean_all() {
    echo "[INFO] ドライバのビルド成果物を削除中..."
    cd "${DRIVER_DIR}"
    make ${MAKE_ARGS} KERNEL_DIR="${KERNEL_SRC_DIR}" clean 2>/dev/null || true
    rm -rf "${DRIVER_DIR}/build"
    echo "[INFO] 完了"
}

# ==============================
# メイン処理
# ==============================
echo "======================================================"
echo " Hailo PCIe ドライバ Android 16 GKI ビルド"
echo " Clang: $(clang --version 2>/dev/null | head -1 || echo 'PATH設定後に確認')"
echo "======================================================"

# 引数による処理選択
case "${1:-all}" in
    kernel)
        prepare_kernel_source
        prepare_kernel_headers
        ;;
    driver)
        if [ ! -f "${KERNEL_SRC_DIR}/include/generated/autoconf.h" ]; then
            echo "[ERROR] カーネルヘッダが未準備です。先に './build_android.sh kernel' を実行してください"
            exit 1
        fi
        build_hailo_driver
        ;;
    all)
        prepare_kernel_source
        prepare_kernel_headers
        build_hailo_driver
        ;;
    clean)
        clean_all
        ;;
    deploy)
        deploy_to_device
        ;;
    *)
        echo "使い方: $0 [all|kernel|driver|clean|deploy]"
        echo "  all    : カーネルソース取得 + ヘッダ準備 + ドライバビルド (デフォルト)"
        echo "  kernel : カーネルソース取得とヘッダ準備のみ"
        echo "  driver : ドライバビルドのみ (カーネルヘッダ準備済みの場合)"
        echo "  clean  : ドライバのビルド成果物を削除"
        echo "  deploy : adb でデバイスにドライバとファームウェアを展開"
        exit 1
        ;;
esac
