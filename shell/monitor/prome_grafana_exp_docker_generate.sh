#!/bin/bash

# ==============================================================================
# 脚本名称: generate_monitoring_compose.sh
# 脚本功能: 检查依赖环境 (Docker, Docker Compose), 生成用于部署 Prometheus, Grafana, Node Exporter 的 Docker Compose 文件。
# ==============================================================================

# --- 默认配置 ---
# 文件和网络相关
OUTPUT_FILE="docker-compose.yml" # 输出的 docker-compose 文件名
PROM_CONFIG_DIR="./prometheus"   # Prometheus 配置和数据持久化的主机基础路径
GRAFANA_DATA_DIR="./grafana/data" # Grafana 数据持久化的主机路径
NETWORK_NAME="monitoring-net"     # Docker 自定义网络名称，用于服务间通信

# Prometheus 服务配置
PROM_IMAGE="prom/prometheus:latest" # Prometheus 容器镜像
PROM_CONTAINER_NAME="prometheus"    # Prometheus 容器名称
PROM_PORT="9090"                    # Prometheus Web UI 对外暴露的主机端口
PROM_RESTART_POLICY="unless-stopped" # Prometheus 容器重启策略

# Grafana 服务配置
GRAFANA_IMAGE="grafana/grafana:latest" # Grafana 容器镜像
GRAFANA_CONTAINER_NAME="grafana"       # Grafana 容器名称
GRAFANA_PORT="3000"                    # Grafana Web UI 对外暴露的主机端口
GRAFANA_RESTART_POLICY="unless-stopped" # Grafana 容器重启策略
# 注意: Grafana 首次启动默认管理员用户/密码是 admin/admin，登录后会强制要求修改

# Node Exporter 服务配置 (用于收集主机指标)
NODE_EXPORTER_IMAGE="prom/node-exporter:latest" # Node Exporter 容器镜像
NODE_EXPORTER_CONTAINER_NAME="node-exporter"    # Node Exporter 容器名称
NODE_EXPORTER_PORT="9100"                       # Node Exporter 指标接口对外暴露的主机端口 (可选, 主要供 Prometheus 在网络内访问)
NODE_EXPORTER_RESTART_POLICY="unless-stopped" # Node Exporter 容器重启策略

# 用于存储检测到的 docker compose 命令 (v1 或 v2)
COMPOSE_CMD=""

# --- 帮助信息函数 ---
usage() {
  echo "用法: $0 [选项]"
  echo ""
  echo "该脚本用于生成监控组件 (Prometheus, Grafana, Node Exporter) 的 Docker Compose 配置。"
  echo ""
  echo "选项:"
  echo "  -f, --file <文件名>       指定输出的 docker-compose 文件名 (默认: ${OUTPUT_FILE})"
  echo "  --prom-port <端口>       指定 Prometheus 暴露到主机的端口 (默认: ${PROM_PORT})"
  echo "  --grafana-port <端口>    指定 Grafana 暴露到主机的端口 (默认: ${GRAFANA_PORT})"
  echo "  --node-exporter-port <端口> 指定 Node Exporter 暴露到主机的端口 (默认: ${NODE_EXPORTER_PORT})"
  echo "  --network <网络名>       指定 Docker 网络名称 (默认: ${NETWORK_NAME})"
  echo "  --prom-dir <目录>        指定 Prometheus 配置和数据存储的主机基础路径 (默认: ${PROM_CONFIG_DIR})"
  echo "  --grafana-dir <目录>     指定 Grafana 数据存储的主机路径 (默认: ${GRAFANA_DATA_DIR})"
  echo "  -h, --help                显示此帮助信息并退出"
  echo ""
  echo "脚本执行前会检查 Docker 和 Docker Compose 是否已安装。"
  echo "如果不提供任何选项，脚本将进入交互模式，引导您完成配置。"
  exit 0
}

