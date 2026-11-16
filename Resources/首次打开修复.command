#!/bin/bash
# Maple 首次打开修复工具（支持：DMG 内运行 / 下载目录自动挂载 DMG 安装 / 已安装应用直接修复）

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_TARGET="/Applications/Maple.app"

echo "🍁 正在为您配置 Maple 打开权限..."

# 顺手清除同目录及下载目录下所有 Maple*.dmg 的隔离属性，使 DMG 也能正常双击打开
for dmg_file in "$DIR"/Maple*.dmg "$HOME/Downloads"/Maple*.dmg; do
    if [ -f "$dmg_file" ]; then
        xattr -c "$dmg_file" 2>/dev/null || true
    fi
done

# 1. 如果尚未安装到 /Applications，尝试从同目录的 Maple.app 或同目录/下载目录的 Maple*.dmg 自动安装
if [ ! -d "$APP_TARGET" ]; then
    if [ -d "$DIR/Maple.app" ]; then
        echo "→ 正在自动安装 Maple.app 到 /Applications ..."
        if [ -w "/Applications" ]; then
            cp -R "$DIR/Maple.app" "$APP_TARGET"
        else
            osascript -e "do shell script \"cp -R '$DIR/Maple.app' '$APP_TARGET'\" with administrator privileges" || exit 1
        fi
    else
        # 查找同目录或下载目录下的 Maple*.dmg 自动挂载安装
        FOUND_DMG=""
        for dmg_file in "$DIR"/Maple*.dmg "$HOME/Downloads"/Maple*.dmg; do
            if [ -f "$dmg_file" ]; then
                FOUND_DMG="$dmg_file"
                break
            fi
        done
        if [ -n "$FOUND_DMG" ]; then
            echo "→ 检测到安装包 $(basename "$FOUND_DMG")，正在自动挂载并安装到 /Applications ..."
            xattr -c "$FOUND_DMG" 2>/dev/null || true
            MNT="$(hdiutil attach "$FOUND_DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | head -n 1)"
            if [ -n "$MNT" ] && [ -d "$MNT/Maple.app" ]; then
                if [ -w "/Applications" ]; then
                    cp -R "$MNT/Maple.app" "$APP_TARGET"
                else
                    osascript -e "do shell script \"cp -R '$MNT/Maple.app' '$APP_TARGET'\" with administrator privileges" || true
                fi
                hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
            fi
        fi
    fi
fi

if [ ! -d "$APP_TARGET" ]; then
    osascript -e 'display alert "未找到 Maple.app" message "请先将安装包中的 Maple 图标拖入右侧的 Applications（应用程序）文件夹，然后再运行本工具。" as warning buttons {"好"} default button "好"'
    exit 1
fi

# 2. 移除隔离属性 (com.apple.quarantine)，解决首次打开提示「无法验证开发者」或「已损坏」
if ! xattr -cr "$APP_TARGET" 2>/dev/null; then
    osascript -e "do shell script \"xattr -cr '$APP_TARGET'\" with administrator privileges" || exit 1
fi

echo "✓ 修复完成，正在启动 Maple..."

# 3. 弹出原生完成提示并启动 Maple
osascript -e 'display dialog "✅ Maple 首次打开权限配置完成！\n点击下方按钮立即启动。" buttons {"立即打开 Maple"} default button 1 with title "Maple 修复成功"' >/dev/null 2>&1 || true

open -a "$APP_TARGET"

# 4. 自动关闭当前终端窗口
osascript -e 'tell application "Terminal" to close (every window whose name contains "首次打开修复")' >/dev/null 2>&1 &
exit 0
