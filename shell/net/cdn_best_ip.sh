#!/usr/bin/env bash

set -euo pipefail

QUERY_TIMES=3
WRITE_HOSTS=0
TARGET=""

usage() {
    cat <<EOF
用法:
  $0 [选项] <域名或URL>

选项:
  -n, --times <次数>         每个DNS查询次数，默认 3
  -w, --write-hosts          自动把最优IP写入 /etc/hosts（默认关闭）
  -h, --help                 显示帮助

示例:
  $0 www.example.com
  $0 https://www.example.com/path
  $0 -n 5 www.example.com
  $0 -n 5 -w www.example.com
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--times)
            QUERY_TIMES="${2:-}"
            if [[ -z "$QUERY_TIMES" ]] || ! [[ "$QUERY_TIMES" =~ ^[0-9]+$ ]]; then
                echo "错误: --times 需要一个正整数"
                exit 1
            fi
            shift 2
            ;;
        -w|--write-hosts)
            WRITE_HOSTS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$TARGET" ]]; then
                TARGET="$1"
            else
                echo "错误: 多余参数 $1"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    usage
    exit 1
fi

if ! command -v dig >/dev/null 2>&1; then
    echo "错误: 需要 dig 命令，请安装 dnsutils 或 bind-utils"
    exit 1
fi

