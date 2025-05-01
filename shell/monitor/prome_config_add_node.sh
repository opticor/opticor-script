#!/bin/bash

# --- 函数定义 ---

# 函数：检查 yq 是否安装且版本正确 (mikefarah/yq v4+)
check_yq() {
    echo "--- 正在检查依赖: yq (mikefarah/yq v4+) ---"
    if ! command -v yq &> /dev/null; then
        echo "错误：找不到 'yq' 命令。" >&2
        echo "此脚本需要 mikefarah/yq v4+ (Go 语言版 YAML 处理器)。" >&2
        echo "请访问 https://github.com/mikefarah/yq/ 获取安装指南。" >&2
        exit 1
    fi

    local yq_version_output
    yq_version_output=$(yq --version 2>&1)

    if [[ "$yq_version_output" =~ version\ v?4\. || "$yq_version_output" =~ yq\ v?4\. ]]; then
        echo "yq 版本检查通过: $(echo "$yq_version_output" | head -n 1)"
        echo "-----------------------------------------"
        echo
    else
        echo "错误：检测到的 'yq' 可能不是所需的 mikefarah/yq v4+ 版本。" >&2
        echo "检测到的输出: $yq_version_output" >&2
        echo "请确保安装了正确的 mikefarah/yq v4+ 版本。" >&2
        exit 1
    fi
}

