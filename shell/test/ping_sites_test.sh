#!/bin/bash

# ==============================================================================
# 网络延迟和丢包率测试脚本
#
# 功能:
# 1. 测试到预定义主机列表的延迟和丢包率。
# 2. 包含 IPv6 测试。
# ==============================================================================

# --- 配置 ---
HOSTS_TO_TEST=(
    "google.com"
    "telegram.com"
    "youtube.com"
    "chatgpt.com"
    "bilibili.com"
    "twitch.tv"
    "www.microsoft.com"
    "github.com"
    "apple.com"
    "x.com"               # Twitter/X
    "tiktok.com"
    "jetbrains.com"
)

# --- 全局变量 ---
SCRIPT_VERSION="1.6" #版本更新
ipv6_available="false"

# --- 辅助函数 ---

command_exists() {
    command -v "$1" &>/dev/null
}


_get_ping_stats() {
    local host="$1"
    local ip_version="$2"
    local count="$3"
    local overall_timeout="$4"
    local ping_opts="-c $count -W 1"
    [[ "$count" -gt 1 ]] && ping_opts="$ping_opts -i 0.2"

    local cmd_base="ping"
    local cmd_array

    local LC_NUMERIC_ORIG=$LC_NUMERIC
    export LC_NUMERIC=C

    local latency="N/A"
    local loss="N/A"

    if [[ "$ip_version" == "6" ]];
    then
        if command_exists dig; then
            if ! dig +short AAAA "$host" &>/dev/null; then
                latency="无IPv6记录"; loss="-"
                export LC_NUMERIC=$LC_NUMERIC_ORIG
                echo "$latency $loss"
                return
            fi
        elif command_exists host; then
             if ! host -t AAAA "$host" &>/dev/null; then
                latency="无IPv6记录"; loss="-"
                export LC_NUMERIC=$LC_NUMERIC_ORIG
                echo "$latency $loss"
                return
            fi
        fi
        cmd_array=("$cmd_base" -6 $ping_opts "$host")
    else
        cmd_array=("$cmd_base" -4 $ping_opts "$host")
    fi

    local ping_output
    if command_exists timeout; then
        ping_output=$(timeout "$overall_timeout" "${cmd_array[@]}" 2>&1)
    else
        ping_output=$("${cmd_array[@]}" 2>&1)
    fi
    local exit_status=$?

    if echo "$ping_output" | grep -qE "unknown host|Unknown host|Name or service not known|cannot resolve|Host not found"; then
        latency="未知主机"
        loss="100"
    elif [[ $exit_status -eq 124 ]]; then
        latency="超时"
        loss="100"
    elif [[ $exit_status -ne 0 && $exit_status -ne 1 ]]; then
        latency="失败"
        loss="100"
    else
        current_loss_percent=$(echo "$ping_output" | grep -oP '\d+(\.\d+)?(?=% packet loss)' | tail -n1)
        if [[ -z "$current_loss_percent" ]]; then
            tx_packets=$(echo "$ping_output" | grep 'packets transmitted' | awk '{print $1}')
            rx_packets=$(echo "$ping_output" | grep 'packets transmitted' | awk '{print $4}')
            if ! [[ "$rx_packets" =~ ^[0-9]+$ ]]; then
                 rx_packets=$(echo "$ping_output" | grep -oP '\d+(?= packets received)' | head -n1)
            fi

            if [[ "$tx_packets" =~ ^[0-9]+$ && "$rx_packets" =~ ^[0-9]+$ && "$tx_packets" -gt 0 ]]; then
                loss_calc=$(( ( (tx_packets - rx_packets) * 100 ) / tx_packets ))
                current_loss_percent=$(printf "%.0f" "$loss_calc")
            elif [[ $exit_status -eq 1 || ($(echo "$ping_output" | grep -q " 0 received") && $exit_status -eq 0) ]]; then
                current_loss_percent="100"
            elif [[ $exit_status -eq 0 ]]; then
                current_loss_percent="0"
            else
                current_loss_percent="?"
            fi
        else
            current_loss_percent=$(printf "%.0f" "$current_loss_percent")
        fi
        loss="$current_loss_percent"

        avg_latency_val=""
        avg_latency_val=$(echo "$ping_output" | awk -F'[ =/]+' '
            ($1 == "rtt" || $1 == "round-trip") {
                for (i=2; i<=NF; i++) {
                    if ($i == "min" && $(i+1) == "avg" && $(i+2) == "max") {
                        if ( $(i+3) == "mdev" || $(i+3) == "stddev" ) {
                            if ($(i+5) ~ /^[0-9]+\.?[0-9]*$/) { print $(i+5); exit; }
                        } else if ($(i+3) ~ /^[0-9]+\.?[0-9]*$/) {
                             if ($(i+4) ~ /^[0-9]+\.?[0-9]*$/) { print $(i+4); exit; }
                        }
                        break;
                    }
                }
            }
        ')

        if [[ -z "$avg_latency_val" && "$count" -gt 0 ]]; then
            all_times=$(echo "$ping_output" | awk -F'[= ]+' '/icmp_seq=/ && /time=/ { for(i=1;i<NF;i++) if ($i=="time") {gsub("ms","",$(i+1)); if($(i+1) ~ /^[0-9]+\.?[0-9]*$/) print $(i+1); next} }')
            num_valid_times=$(echo "$all_times" | grep -cE '^[0-9]+\.?[0-9]*$')

            if [[ "$num_valid_times" -gt 0 && "$num_valid_times" -le "$count" ]]; then
                total_time=$(echo "$all_times" | awk '{sum+=$1} END {print sum}')
                avg_latency_val=$(awk -v total="$total_time" -v num="$num_valid_times" 'BEGIN {if (num > 0) printf "%.3f", total/num; else print "";}')
            fi
        fi

        if [[ "$avg_latency_val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            latency=$(printf "%.2f" "$avg_latency_val")
        else
            latency="N/A"
        fi

        if [[ "$loss" == "100" ]]; then
            if [[ "$latency" != "N/A" && "$latency" != "失败" && "$latency" != "超时" && "$latency" != "未知主机" ]]; then
                 latency="N/A"
            fi
        elif [[ "$loss" != "?" && "$loss" -lt 100 && ("$latency" == "N/A" || -z "$latency") ]]; then
            if [[ $exit_status -ne 124 ]]; then
                 latency="解析错误"
            fi
        fi

        if [[ "$latency" != "N/A" && "$latency" != "解析错误" && "$latency" != "失败" && "$latency" != "超时" && "$latency" != "未知主机" && "$loss" == "?" ]]; then
            loss="0"
        fi
    fi

    export LC_NUMERIC=$LC_NUMERIC_ORIG
    echo "$latency $loss"
}


# --- 初始化和检查 ---
if ! command_exists ping; then
    echo "错误: 'ping' 命令未找到。请安装 iputils-ping (或类似包) 后重试。" >&2
    exit 1
fi

if ping -6 -c 1 -W 1 2001:4860:4860::8888 &>/dev/null; then
    ipv6_available="true"
elif command_exists ip && ip -6 route get 2001:4860:4860::8888 &>/dev/null; then
    ipv6_available="true"
fi

# --- 主逻辑 ---
echo "🌐 网络延迟和丢包率测试脚本 v${SCRIPT_VERSION}"
echo "-----------------------------------------"

N_PINGS_ONCE_DEFAULT=5
CONTINUOUS_INTERVAL_DEFAULT=3
MAX_CUSTOM_PINGS_TIMEOUT_CAP=60 # PING命令本身的总超时上限（秒）

echo "请选择测试模式:"
echo "1. 快速测试 (默认 ${N_PINGS_ONCE_DEFAULT} 次 ping)"
echo "2. 持续监测 (每次 ping 1 次, 每 ${CONTINUOUS_INTERVAL_DEFAULT} 秒刷新)"
echo "3. 自定义次数测试"
read -r -p "输入选项 (1, 2, 或 3): " test_mode

ping_count_this_run=$N_PINGS_ONCE_DEFAULT
is_continuous_mode=false

if [[ "$test_mode" == "1" ]]; then
    ping_count_this_run=$N_PINGS_ONCE_DEFAULT
    is_continuous_mode=false
    echo "模式: 快速测试 (${ping_count_this_run} 次 ping)"
elif [[ "$test_mode" == "2" ]]; then
    ping_count_this_run=1 # 持续模式固定为1次ping
    is_continuous_mode=true
    echo "模式: 持续监测 (每次 1 ping, ${CONTINUOUS_INTERVAL_DEFAULT}秒刷新)"
    trap "echo -e '\n👋 测试已终止。'; exit 0" SIGINT SIGTERM
elif [[ "$test_mode" == "3" ]]; then
    read -r -p "请输入自定义 ping 次数 (例如: 3, 10): " custom_ping_count
    if [[ "$custom_ping_count" =~ ^[1-9][0-9]*$ ]]; then
        ping_count_this_run=$custom_ping_count
        is_continuous_mode=false
        echo "模式: 自定义测试 (${ping_count_this_run} 次 ping)"
    else
        echo "错误：ping 次数必须为正整数。将使用默认快速测试 (${N_PINGS_ONCE_DEFAULT} 次)。"
        ping_count_this_run=$N_PINGS_ONCE_DEFAULT
        is_continuous_mode=false
    fi
else
    echo "无效选项。将使用默认快速测试 (${N_PINGS_ONCE_DEFAULT} 次)。"
    ping_count_this_run=$N_PINGS_ONCE_DEFAULT
    is_continuous_mode=false
fi

overall_timeout_s=$(( ping_count_this_run * 2 + 2 )) # 估算ping命令总超时
if [[ "$is_continuous_mode" == "true" ]]; then
    overall_timeout_s=4
fi

if [[ "$is_continuous_mode" == "false" ]]; then
    if [[ "$overall_timeout_s" -lt 4 ]]; then overall_timeout_s=4; fi
    if [[ "$overall_timeout_s" -gt "$MAX_CUSTOM_PINGS_TIMEOUT_CAP" ]]; then
        overall_timeout_s="$MAX_CUSTOM_PINGS_TIMEOUT_CAP"
        echo "注意: 计算的 ping 命令总超时时间较长, 已被限制为 ${overall_timeout_s} 秒。"
    fi
fi

# --- 表头和数据行格式化 ---
IPV4_HEADER_FMT="%-20s | %15s | %12s"
IPV4_DATA_FMT="%-20.20s | %15s | %12s"

IPV6_HEADER_FMT="${IPV4_HEADER_FMT} | %15s | %12s"
IPV6_DATA_FMT="${IPV4_DATA_FMT} | %15s | %12s"

header_host="目标主机"
header_ipv4_latency="IPv4延迟(ms)"
header_ipv4_loss="IPv4丢包(%)"
header_ipv6_latency="IPv6延迟(ms)"
header_ipv6_loss="IPv6丢包(%)"

SEP_HOST="--------------------"
SEP_LAT="---------------"
SEP_LOSS="------------"

print_header() {
    if [[ "$ipv6_available" == "true" ]]; then
        command printf "${IPV6_HEADER_FMT}\n" "$header_host" "$header_ipv4_latency" "$header_ipv4_loss" "$header_ipv6_latency" "$header_ipv6_loss"
        command printf "${IPV6_HEADER_FMT}\n" "$SEP_HOST" "$SEP_LAT" "$SEP_LOSS" "$SEP_LAT" "$SEP_LOSS"
    else
        command printf "${IPV4_HEADER_FMT}\n" "$header_host" "$header_ipv4_latency" "$header_ipv4_loss"
        command printf "${IPV4_HEADER_FMT}\n" "$SEP_HOST" "$SEP_LAT" "$SEP_LOSS"
    fi
}

process_and_print_host_stats() {
    local host_to_test=$1
    read -r ipv4_lat ipv4_loss_val <<< "$(_get_ping_stats "$host_to_test" "4" "$ping_count_this_run" "$overall_timeout_s")"

    local ipv6_lat="N/A"
    local ipv6_loss_val="-"
    if [[ "$ipv6_available" == "true" ]]; then
        read -r ipv6_lat ipv6_loss_val <<< "$(_get_ping_stats "$host_to_test" "6" "$ping_count_this_run" "$overall_timeout_s")"
    fi

    local v4_loss_display
    if [[ "$ipv4_loss_val" == "-" || "$ipv4_loss_val" == "?" ]]; then
        v4_loss_display="$ipv4_loss_val"
    else
        v4_loss_display="${ipv4_loss_val}%"
    fi

    local v6_loss_display
    if [[ "$ipv6_loss_val" == "-" || "$ipv6_loss_val" == "?" ]]; then
        v6_loss_display="$ipv6_loss_val"
    else
        v6_loss_display="${ipv6_loss_val}%"
    fi

    if [[ "$ipv6_available" == "true" ]]; then
        command printf "${IPV6_DATA_FMT}\n" "$host_to_test" "$ipv4_lat" "$v4_loss_display" "$ipv6_lat" "$v6_loss_display"
    else
        command printf "${IPV4_DATA_FMT}\n" "$host_to_test" "$ipv4_lat" "$v4_loss_display"
    fi
}

# --- 执行测试 ---
if [[ "$is_continuous_mode" == "true" ]]; then
    use_tput_refresh=false
    if command_exists tput; then
        use_tput_refresh=true
    else
        echo "警告: 'tput' 命令未找到。持续监测模式将使用全屏刷新。" >&2
    fi

    # 初始绘制
    if command_exists tput && [[ "$use_tput_refresh" == "true" ]]; then tput clear; else clear; fi
    echo "🔄 持续监测中... (按 Ctrl+C 退出)"
    echo
    print_header

    num_hosts=${#HOSTS_TO_TEST[@]}
    first_cycle_complete=false

    for host_item in "${HOSTS_TO_TEST[@]}"; do # 首次填充数据
        process_and_print_host_stats "$host_item"
    done
    first_cycle_complete=true

    while true; do
        sleep "$CONTINUOUS_INTERVAL_DEFAULT"

        if [[ "$use_tput_refresh" == "true" ]]; then
            command tput cuu "$num_hosts" # 光标上移N行到第一个数据行的开始
        else # Fallback to full refresh if tput not available/disabled
            if command_exists tput; then tput clear; else clear; fi
            echo "🔄 持续监测中... (按 Ctrl+C 退出)" # Re-print message and header
            echo
            print_header
        fi

        for host_item in "${HOSTS_TO_TEST[@]}"; do
            if [[ "$use_tput_refresh" == "true" ]]; then
                command tput el # 清除从光标到行尾的内容
            fi
            process_and_print_host_stats "$host_item"
        done
    done
else # 快速测试或自定义次数测试
    if command_exists tput; then tput clear; else clear; fi # 清屏开始
    echo "🚀 开始测试 (每个目标 ping $ping_count_this_run 次)..."
    print_header
    total_hosts=${#HOSTS_TO_TEST[@]}
    current_host_idx=0
    for host_item in "${HOSTS_TO_TEST[@]}"; do
        current_host_idx=$((current_host_idx + 1))
        process_and_print_host_stats "$host_item"
    done
    echo -e "\n✅ 测试完成。"
fi

exit 0