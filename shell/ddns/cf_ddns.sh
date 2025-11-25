#!/bin/bash

# ==============================================================================
#  赋予权限: chmod +x cf_ddns.sh
#  定时任务: 运行 crontab -e 添加如下内容 (示例为每5分钟检查一次):
#    */5 * * * * /root/ddns/cf_ddns.sh >> /root/ddns/cf_ddns.log 2>&1
# ==============================================================================

# =========================================================
# 配置区域 (请修改以下内容)
# =========================================================

# Cloudflare API Token (在 用户头像 -> My Profile -> API Tokens 中创建)
# 权限需包含: Zone.DNS (Edit)
CF_API_TOKEN="你的_API_Token_填在这里"

# 区域 ID (在域名概览页面的右下角 "Zone ID")
CF_ZONE_ID="你的_Zone_ID_填在这里"

# 要更新的域名 (例如: ddns.example.com)
CF_RECORD_NAME="ddns.example.com"

# 记录类型 (A 为 IPv4, AAAA 为 IPv6)
CF_RECORD_TYPE="A"

# 是否开启 Cloudflare 代理 (CDN) (true 或 false)
CF_PROXIED=false

# 获取公网 IP 的服务地址 (备选: http://ipv4.icanhazip.com)
IP_CHECK_URL="https://api.ipify.org"

# =========================================================
# 脚本逻辑开始
# =========================================================

# 1. 检查依赖
command -v jq >/dev/null 2>&1 || { echo "错误: 未安装 jq，请先安装 (apt/yum install jq)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "错误: 未安装 curl，请先安装"; exit 1; }

# 2. 获取当前公网 IP
CURRENT_IP=$(curl -s "$IP_CHECK_URL")

if [[ -z "$CURRENT_IP" ]]; then
    echo "[$(date)] 错误: 无法获取当前公网 IP，请检查网络。"
    exit 1
fi

# 3. 从 Cloudflare 获取当前 DNS 记录信息
# 我们需要获取 Record ID 和当前解析的 IP
CF_API_URL="https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=$CF_RECORD_TYPE&name=$CF_RECORD_NAME"

RESPONSE=$(curl -s -X GET "$CF_API_URL" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json")

# 4. 解析 API 返回结果
SUCCESS=$(echo "$RESPONSE" | jq -r '.success')

if [[ "$SUCCESS" != "true" ]]; then
    echo "[$(date)] 错误: 连接 Cloudflare API 失败，请检查 Token 或 Zone ID。"
    echo "详细信息: $(echo "$RESPONSE" | jq -r '.errors[0].message')"
    exit 1
fi

# 提取 Record ID 和 Cloudflare 上记录的 IP
CF_RECORD_ID=$(echo "$RESPONSE" | jq -r '.result[0].id')
CF_RECORD_IP=$(echo "$RESPONSE" | jq -r '.result[0].content')

# 检查域名记录是否存在
if [[ "$CF_RECORD_ID" == "null" ]]; then
    echo "[$(date)] 错误: 未在 Cloudflare 找到域名 $CF_RECORD_NAME 的记录，请先手动在后台创建一条记录。"
    exit 1
fi

# 5. 对比 IP 并更新
if [[ "$CURRENT_IP" == "$CF_RECORD_IP" ]]; then
    echo "[$(date)] IP 无变化 ($CURRENT_IP)，无需更新。"
else
    echo "[$(date)] 检测到 IP 变更 (旧: $CF_RECORD_IP -> 新: $CURRENT_IP)，正在更新..."

    # 发送更新请求
    UPDATE_URL="https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID"

    UPDATE_RESPONSE=$(curl -s -X PUT "$UPDATE_URL" \
         -H "Authorization: Bearer $CF_API_TOKEN" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"$CF_RECORD_TYPE\",\"name\":\"$CF_RECORD_NAME\",\"content\":\"$CURRENT_IP\",\"proxied\":$CF_PROXIED}")

    UPDATE_SUCCESS=$(echo "$UPDATE_RESPONSE" | jq -r '.success')

    if [[ "$UPDATE_SUCCESS" == "true" ]]; then
        echo "[$(date)] 更新成功！当前 IP: $CURRENT_IP"
    else
        echo "[$(date)] 更新失败！"
        echo "错误信息: $(echo "$UPDATE_RESPONSE" | jq -r '.errors[0].message')"
        exit 1
    fi
fi