#!/bin/bash

SERVICE_FILE="/etc/systemd/system/komari-agent.service"

if [ ! -f "$SERVICE_FILE" ]; then
    echo "错误: 服务文件 $SERVICE_FILE 不存在"
    exit 1
fi

# 从 ExecStart 行提取参数（去掉可执行文件路径，保留其余所有参数）
ARGS=$(grep -E '^\s*ExecStart\s*=' "$SERVICE_FILE" | sed 's/^\s*ExecStart\s*=\s*//' | sed 's/^\S*//')

if [ -z "$ARGS" ]; then
    echo "错误: 未能从 $SERVICE_FILE 中提取到 ExecStart 参数"
    exit 1
fi

echo "提取到的参数:$ARGS"
echo ""
echo "即将执行安装脚本..."

bash <(curl -sL https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh) $ARGS