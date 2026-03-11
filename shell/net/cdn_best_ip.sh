#!/usr/bin/env bash

set -euo pipefail

QUERY_TIMES=3
WRITE_HOSTS=0
TARGET=""
PREFER="ping"

usage() {
    cat <<EOF
用法:
  $0 [选项] <域名或URL>

选项:
  -n, --times <次数>         每个DNS查询次数，默认 3
  -p, --prefer <ping|tcp>    如果 ICMP 和 TCP 测速最优不一样，默认优先选哪个 (默认: ping)
  -w, --write-hosts          自动把最优IP写入 /etc/hosts（无此参数交互提示）
  -h, --help                 显示帮助

示例:
  $0 www.example.com
  $0 -p tcp www.example.com
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
        -p|--prefer)
            PREFER="${2:-}"
            if [[ "$PREFER" != "ping" && "$PREFER" != "tcp" ]]; then
                echo "错误: --prefer 只能是 ping 或 tcp"
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
TMP_PING_RES="$(mktemp -d)"
TMP_TCP_RES="$(mktemp -d)"
trap 'rm -rf "$TMP_IPS" "$TMP_HOSTS" "$TMP_PING_RES" "$TMP_TCP_RES"' EXIT

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

query_a_records() {
    local dns="$1"
    local host="$2"

    dig @"$dns" +time=3 +tries=1 +short "$host" A 2>/dev/null | while read -r line; do
        if is_ipv4 "$line"; then
            echo "$line"
        fi
    done
}

get_authoritative_ns() {
    dig +time=3 +tries=1 +short NS "$HOST" 2>/dev/null | sed 's/\.$//'
}

