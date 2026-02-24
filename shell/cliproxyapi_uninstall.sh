#!/usr/bin/env bash

set -euo pipefail

echo "=== 开始卸载 CLIProxyAPI ==="
echo "这会杀死进程、停止/删除常见 systemd 服务、清理目录。"

# 1. 强制杀死进程
echo "→ 杀死所有相关进程..."
pkill -9 -f cli-proxy-api     2>/dev/null || true
pkill -9 -f cliproxyapi        2>/dev/null || true
pkill -9 -f "cli proxy api"    2>/dev/null || true

# 2. 只处理常见的 cliproxyapi.service（用户级 + 系统级）
echo "→ 停止并禁用 cliproxyapi 服务（如果存在）..."

# 用户级
systemctl --user stop    cliproxyapi.service  2>/dev/null || true
systemctl --user disable cliproxyapi.service  2>/dev/null || true

# 系统级（需要 sudo）
if command -v sudo >/dev/null; then
    sudo systemctl stop    cliproxyapi.service  2>/dev/null || true
    sudo systemctl disable cliproxyapi.service  2>/dev/null || true
fi

# 3. 删除服务文件（只针对 cliproxyapi）
echo "→ 删除服务文件..."
rm -f ~/.config/systemd/user/cliproxyapi.service          2>/dev/null
rm -f ~/.config/systemd/user/cliproxyapi@.service         2>/dev/null

if command -v sudo >/dev/null; then
    sudo rm -f /etc/systemd/system/cliproxyapi.service     2>/dev/null
    sudo rm -f /etc/systemd/system/cliproxyapi@.service    2>/dev/null
    sudo rm -f /usr/lib/systemd/system/cliproxyapi.service 2>/dev/null
    sudo rm -f /lib/systemd/system/cliproxyapi.service     2>/dev/null
fi

# 重新加载 systemd
systemctl --user daemon-reload 2>/dev/null || true
if command -v sudo >/dev/null; then
    sudo systemctl daemon-reload
fi

# 4. 清理常见安装目录和配置
echo "→ 删除常见目录和配置文件..."
rm -rf ~/CLIProxyAPI           2>/dev/null
rm -rf ~/cliproxyapi           2>/dev/null
rm -rf ~/.cliproxyapi          2>/dev/null
rm -rf ~/.cli-proxy-api        2>/dev/null
rm -rf ~/.config/cli-proxy-api 2>/dev/null

# 5. 清理 crontab 中的启动任务（如果有）
echo "→ 清理 crontab 中的相关任务..."
(crontab -l 2>/dev/null | grep -v -i "cli-proxy-api\|cliproxyapi") | crontab - 2>/dev/null

echo ""
echo "=== 卸载基本完成 ==="
echo "建议手动检查以下内容是否还有残留："
echo "  ps aux | grep -i cli-proxy"
echo "  systemctl --user list-units --type=service | grep -i cliproxy"
echo "  sudo systemctl list-units --type=service | grep -i cliproxy   （如果有 sudo）"
echo "  ls ~/CLIProxyAPI ~/.cliproxyapi ~/cliproxyapi"
echo ""
echo "如果看到残留文件/进程，直接 rm / kill 即可。"
echo "完成！"