# --- 检查依赖环境函数 ---
check_dependencies() {
  echo "--- 步骤 1: 检查依赖环境 ---"
  local docker_ok=false
  local compose_ok=false

  # 检查 Docker 是否安装
  if command -v docker &> /dev/null; then
    echo "[✓] 检测到 Docker 命令。"
    # 尝试连接 Docker 守护进程，确认服务是否运行
    if docker info &> /dev/null; then
        echo "[✓] Docker 服务正在运行。"
        docker_ok=true
    else
        echo "[!] Docker 命令存在，但无法连接到 Docker 守护进程。"
        echo "    请确认 Docker 服务已启动。您可以尝试运行: sudo systemctl start docker (或适合您系统的命令)"
        # 即使守护进程未运行，也认为 Docker 命令存在，让用户后续启动 compose 时再处理
        docker_ok=true # 或者根据严格程度设为 false 并退出: exit 1
    fi
  else
    echo "[✗] 未检测到 Docker 命令。"
    echo "    请先安装 Docker。参考官方文档:"
    echo "    https://docs.docker.com/engine/install/"
    # docker_ok 保持 false
  fi

  # 检查 Docker Compose 是否安装 (优先检查 v2 插件)
  # 只有 Docker 命令存在时才检查 Compose
  if [ "$docker_ok" = true ]; then
    if docker compose version &> /dev/null; then
      echo "[✓] 检测到 Docker Compose (v2 插件式命令: 'docker compose')"
      COMPOSE_CMD="docker compose" # 使用 v2 命令
      compose_ok=true
    elif command -v docker-compose &> /dev/null; then
      echo "[✓] 检测到 Docker Compose (v1 独立命令: 'docker-compose')"
      COMPOSE_CMD="docker-compose" # 使用 v1 命令
      compose_ok=true
    else
      echo "[✗] 未检测到 Docker Compose (v2 插件 'compose' 或 v1 命令 'docker-compose')。"
      echo "    请安装 Docker Compose。对于较新版本的 Docker，Compose 通常作为插件提供。"
      echo "    参考官方文档: https://docs.docker.com/compose/install/"
      # compose_ok 保持 false
    fi
  fi

  # 检查所有依赖是否都满足
  if [ "$docker_ok" = true ] && [ "$compose_ok" = true ]; then
    echo "--- 依赖环境检查通过 ---"
    echo "" # 添加空行以分隔
    return 0 # 返回成功状态码
  else
    echo "---------------------------"
    echo "错误：缺少必要的依赖项 (Docker 或 Docker Compose)。"
    echo "请根据上面的提示安装相应软件后重试。"
    exit 1 # 依赖检查失败，退出脚本
  fi
}

# --- 主脚本逻辑开始 ---

# 1. 检查依赖
check_dependencies

# 2. 解析命令行参数
# 使用 while 循环处理所有传入的参数
while [[ $# -gt 0 ]]; do
  key="$1" # 当前处理的参数名
  case $key in
    -f|--file) # 文件名选项
      OUTPUT_FILE="$2" # 获取选项的值 (下一个参数)
      shift # 移过参数名
      shift # 移过参数值
      ;;
    --prom-port) # Prometheus 端口选项
      PROM_PORT="$2"
      shift; shift
      ;;
    --grafana-port) # Grafana 端口选项
      GRAFANA_PORT="$2"
      shift; shift
      ;;
    --node-exporter-port) # Node Exporter 端口选项
      NODE_EXPORTER_PORT="$2"
      shift; shift
      ;;
    --network) # 网络名称选项
      NETWORK_NAME="$2"
      shift; shift
      ;;
    --prom-dir) # Prometheus 目录选项
      PROM_CONFIG_DIR="$2"
      # 规范化路径：移除末尾可能存在的斜杠
      PROM_CONFIG_DIR=${PROM_CONFIG_DIR%/}
      shift; shift
      ;;
    --grafana-dir) # Grafana 目录选项
      GRAFANA_DATA_DIR="$2"
      # 规范化路径：移除末尾可能存在的斜杠
      GRAFANA_DATA_DIR=${GRAFANA_DATA_DIR%/}
      shift; shift
      ;;
    -h|--help) # 帮助选项
      usage # 调用帮助函数并退出
      ;;
    *) # 未知选项处理
      echo "错误: 未知选项 '$1'" >&2 # 输出错误信息到 stderr
      usage # 显示帮助信息
      exit 1
      ;;
  esac
