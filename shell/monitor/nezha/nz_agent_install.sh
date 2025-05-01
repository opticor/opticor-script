#!/bin/bash

# 哪吒 Agent 安装/重装脚本

# ========== 默认值 ==========
NZ_SERVER=""
NZ_CLIENT_SECRET=""
NZ_UUID=""
NZ_TLS="false"

# ========== 解析具名参数 ==========
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)
      NZ_SERVER="$2"
      shift 2
      ;;
    --secret)
      NZ_CLIENT_SECRET="$2"
      shift 2
      ;;
    --uuid)
      NZ_UUID="$2"
      shift 2
      ;;
    --tls)
      NZ_TLS="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1"
      echo "用法: $0 --server example.com:8008 --secret SECRET --uuid UUID --tls true"
      exit 1
      ;;
  esac
done

# ========== 交互式补充 ==========
[[ -z "$NZ_SERVER" ]] && read -p "请输入哪吒服务端地址 (如 dashboard.example.com:8008): " NZ_SERVER
[[ -z "$NZ_CLIENT_SECRET" ]] && read -p "请输入客户端密钥 (NZ_CLIENT_SECRET): " NZ_CLIENT_SECRET
[[ -z "$NZ_UUID" ]] && read -p "请输入UUID（可选，直接回车跳过）: " NZ_UUID
[[ -z "$NZ_TLS" ]] && read -p "是否启用 TLS？输入 true 或 false [默认 false]: " NZ_TLS

# ========== 打印配置 ==========
echo -e "\n[*] 开始安装哪吒 Agent..."
echo "服务端地址：$NZ_SERVER"
echo "客户端密钥：$NZ_CLIENT_SECRET"
echo "UUID：$NZ_UUID"
echo "TLS：$NZ_TLS"
echo

# ========== 卸载旧版本 ==========
if [ -f /opt/nezha/agent/nezha-agent ]; then
  echo "[*] 检测到已有安装，开始卸载..."
  /opt/nezha/agent/nezha-agent service uninstall
  rm -rf /opt/nezha/agent/
else
  echo "[*] 未检测到已安装版本，跳过卸载。"
fi

# ========== 安装新 Agent ==========
echo "[*] 下载安装脚本..."
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
chmod +x agent.sh

echo "[*] 正在安装新的 Agent..."
env NZ_SERVER="$NZ_SERVER" NZ_TLS="$NZ_TLS" NZ_CLIENT_SECRET="$NZ_CLIENT_SECRET" NZ_UUID="$NZ_UUID" ./agent.sh

echo -e "\n[✓] 哪吒 Agent 安装完成！"