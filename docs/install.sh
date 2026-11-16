#!/bin/bash
# Maple for Mac 一键免拦截安装 / 修复脚本
# 用法: curl -fsSL https://liceal.github.io/maple/install.sh | bash

set -e

BOLD="\033[1m"
GREEN="\033[32m"
AMBER="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}🍁 Maple for Mac 一键安装与免拦截助手${RESET}"
echo "--------------------------------------------------------"

ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
    DMG_NAME="Maple-arm64.dmg"
    ARCH_LABEL="Apple Silicon (M 系列 / arm64)"
else
    DMG_NAME="Maple-x86_64.dmg"
    ARCH_LABEL="Intel (x86_64)"
fi

echo -e "→ 检测到当前 Mac 架构: ${BOLD}${ARCH_LABEL}${RESET}"

# 如果只是修复已安装的 Maple.app
if [ "$1" = "--fix" ] && [ -d "/Applications/Maple.app" ]; then
    echo "→ 正在解除 /Applications/Maple.app 的系统安全隔离限制..."
    xattr -cr "/Applications/Maple.app" 2>/dev/null || sudo xattr -cr "/Applications/Maple.app"
    echo -e "${GREEN}✓ 已成功移除隔离标记，正在启动 Maple...${RESET}"
    open -a "/Applications/Maple.app"
    exit 0
fi

TMP_DIR="$(mktemp -d /tmp/maple_install.XXXXXX)"
MOUNT_POINT=""
cleanup() {
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

DOWNLOAD_URL="https://github.com/liceal/maple/releases/latest/download/${DMG_NAME}"
DMG_PATH="${TMP_DIR}/${DMG_NAME}"

echo "→ 正在下载最新版本 (${DMG_NAME})..."
curl -fL --progress-bar "$DOWNLOAD_URL" -o "$DMG_PATH"

echo "→ 正在挂载安装包..."
MOUNT_POINT="$(hdiutil attach "$DMG_PATH" -nobrowse -readonly | grep -o '/Volumes/.*' | head -n 1)"

if [ -z "$MOUNT_POINT" ] || [ ! -d "${MOUNT_POINT}/Maple.app" ]; then
    echo -e "${RED}✗ 挂载 DMG 失败，未找到 Maple.app${RESET}"
    exit 1
fi

echo "→ 正在安装 Maple.app 到 /Applications ..."
# 如果正在运行则先温和退出
killall "Maple" 2>/dev/null || true

if [ -w "/Applications" ]; then
    rm -rf "/Applications/Maple.app"
    cp -R "${MOUNT_POINT}/Maple.app" "/Applications/Maple.app"
    xattr -cr "/Applications/Maple.app" 2>/dev/null || true
else
    echo -e "${AMBER}需要管理员权限以写入 /Applications 目录，请输入开机密码：${RESET}"
    sudo rm -rf "/Applications/Maple.app"
    sudo cp -R "${MOUNT_POINT}/Maple.app" "/Applications/Maple.app"
    sudo xattr -cr "/Applications/Maple.app" 2>/dev/null || true
fi

echo -e "${GREEN}✓ Maple 安装完成，且已自动解除 macOS 未签名拦截！${RESET}"
echo "→ 正在为您启动 Maple..."
open -a "/Applications/Maple.app"