done

# 3. 交互式配置获取 (如果用户未通过命令行指定，则提示输入)
echo "--- 步骤 2: 配置 Docker Compose 参数 ---"
echo "请输入各项配置，或直接按 Enter 键接受方括号中的默认值。"
echo "--------------------------------------------------"

# 交互式获取输出文件名
read -p "设置 Docker Compose 输出文件名 [${OUTPUT_FILE}]: " input
OUTPUT_FILE=${input:-$OUTPUT_FILE} # 如果输入为空，使用默认值

# 交互式获取网络名称
read -p "设置 Docker 网络名称 [${NETWORK_NAME}]: " input
NETWORK_NAME=${input:-$NETWORK_NAME}

# --- Prometheus 相关配置 ---
echo "" # 空行分隔
echo "--- Prometheus 服务配置 ---"
read -p "Prometheus 容器镜像 [${PROM_IMAGE}]: " input
PROM_IMAGE=${input:-$PROM_IMAGE}
read -p "Prometheus 容器名 [${PROM_CONTAINER_NAME}]: " input
PROM_CONTAINER_NAME=${input:-$PROM_CONTAINER_NAME}
read -p "Prometheus 对外暴露端口 [${PROM_PORT}]: " input
PROM_PORT=${input:-$PROM_PORT}
read -p "Prometheus 配置和数据主机路径 [${PROM_CONFIG_DIR}]: " input
PROM_CONFIG_DIR=${input:-$PROM_CONFIG_DIR}
# 再次确保移除末尾斜杠，防止用户输入时添加
PROM_CONFIG_DIR=${PROM_CONFIG_DIR%/}
# 根据基础路径定义具体的配置文件和数据目录路径
PROM_CONFIG_FILE="${PROM_CONFIG_DIR}/prometheus.yml" # Prometheus 配置文件的主机绝对或相对路径
PROM_DATA_DIR="${PROM_CONFIG_DIR}/data"             # Prometheus 数据存储的主机绝对或相对路径

# --- Grafana 相关配置 ---
echo "" # 空行分隔
echo "--- Grafana 服务配置 ---"
read -p "Grafana 容器镜像 [${GRAFANA_IMAGE}]: " input
GRAFANA_IMAGE=${input:-$GRAFANA_IMAGE}
read -p "Grafana 容器名 [${GRAFANA_CONTAINER_NAME}]: " input
GRAFANA_CONTAINER_NAME=${input:-$GRAFANA_CONTAINER_NAME}
read -p "Grafana 对外暴露端口 [${GRAFANA_PORT}]: " input
GRAFANA_PORT=${input:-$GRAFANA_PORT}
read -p "Grafana 数据主机路径 [${GRAFANA_DATA_DIR}]: " input
GRAFANA_DATA_DIR=${input:-$GRAFANA_DATA_DIR}
# 再次确保移除末尾斜杠
GRAFANA_DATA_DIR=${GRAFANA_DATA_DIR%/}

# --- Node Exporter 相关配置 ---
echo "" # 空行分隔
echo "--- Node Exporter 服务配置 ---"
read -p "Node Exporter 容器镜像 [${NODE_EXPORTER_IMAGE}]: " input
NODE_EXPORTER_IMAGE=${input:-$NODE_EXPORTER_IMAGE} # 修正变量名
read -p "Node Exporter 容器名 [${NODE_EXPORTER_CONTAINER_NAME}]: " input
NODE_EXPORTER_CONTAINER_NAME=${input:-$NODE_EXPORTER_CONTAINER_NAME}
read -p "Node Exporter 对外暴露端口 [${NODE_EXPORTER_PORT}]: " input
NODE_EXPORTER_PORT=${input:-$NODE_EXPORTER_PORT}
echo "--------------------------------------------------"