resolve_ns_ip() {
    local ns="$1"
    dig +time=3 +tries=1 +short "$ns" A 2>/dev/null | while read -r line; do
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

tcp_ping() {
    local ip="$1"
    local res
    res=$(curl -o /dev/null -s -w "%{time_connect}\n" --connect-timeout 2 "http://$ip" 2>/dev/null || true)
    if [[ -n "$res" && "$res" != "0.000000" && "$res" != "0.000" ]]; then
        awk -v t="$res" 'BEGIN { printf "%.2f", t * 1000 }'
    fi
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
    (
        for ((i=1; i<=QUERY_TIMES; i++)); do
            result="$(query_a_records "$dns" "$HOST" || true)"
            if [[ -n "$result" ]]; then
                echo "$result" >> "$TMP_IPS"
                echo "  [$dns] 第 $i 次: 获取到 $(echo "$result" | wc -l | awk '{print $1}') 个IP"
            else
                echo "  [$dns] 第 $i 次: 无结果"
            fi
            sleep 0.3
        done
    ) &
done
wait

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

            (
                for ((i=1; i<=QUERY_TIMES; i++)); do
                    result="$(dig @"$ns_ip" +time=3 +tries=1 +short "$HOST" A 2>/dev/null \
                        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)"
                    if [[ -n "$result" ]]; then
                        echo "$result" >> "$TMP_IPS"
                        echo "    [$ns_ip] 第 $i 次: 获取到 $(echo "$result" | wc -l | awk '{print $1}') 个IP"
                    else
                        echo "    [$ns_ip] 第 $i 次: 无结果"
                    fi
                    sleep 0.3
                done
            ) &
        done <<< "$ns_ips"
        wait
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

echo "第三阶段：并发测试每个IP的 Ping (ICMP) 和 TCP (80端口) 延迟..."
echo

while read -r ip; do
    [[ -z "$ip" ]] && continue

    (
        latency="$(ping_avg "$ip" || true)"
        if [[ -n "$latency" ]]; then
            echo "$latency" > "$TMP_PING_RES/$ip"
        fi
    ) &
    (
        tcp_lat="$(tcp_ping "$ip" || true)"
        if [[ -n "$tcp_lat" ]]; then
            echo "$tcp_lat" > "$TMP_TCP_RES/$ip"
        fi
    ) &
done <<< "$ALL_IPS"
wait

echo "--- Ping (ICMP) 测速结果 ---"
best_ping_ip=""
best_ping_latency=""
if ls "$TMP_PING_RES"/* >/dev/null 2>&1; then
    for res_file in "$TMP_PING_RES"/*; do
        [[ -e "$res_file" ]] || continue
        ip="$(basename "$res_file")"
        latency="$(cat "$res_file")"
        echo "IP: $ip -> Ping 平均延迟: ${latency} ms"
        if [[ -z "$best_ping_latency" ]] || awk -v a="$latency" -v b="$best_ping_latency" 'BEGIN {exit !(a < b)}'; then
            best_ping_ip="$ip"
            best_ping_latency="$latency"
        fi
    done
else
    echo "所有 IP 的 Ping 均失败"
fi

echo
echo "--- TCP (80端口) 测速结果 ---"
best_tcp_ip=""
best_tcp_latency=""
if ls "$TMP_TCP_RES"/* >/dev/null 2>&1; then
    for res_file in "$TMP_TCP_RES"/*; do
        [[ -e "$res_file" ]] || continue
        ip="$(basename "$res_file")"
        latency="$(cat "$res_file")"
        echo "IP: $ip -> TCP 平均延迟: ${latency} ms"
        if [[ -z "$best_tcp_latency" ]] || awk -v a="$latency" -v b="$best_tcp_latency" 'BEGIN {exit !(a < b)}'; then
            best_tcp_ip="$ip"
            best_tcp_latency="$latency"
        fi
    done
else
    echo "所有 IP 的 TCP 测速均失败"
fi

echo
echo "==================== 汇总 ===================="
echo "目标主机  : $HOST"
echo "收集IP数量: $TOTAL_IP_COUNT"
echo "最优 Ping IP: ${best_ping_ip:-无} (延迟: ${best_ping_latency:-N/A} ms)"
echo "最优 TCP IP : ${best_tcp_ip:-无} (延迟: ${best_tcp_latency:-N/A} ms)"
echo "==============================================="

final_ip=""
if [[ -n "$best_ping_ip" && -n "$best_tcp_ip" ]]; then
    if [[ "$best_ping_ip" == "$best_tcp_ip" ]]; then
        final_ip="$best_ping_ip"
        echo "发现最优 IP 一致: $final_ip"
    else
        if [[ "$PREFER" == "tcp" ]]; then
            final_ip="$best_tcp_ip"
            echo "最优 IP 不一致，根据配置优先使用 TCP 最优 IP: $final_ip"
        else
            final_ip="$best_ping_ip"
            echo "最优 IP 不一致，根据配置优先使用 Ping 最优 IP: $final_ip"
        fi
    fi
elif [[ -n "$best_ping_ip" ]]; then
    final_ip="$best_ping_ip"
    echo "仅有 Ping 测速结果，使用: $final_ip"
elif [[ -n "$best_tcp_ip" ]]; then
    final_ip="$best_tcp_ip"
    echo "仅有 TCP 测速结果，使用: $final_ip"
else
    echo "所有测速均失败，无法选择可用 IP"
    exit 1
fi

if [[ "$WRITE_HOSTS" -eq 1 ]]; then
    # 已带 -w，自动写入
    if [[ -n "$final_ip" ]]; then
        echo
        echo "第四阶段：自动写入 /etc/hosts ..."
        write_hosts_record "$final_ip" "$HOST"
    fi
else
    # 未带 -w，交互式提示
    if [[ -n "$final_ip" ]]; then
        echo
        if [[ -n "$best_ping_ip" && -n "$best_tcp_ip" && "$best_ping_ip" != "$best_tcp_ip" ]]; then
            echo "测速结果出现差异："
            echo "  1) 写入 Ping 最优 IP: $best_ping_ip"
            echo "  2) 写入 TCP 最优 IP: $best_tcp_ip"
            echo "  0) 不写入 (退出)"
            read -r -p "请输入序号选择要写入的 IP [0]: " choice </dev/tty || true
            case "$choice" in
                1)
                    write_hosts_record "$best_ping_ip" "$HOST"
                    ;;
                2)
                    write_hosts_record "$best_tcp_ip" "$HOST"
                    ;;
                *)
                    echo "已取消写入"
                    ;;
            esac
        else
            read -r -p "是否将唯一的最佳 IP ($final_ip) 写入 /etc/hosts？[y/N]: " choice </dev/tty || true
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                write_hosts_record "$final_ip" "$HOST"
            else
                echo "已取消写入"
            fi
        fi
    fi
fi