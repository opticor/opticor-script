#!/bin/bash

clear
echo -e "\033[1;36m====================================\033[0m"
echo -e "\033[1;32m      Reality 代理 安装脚本      \033[0m"
echo -e "\033[1;36m====================================\033[0m"

echo -e "\n\033[1;33m[1/5] 安装依赖...\033[0m"
apt update -y && apt install -y curl wget unzip jq socat netcat openssl dnsutils

echo -e "\n\033[1;33m[2/5] 配置 Reality 参数...\033[0m"
read -rp "请输入用于指向的网站（默认：bilibili.com）: " DOMAIN
DOMAIN=${DOMAIN:-bilibili.com}

read -rp "请输入监听端口（默认：443）: " PORT
PORT=${PORT:-443}

# 获取本机公网IP
REALITY_IP=$(curl -s https://api.ipify.org)

if [[ -z "$REALITY_IP" ]]; then
  echo -e "\033[0;31m❌ 无法自动获取本机公网IP，请手动输入：\033[0m"
  read -rp "请输入服务器公网IP: " REALITY_IP
fi

FINGERPRINT=$(curl -sIv https://$DOMAIN 2>&1 | grep -i "issuer" | head -n 1 | sed -E 's/.*CN=//')

echo -e "👉 本机公网IP: \033[1;32m$REALITY_IP\033[0m"
echo -e "👉 TLS指纹 (此为目标网站证书Issuer CN, 仅供参考, Reality配置中实际使用的是客户端指纹如chrome): \033[1;32m$FINGERPRINT\033[0m"

echo -e "\n\033[1;33m[3/5] 安装 Xray Core...\033[0m"
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
ln -sf /usr/local/bin/xray /usr/bin/xray

echo -e "\n\033[1;33m[4/5] 生成 Reality 密钥对...\033[0m"
/usr/local/bin/xray x25519 | tee /etc/xray/key.txt
PRIV_KEY=$(grep "Private key" /etc/xray/key.txt | awk '{print $NF}')
PUB_KEY=$(grep "Public key" /etc/xray/key.txt | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 4)
UUID=$(cat /proc/sys/kernel/random/uuid)

echo -e "👉 私钥: \033[1;32m$PRIV_KEY\033[0m"
echo -e "👉 公钥: \033[1;32m$PUB_KEY\033[0m"
echo -e "👉 短ID: \033[1;32m$SHORT_ID\033[0m"
echo -e "👉 UUID: \033[1;32m$UUID\033[0m"

echo -e "\n\033[1;33m[5/5] 生成配置文件并启动...\033[0m"
mkdir -p /etc/xray

cat > /etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DOMAIN:443",
          "xver": 0,
          "serverNames": ["$DOMAIN"],
          "privateKey": "$PRIV_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload # <-- 已修正
systemctl enable xray
systemctl restart xray

echo -e "\n\033[1;36m✅ Reality 安装完成！以下是你的连接信息：\033[0m"
echo -e "地址 (服务器公网IP)：\033[1;32m$REALITY_IP\033[0m"
echo -e "端口：\033[1;32m$PORT\033[0m"
echo -e "UUID：\033[1;32m$UUID\033[0m"
echo -e "公钥：\033[1;32m$PUB_KEY\033[0m"
echo -e "短ID：\033[1;32m$SHORT_ID\033[0m"
echo -e "SNI/ServerName (伪装域名)：\033[1;32m$DOMAIN\033[0m"
echo -e "Flow：\033[1;32mxtls-rprx-vision\033[0m"
echo -e "客户端TLS指纹 (Client Fingerprint - 建议值)：\033[1;32mchrome, firefox, safari, ios, android, random (任选其一)\033[0m"


echo -e "\n\033[1;35m📁 配置文件路径：\033[0m /etc/xray/config.json"
echo -e "\033[1;35m📄 密钥文件路径：\033[0m /etc/xray/key.txt"
echo -e "\033[1;35m📜 管理命令示例：\033[0m"
echo -e "  👉 启动：      \033[1;32msystemctl start xray\033[0m"
echo -e "  👉 停止：      \033[1;32msystemctl stop xray\033[0m"
echo -e "  👉 重启：      \033[1;32msystemctl restart xray\033[0m"
echo -e "  👉 查看状态：  \033[1;32msystemctl status xray\033[0m"
echo -e "  👉 查看日志：  \033[1;32mjournalctl -u xray -f\033[0m"

echo -e "\n\033[1;36m📦 Clash Meta 配置片段如下 (请根据你的客户端核心版本和配置习惯调整)：\033[0m"
echo -e "\033[1;37m----------------------------------------\033[0m"
cat <<EOF
# 示例 Clash Meta 配置
- name: reality-$(echo $REALITY_IP | tr '.' '-')-$PORT
  type: vless
  server: $REALITY_IP
  port: $PORT
  uuid: $UUID
  flow: xtls-rprx-vision
  network: tcp
  tls: true # 对于Reality, tls字段是必需的
  client-fingerprint: chrome # 建议: chrome, firefox, safari, ios, android, random
  servername: $DOMAIN
  reality-opts:
    public-key: "$PUB_KEY"
    short-id: "$SHORT_ID"
  udp: true
EOF
echo -e "\033[1;37m----------------------------------------\033[0m"