# 4. 创建主机上的持久化目录
echo ""
echo "--- 步骤 3: 准备主机目录 ---"
echo "检查并创建 Prometheus 和 Grafana 所需的主机目录..."
# 使用 mkdir -p 可以创建多层嵌套目录，且如果目录已存在也不会报错
mkdir -p "${PROM_CONFIG_DIR}"
# 检查上一个命令的退出状态码，0 表示成功
if [ $? -ne 0 ]; then echo "错误: 无法创建目录 ${PROM_CONFIG_DIR}"; exit 1; fi
mkdir -p "${PROM_DATA_DIR}"
if [ $? -ne 0 ]; then echo "错误: 无法创建目录 ${PROM_DATA_DIR}"; exit 1; fi
mkdir -p "${GRAFANA_DATA_DIR}"
if [ $? -ne 0 ]; then echo "错误: 无法创建目录 ${GRAFANA_DATA_DIR}"; exit 1; fi
echo "[✓] 主机目录已准备就绪:"
echo "    Prometheus 配置: ${PROM_CONFIG_DIR}"
echo "    Prometheus 数据: ${PROM_DATA_DIR}"
echo "    Grafana 数据:    ${GRAFANA_DATA_DIR}"

# 5. 生成基础 Prometheus 配置文件 (prometheus.yml)
echo ""
echo "--- 步骤 4: 准备 Prometheus 配置文件 ---"
# 检查 Prometheus 配置文件是否已存在
if [ ! -f "${PROM_CONFIG_FILE}" ]; then
  echo "检测到 Prometheus 配置文件 (${PROM_CONFIG_FILE}) 不存在，将生成一个基础配置..."
  # 使用 cat 和 Heredoc (<< EOF) 创建文件内容
  cat << EOF > "${PROM_CONFIG_FILE}"
# 全局配置 (Global settings)
global:
  scrape_interval: 15s # 设置抓取目标的默认间隔为 15 秒
  evaluation_interval: 15s # 设置规则评估的默认间隔为 15 秒
  # scrape_timeout is set to the global default (10s).

# Alertmanager 配置 (可选, 如果需要告警功能则取消注释并配置)
# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets:
#           # - alertmanager:9093

# 规则文件加载 (可选, 如果有告警或记录规则则取消注释并指定文件)
# rule_files:
#   # - "first_rules.yml"
#   # - "second_rules.yml"

# 抓取配置 (Scrape configurations)
scrape_configs:
  # 抓取 Prometheus 自身指标的作业
  - job_name: 'prometheus'
    # metrics_path defaults to '/metrics'
    # scheme defaults to 'http'.
    static_configs:
      # 指定 Prometheus 自身的地址和端口 (在容器内部访问)
      - targets: ['localhost:9090']

  # 抓取 Node Exporter 指标的作业 (用于收集主机指标)
  - job_name: 'node_exporter'
    static_configs:
      # 指定 Node Exporter 的地址和端口
      # 使用 Docker Compose 的服务名 (${NODE_EXPORTER_CONTAINER_NAME}) 进行服务发现
      # Prometheus 和 Node Exporter 在同一个 Docker 网络 (${NETWORK_NAME}) 中
      - targets: ['${NODE_EXPORTER_CONTAINER_NAME}:${NODE_EXPORTER_PORT}']
EOF
  # 检查文件写入是否成功
  if [ $? -ne 0 ]; then
    echo "错误: 无法写入 Prometheus 配置文件 ${PROM_CONFIG_FILE}" >&2
    exit 1
  fi
  echo "[✓] 已生成基础 Prometheus 配置文件: ${PROM_CONFIG_FILE}"
else
  # 如果文件已存在，提示用户
  echo "[!] 注意: Prometheus 配置文件 ${PROM_CONFIG_FILE} 已存在，脚本不会覆盖它。"
  echo "    请确保该文件内容配置正确，特别是 node_exporter 的 target 地址。"
fi

# 6. 生成 Docker Compose 文件 (docker-compose.yml)
echo ""
echo "--- 步骤 5: 生成 Docker Compose 文件 ---"
echo "正在生成 ${OUTPUT_FILE} ..."