# 函数：选择配置文件路径
select_config_file() {
    echo "#----------------------------------------------------#"
    echo "# 1. 选择 Prometheus 配置文件路径                 #"
    echo "#----------------------------------------------------#"
    echo "请选择 Prometheus 配置文件的路径："
    echo "  1) /etc/prometheus/prometheus.yml (默认)"
    echo "  2) ./prometheus/prometheus.yml"
    echo "  3) 自定义输入"

    local choice
    read -p "请输入选项编号 (1-3，默认为 1): " choice

    case "$choice" in
        1|"") prometheus_config_file="/etc/prometheus/prometheus.yml" ;;
        2)    prometheus_config_file="./prometheus/prometheus.yml" ;;
        3)    read -p "请输入完整的配置文件路径: " prometheus_config_file
              if [[ -z "$prometheus_config_file" ]]; then
                  echo "错误：配置文件路径不能为空。" >&2; exit 1
              fi
              ;;
        *)    echo "错误：无效的选项。" >&2; exit 1 ;;
    esac

    # 尝试解析为绝对路径
    if command -v realpath &> /dev/null && [[ "$prometheus_config_file" != /* && -e "$prometheus_config_file" ]]; then
        prometheus_config_file=$(realpath "$prometheus_config_file")
    fi
    echo "将使用的配置文件路径: $prometheus_config_file"

    # 检查文件是否存在及权限
    if [[ ! -f "$prometheus_config_file" ]]; then echo "错误：配置文件 '$prometheus_config_file' 不存在。" >&2; exit 1; fi
    if [[ ! -r "$prometheus_config_file" ]]; then echo "错误：没有读取 '$prometheus_config_file' 的权限。" >&2; exit 1; fi
    if [[ ! -w "$prometheus_config_file" ]]; then echo "错误：没有写入 '$prometheus_config_file' 的权限。" >&2; exit 1; fi

    # 验证 YAML 格式
    if ! yq eval '.' "$prometheus_config_file" > /dev/null 2>&1; then
        echo "错误：配置文件 '$prometheus_config_file' 不是有效的 YAML 格式。" >&2
        echo "请检查文件缩进（使用空格而非 Tab）和语法。" >&2
        exit 1
    fi
    echo "YAML 格式验证通过。"
}

# 函数：获取 Job Name
get_job_name() {
    echo ""
    echo "#----------------------------------------------------#"
    echo "# 2. 输入 Job Name                                  #"
    echo "#----------------------------------------------------#"
    read -p "请输入 Job Name (默认为 'node_exporter'): " job_name
    job_name=${job_name:-node_exporter}
    job_name=$(echo "$job_name" | sed "s/['\"]//g") # 移除可能存在的引号
    echo "使用的 Job Name: $job_name"
}

# 函数：获取节点信息
get_node_info() {
    echo ""
    echo "#----------------------------------------------------#"
    echo "# 3. 输入节点信息                                   #"
    echo "#----------------------------------------------------#"
    while true; do
        read -p "请输入新节点的 target 地址 (格式: <ip_or_hostname>:<port>): " node_target
        if [[ "$node_target" =~ ^[^:]+:[0-9]+$ ]]; then break
        else echo "错误：格式无效，请重新输入。"; fi
    done
    echo "节点 Target: $node_target"

    echo ""
    echo "#----------------------------------------------------#"
    echo "# 4. 输入节点 Label (可选)                           #"
    echo "#----------------------------------------------------#"
    read -p "请输入 'instance' 标签的值 (可选, 留空则无此标签): " instance_label
    if [[ -n "$instance_label" ]]; then echo "节点 Instance 标签: $instance_label"; else echo "未提供 Instance 标签。"; fi
}

# 函数：修改 Prometheus 配置 (版本：不使用 //= 初始化 scrape_configs)
modify_prometheus_config() {
    echo ""
    echo "#----------------------------------------------------#"
    echo "# 5. 修改配置文件                                   #"
    echo "#----------------------------------------------------#"

    # --- 备份 ---
    local backup_file="${prometheus_config_file}.bak_$(date +%Y%m%d_%H%M%S)"
    echo "正在备份配置文件到: $backup_file"
    cp "$prometheus_config_file" "$backup_file" || { echo "错误：备份失败。" >&2; exit 1; }

    # --- 确保 scrape_configs 结构 ---
    local scrape_configs_type
    scrape_configs_type=$(yq eval '.scrape_configs | type' "$prometheus_config_file" 2>/dev/null)
    local type_check_status=$?
    if [[ $type_check_status -ne 0 ]]; then scrape_configs_type="!!null"; fi # Treat error as null

    if [[ "$scrape_configs_type" != "!!seq" && "$scrape_configs_type" != "!!null" ]]; then
        echo "错误: 配置中的 'scrape_configs' 存在但不是一个列表。类型: $scrape_configs_type。" >&2
        mv "$backup_file" "$prometheus_config_file"; exit 1
    fi
    if [[ "$scrape_configs_type" == "!!null" ]]; then
        yq eval -i '.scrape_configs = []' "$prometheus_config_file" || {
            echo "错误：初始化 'scrape_configs' 为空列表失败。" >&2; mv "$backup_file" "$prometheus_config_file"; exit 1;
        }
    fi

    # --- 检查 Job 是否存在 ---
    local job_exists_cmd="yq eval \"(.scrape_configs[] | select(.job_name == \\\"$job_name\\\")) | length > 0\" \"$prometheus_config_file\""
    local job_exists
    job_exists=$(eval "$job_exists_cmd" 2>&1)
    local yq_check_status=$?
    if [[ $yq_check_status -ne 0 ]]; then
        echo "错误：yq 命令在检查 Job Name 时失败。" >&2; echo "yq 输出: $job_exists" >&2
        mv "$backup_file" "$prometheus_config_file"; exit 1
    fi

    # --- 根据 Job 是否存在执行不同操作 ---
    if [[ "$job_exists" == "true" ]]; then
        # --- Job 已存在 ---
        echo "Job Name '$job_name' 已存在。"

        local target_added_to_existing_instance=false # 标记是否已添加到现有 instance

        # 仅当用户提供了 instance 标签时，才尝试合并
        if [[ -n "$instance_label" ]]; then
            echo "检查是否存在具有相同 instance ('$instance_label') 的现有条目..."

            # 查找具有相同 instance label 的 static_configs 条目是否存在
            local instance_exists_cmd="yq eval \"((.scrape_configs[] | select(.job_name == \\\"$job_name\\\") | .static_configs[]) | select(.labels.instance == \\\"$instance_label\\\")) | length > 0\" \"$prometheus_config_file\""
            local instance_exists
            instance_exists=$(eval "$instance_exists_cmd" 2>&1)
            local instance_check_status=$?

            if [[ $instance_check_status -ne 0 ]]; then
                 echo "警告：检查现有 instance 时 yq 命令失败，将创建新条目。" >&2
                 echo "yq 输出: $instance_exists" >&2
                 # 继续执行，当作没找到处理
                 instance_exists="false"
            fi

            if [[ "$instance_exists" == "true" ]]; then
                # --- 找到匹配的 Instance，合并 Target ---
                echo "找到匹配的 instance，将 target '$node_target' 添加到其 targets 列表..."
                local merge_target_cmd="yq eval -i \"((.scrape_configs[] | select(.job_name == \\\"$job_name\\\") | .static_configs[] | select(.labels.instance == \\\"$instance_label\\\")) | .targets) += [\\\"$node_target\\\"]\" \"$prometheus_config_file\""

                eval "$merge_target_cmd" || {
                    echo "错误：向现有 instance ('$instance_label') 添加 target 失败。" >&2
                    # 尝试模拟执行
                    echo "模拟执行: $merge_target_cmd" >&2
                    yq eval "((.scrape_configs[] | select(.job_name == \"$job_name\") | .static_configs[] | select(.labels.instance == \"$instance_label\")) | .targets) += [\"$node_target\"]" "$prometheus_config_file" >/dev/null 2>&1
                    mv "$backup_file" "$prometheus_config_file"; exit 1;
                }
                echo "Target 已成功合并到 instance '$instance_label'。"
                target_added_to_existing_instance=true # 标记完成
            else
                 echo "未找到具有相同 instance ('$instance_label') 的条目。"
            fi
        fi # 结束 instance label 检查

        # --- 如果未合并到现有 instance (因为没提供 label，或没找到匹配的)，则创建新条目 ---
        if [[ "$target_added_to_existing_instance" == "false" ]]; then
            echo "为 target '$node_target' 创建新的 static_configs 条目..."

            # 验证 Job 内的 static_configs 是列表 (之前已做过初步验证)
            local check_sc_list_cmd="yq eval '(.scrape_configs[] | select(.job_name == \"$job_name\") | .static_configs | length) >= 0' '$prometheus_config_file'"
            local is_list
            is_list=$(eval "$check_sc_list_cmd" 2>&1)
            local check_status=$?
            if [[ $check_status -ne 0 || "$is_list" != "true" ]]; then
                # 如果此时 static_configs 不是列表（理论上不太可能发生，除非手动修改了文件），尝试初始化
                 local create_list_cmd="yq eval -i '(.scrape_configs[] | select(.job_name == \"$job_name\") | .static_configs) = []' '$prometheus_config_file'"
                 eval "$create_list_cmd" || {
                    echo "错误: Job '$job_name' 的 'static_configs' 不是列表，且尝试创建失败。" >&2
                    mv "$backup_file" "$prometheus_config_file"; exit 1;
                 }
                 echo "警告: Job '$job_name' 的 'static_configs' 不是列表，已强制初始化为空列表。"
            fi

            # 构建并执行添加新条目的命令
            local add_entry_cmd
            if [[ -n "$instance_label" ]]; then
                add_entry_cmd="(.scrape_configs[] | select(.job_name == \"$job_name\") | .static_configs) += [{\"targets\": [\"$node_target\"], \"labels\": {\"instance\": \"$instance_label\"}}]"
            else
                # 没有 instance label，就不加 labels 字段或加空 labels
                add_entry_cmd="(.scrape_configs[] | select(.job_name == \"$job_name\") | .static_configs) += [{\"targets\": [\"$node_target\"]}]"
            fi

            yq eval -i "$add_entry_cmd" "$prometheus_config_file" || {
                echo "错误：在 Job '$job_name' 内添加新的 static_configs 条目失败。" >&2
                echo "模拟执行: yq eval '$add_entry_cmd' '$prometheus_config_file'" >&2
                yq eval "$add_entry_cmd" "$prometheus_config_file" > /dev/null 2>&1
                mv "$backup_file" "$prometheus_config_file"; exit 1;
            }
            echo "新的 static_configs 条目已成功添加到 Job '$job_name'。"
        fi # 结束创建新条目的逻辑

    elif [[ "$job_exists" == "false" ]]; then
        # --- Job 不存在: 创建新的 Job ---
        echo "Job Name '$job_name' 不存在，创建新的 Job 配置..."
        local add_job_cmd
        if [[ -n "$instance_label" ]]; then
             add_job_cmd=".scrape_configs += [{ \"job_name\": \"$job_name\", \"static_configs\": [ { \"targets\": [\"$node_target\"], \"labels\": { \"instance\": \"$instance_label\" } } ] }]"
        else
             add_job_cmd=".scrape_configs += [{ \"job_name\": \"$job_name\", \"static_configs\": [ { \"targets\": [\"$node_target\"] } ] }]"
        fi

        yq eval -i "$add_job_cmd" "$prometheus_config_file" || {
            echo "错误：创建新的 Job '$job_name' 失败。" >&2
            echo "模拟执行: yq eval '$add_job_cmd' '$prometheus_config_file'" >&2
            yq eval "$add_job_cmd" "$prometheus_config_file" > /dev/null 2>&1
            mv "$backup_file" "$prometheus_config_file"; exit 1;
        }
        echo "新的 Job '$job_name' 已成功添加。"

    else
        # --- 意外情况 ---
        echo "错误：检查 Job Name 的 yq 命令返回了意外的输出: '$job_exists'" >&2
        mv "$backup_file" "$prometheus_config_file"; exit 1
    fi

    # --- 完成 ---
    echo ""
    echo "#----------------------------------------------------#"
    echo "# 配置修改完成                                       #"
    echo "#----------------------------------------------------#"
    echo "配置文件 '$prometheus_config_file' 已更新。"
    echo "原始文件已备份为 '$backup_file'。"
    echo "请检查文件内容，并根据需要重新加载 Prometheus 配置。"
    echo "  (例如: kill -HUP <pid>, systemctl reload prometheus, docker/k8s 命令, 或 /-/reload API)"
}


# --- 主程序 ---
check_yq
select_config_file
get_job_name
get_node_info
modify_prometheus_config
exit 0