extract_host() {
    local input="$1"

    if [[ "$input" =~ ^https?:// ]]; then
        input="${input#http://}"
        input="${input#https://}"
        input="${input%%/*}"
    fi

    input="${input%%:*}"
    echo "$input"
}

HOST="$(extract_host "$TARGET")"

if [[ -z "$HOST" ]]; then
    echo "错误: 无法提取主机名"
    exit 1
fi

DNS_SERVERS=(
    "8.8.8.8"
    "1.1.1.1"
    "9.9.9.9"
    "223.5.5.5"
    "119.29.29.29"
    "114.114.114.114"
)

TMP_IPS="$(mktemp)"
TMP_HOSTS="$(mktemp)"
trap 'rm -f "$TMP_IPS" "$TMP_HOSTS"' EXIT

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

query_a_records() {
    local dns="$1"
    local host="$2"

    dig @"$dns" +short "$host" A 2>/dev/null | while read -r line; do
        if is_ipv4 "$line"; then
            echo "$line"
        fi
    done
}

get_authoritative_ns() {
    dig +short NS "$HOST" 2>/dev/null | sed 's/\.$//'
}

resolve_ns_ip() {
    local ns="$1"
    dig +short "$ns" A 2>/dev/null | while read -r line; do
        if is_ipv4 "$line"; then
            echo "$line"
        fi
    done
}

ping_avg() {
    local ip="$1"
    local outfile
    outfile="$(mktemp)"

    if ping -c 3 -W 1 "$ip" >"$outfile" 2>/dev/null; then
        awk -F'/' '
            /min\/avg\/max\/mdev/ {print $5}
            /round-trip min\/avg\/max\/stddev/ {print $5}
        ' "$outfile" | tail -n1
    fi

    rm -f "$outfile"
}

write_hosts_record() {
    local ip="$1"
    local host="$2"
    local hosts_file="/etc/hosts"
    local marker="# auto-cdn-best-ip"

    local newline="${ip} ${host} ${marker}"

    if [[ ! -w "$hosts_file" ]]; then
        echo "警告: 当前没有权限写入 $hosts_file，请使用 sudo 运行脚本"
        return 1
    fi

    # 只删除与当前 host 相关的行，其他域名的记录完全不动
    awk -v host="$host" '
    {
        # 空行直接保留
        if ($0 ~ /^[[:space:]]*$/) { print; next }

        # 纯注释行直接保留
        if ($0 ~ /^[[:space:]]*#/) { print; next }

        # 检查是否包含目标 host（从第2列开始匹配，避免误匹配IP）
        matched = 0
        for (i = 2; i <= NF; i++) {
            # 去掉行内注释部分再比较
            field = $i
            if (field == host) {
                matched = 1
                break
            }
        }

        if (matched) next

        print
    }' "$hosts_file" > "$TMP_HOSTS"

    echo "$newline" >> "$TMP_HOSTS"

    cat "$TMP_HOSTS" > "$hosts_file"

    echo "已写入 hosts: $newline"
}

echo "目标主机: $HOST"
echo "每个DNS查询次数: $QUERY_TIMES"
echo "写入hosts: $([[ "$WRITE_HOSTS" -eq 1 ]] && echo "开启" || echo "关闭")"
echo

echo "第一阶段：通过多个公共DNS多次查询，尽量收集更多CDN IP..."
echo

for dns in "${DNS_SERVERS[@]}"; do
    echo "查询公共DNS: $dns"
    for ((i=1; i<=QUERY_TIMES; i++)); do
        result="$(query_a_records "$dns" "$HOST" || true)"
        if [[ -n "$result" ]]; then
            echo "$result" >> "$TMP_IPS"
            echo "  第 $i 次: 获取到 $(echo "$result" | wc -l | awk '{print $1}') 个IP"
        else
            echo "  第 $i 次: 无结果"
        fi
        sleep 0.3
    done
done

echo
echo "第二阶段：尝试查询权威DNS服务器..."
echo

AUTH_NS_LIST="$(get_authoritative_ns || true)"

if [[ -n "$AUTH_NS_LIST" ]]; then
    while read -r ns; do
        [[ -z "$ns" ]] && continue
        echo "权威NS: $ns"

        ns_ips="$(resolve_ns_ip "$ns" || true)"
        if [[ -z "$ns_ips" ]]; then
            echo "  无法解析该NS的IP"
            continue
        fi

        while read -r ns_ip; do
            [[ -z "$ns_ip" ]] && continue
            echo "  通过NS IP查询: $ns_ip"

            for ((i=1; i<=QUERY_TIMES; i++)); do
                result="$(dig @"$ns_ip" +short "$HOST" A 2>/dev/null \
                    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)"
                if [[ -n "$result" ]]; then
                    echo "$result" >> "$TMP_IPS"
                    echo "    第 $i 次: 获取到 $(echo "$result" | wc -l | awk '{print $1}') 个IP"
                else
                    echo "    第 $i 次: 无结果"
                fi
                sleep 0.3
            done
        done <<< "$ns_ips"
    done <<< "$AUTH_NS_LIST"
else
    echo "未获取到权威NS"
fi

echo
ALL_IPS="$(sort -u "$TMP_IPS")"

if [[ -z "$ALL_IPS" ]]; then
    echo "未收集到任何IPv4地址"
    exit 1
fi

echo "最终收集到的去重IP列表:"
echo "$ALL_IPS"
echo
TOTAL_IP_COUNT="$(echo "$ALL_IPS" | wc -l | awk '{print $1}')"
echo "共计: ${TOTAL_IP_COUNT} 个IP"
echo

best_ip=""
best_latency=""

echo "第三阶段：测试每个IP的ping延迟..."
echo

while read -r ip; do
    [[ -z "$ip" ]] && continue

    latency="$(ping_avg "$ip" || true)"

    if [[ -z "$latency" ]]; then
        echo "IP: $ip -> ping失败"
        continue
    fi

    echo "IP: $ip -> 平均延迟: ${latency} ms"

    if [[ -z "$best_latency" ]]; then
        best_ip="$ip"
        best_latency="$latency"
    else
        if awk -v a="$latency" -v b="$best_latency" 'BEGIN {exit !(a < b)}'; then
            best_ip="$ip"
            best_latency="$latency"
        fi
    fi
done <<< "$ALL_IPS"

echo
echo "==================== 汇总 ===================="
echo "目标主机  : $HOST"
echo "收集IP数量: $TOTAL_IP_COUNT"

if [[ -n "$best_ip" ]]; then
    echo "延迟最小IP: $best_ip"
    echo "最小平均延迟: ${best_latency} ms"
    echo "最优hosts记录: $best_ip $HOST"
else
    echo "延迟最小IP: 无（所有IP ping失败）"
fi
echo "==============================================="

if [[ -n "$best_ip" && "$WRITE_HOSTS" -eq 1 ]]; then
    echo
    echo "第四阶段：写入 /etc/hosts ..."
    write_hosts_record "$best_ip" "$HOST"
fi

if [[ -z "$best_ip" ]]; then
    exit 1
fi