# 使用 cat 和 Heredoc 生成 docker-compose.yml 文件
# 注意 YAML 格式的缩进非常重要
cat << EOF > "${OUTPUT_FILE}"
# --- 由脚本自动生成的 Docker Compose 文件 ---
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 配置来源: 基于脚本默认值、命令行参数或交互式输入

# 指定 Docker Compose 文件格式版本
version: '3.7'

# 定义网络
networks:
  # 定义一个名为 ${NETWORK_NAME} 的 bridge 网络
  ${NETWORK_NAME}:
    driver: bridge # 使用标准的桥接网络驱动

# 定义卷 (关键修正点: 只有一个顶级的 volumes)
volumes:
  # 定义一个名为 prometheus_data_volume 的卷
  # 使用 local 驱动将主机上的目录绑定到这个卷
  prometheus_data_volume:
    driver: local
    driver_opts:
      type: 'none'       # 类型 'none' 表示不管理生命周期，直接绑定
      o: 'bind'          # 操作 'bind' 表示进行绑定挂载
      device: '${PROM_DATA_DIR}' # 指定要绑定的主机目录路径

  # 定义一个名为 grafana_data_volume 的卷
  # 同样使用 local 驱动绑定主机目录
  grafana_data_volume:
    driver: local
    driver_opts:
      type: 'none'
      o: 'bind'
      device: '${GRAFANA_DATA_DIR}' # 指定要绑定的 Grafana 数据主机目录路径

# 定义服务 (容器)
services:
  # Prometheus 服务定义
  prometheus:
    image: ${PROM_IMAGE}             # 使用的镜像
    container_name: ${PROM_CONTAINER_NAME} # 容器名称
    restart: ${PROM_RESTART_POLICY}  # 重启策略
    networks:                        # 加入的网络
      - ${NETWORK_NAME}
    ports:                           # 端口映射 (主机端口:容器端口)
      - "${PROM_PORT}:9090"
    volumes:                         # 卷挂载
      # 将主机上的 Prometheus 配置文件挂载到容器内的标准路径 (只读推荐, 但这里可写方便在线修改测试)
      - "${PROM_CONFIG_FILE}:/etc/prometheus/prometheus.yml"
      # 将上面定义的 prometheus_data_volume 卷挂载到容器内的数据存储路径
      - prometheus_data_volume:/prometheus
    command:                         # 容器启动时执行的命令
      # 指定 Prometheus 使用的配置文件
      - '--config.file=/etc/prometheus/prometheus.yml'
      # 指定 Prometheus 时间序列数据库 (TSDB) 的存储路径
      - '--storage.tsdb.path=/prometheus'
      # (可选) 启用 Web UI 的管理 API (例如，用于热加载配置)
      # - '--web.enable-lifecycle'
      # (可选) 设置数据保留时间，例如 90 天
      # - '--storage.tsdb.retention.time=90d'
    healthcheck:                     # (可选) 添加健康检查
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9090/-/healthy"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Grafana 服务定义
  grafana:
    image: ${GRAFANA_IMAGE}
    container_name: ${GRAFANA_CONTAINER_NAME}
    restart: ${GRAFANA_RESTART_POLICY}
    networks:
      - ${NETWORK_NAME}
    ports:
      - "${GRAFANA_PORT}:3000" # Grafana 默认监听 3000 端口
    volumes:
      # 将上面定义的 grafana_data_volume 卷挂载到容器内的 Grafana 数据目录
      # 这个目录包含了 Grafana 的数据库、插件、配置等
      - grafana_data_volume:/var/lib/grafana
    depends_on:                  # 依赖关系
      # 建议让 Grafana 在 Prometheus 启动后启动，虽然不是严格必须
      prometheus:
        condition: service_healthy # (如果添加了 healthcheck) 等待 Prometheus 健康后再启动
      # 如果没有 healthcheck，可以用:
      # - prometheus
    # (可选) 通过环境变量配置 Grafana，例如设置匿名访问或修改管理员密码 (不推荐硬编码密码)
    # environment:
    #   - GF_SECURITY_ADMIN_USER=admin
    #   - GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_admin_password # 推荐使用 secrets
    #   - GF_AUTH_ANONYMOUS_ENABLED=true
    #   - GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
    healthcheck:                 # (可选) Grafana 健康检查
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3


  # Node Exporter 服务定义 (收集主机指标)
  node-exporter:
    image: ${NODE_EXPORTER_IMAGE}
    container_name: ${NODE_EXPORTER_CONTAINER_NAME}
    restart: ${NODE_EXPORTER_RESTART_POLICY}
    networks:
      # 加入网络，以便 Prometheus 可以通过服务名访问它
      - ${NETWORK_NAME}
    ports:
      # 暴露端口到主机，主要用于调试，Prometheus 通常通过内部网络访问容器的 9100 端口
      - "${NODE_EXPORTER_PORT}:9100"
    # --- Node Exporter 特殊权限和挂载 ---
    pid: host # 允许 Node Exporter 访问主机的 PID 命名空间，以读取所有进程信息
    volumes:
      # 将主机的 /proc 文件系统 (包含进程和系统信息) 只读挂载到容器内
      - /proc:/host/proc:ro
      # 将主机的 /sys 文件系统 (包含硬件和内核信息) 只读挂载到容器内
      - /sys:/host/sys:ro
      # 将主机的根文件系统 (/) 只读挂载到容器内，用于读取磁盘等信息
      - /:/rootfs:ro
    command:
      # 告知 Node Exporter 主机文件系统挂载点的路径
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      # --path.rootfs
      # 修正之前的 --path.rootfs=/rootfs 参数，node-exporter 默认会探测根路径
      # 如果需要指定收集器，可以使用 --collector.<name>
      # 例如，只启用 cpu 和 memory 收集器:
      # - '--collector.disable-defaults'
      # - '--collector.cpu'
      # - '--collector.meminfo'
      # 例如，忽略某些挂载点:
      # - '--collector.filesystem.ignored-mount-points=^/(sys|proc|dev|host|etc|run/user)($$|/)'

EOF

# 7. 检查文件生成结果并提供后续操作指引
# 再次检查上一个命令 (cat) 的退出状态码
if [ $? -eq 0 ]; then
  echo "[✓] Docker Compose 文件 (${OUTPUT_FILE}) 已成功生成。"
  echo ""
  echo "--- 步骤 6: 后续操作 ---"
  echo "1. (建议) 检查生成的 ${OUTPUT_FILE} 和 ${PROM_CONFIG_FILE} 文件内容是否符合您的预期。"
  echo "2. 使用以下命令在后台启动所有服务:"
  # 使用之前检测到的正确的 Docker Compose 命令 (v1 或 v2)
  echo "   ${COMPOSE_CMD} -f ${OUTPUT_FILE} up -d"
  echo "3. 稍等片刻让服务启动，然后可以通过以下地址访问:"
  echo "   - Prometheus: http://<您的主机IP或域名>:${PROM_PORT}"
  echo "   - Grafana:    http://<您的主机IP或域名>:${GRAFANA_PORT}"
  echo "     (Grafana 首次登录用户名/密码: admin/admin，登录后请立即修改密码)"
  echo "4. 在 Grafana 中配置数据源:"
  echo "   - 类型选择 'Prometheus'"
  echo "   - HTTP URL 输入: http://${PROM_CONTAINER_NAME}:9090  (这是 Grafana 容器访问 Prometheus 容器的内部地址)"
  echo "   - 点击 'Save & Test'，应该会看到 'Data source is working' 的提示。"
  echo "5. 在 Grafana 中导入或创建仪表盘来可视化 Prometheus 收集的数据。"
  echo "   (例如，可以搜索 'Node Exporter Full' 仪表盘，ID 通常是 1860)"
  echo ""
  echo "查看日志: ${COMPOSE_CMD} -f ${OUTPUT_FILE} logs -f [服务名]"
  echo "停止服务: ${COMPOSE_CMD} -f ${OUTPUT_FILE} down"
  echo "--------------------------------------------------"
else
  # 如果 cat 命令失败
  echo "错误: 生成 Docker Compose 文件 ${OUTPUT_FILE} 时发生错误。" >&2
  exit 1
fi

# 脚本正常结束
exit 0