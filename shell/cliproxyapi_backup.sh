#!/bin/bash
set -uo pipefail
# =============================================================================
# CLIProxyAPI 增量备份脚本
# 基础路径: http(s)://localhost:8317/v0/management
# 策略:
#   - 备份文件不存在 → GET /usage/export 全量备份
#   - 备份文件存在   → GET /usage/export 获取新快照，与旧快照按 details 合并去重后更新
# =============================================================================

# ======================== 配置变量 ========================
ROUTER_HOST="127.0.0.1"
ROUTER_PORT="8317"
ROUTER_SCHEME="http"
ROUTER_TLS_NAME=""
API_KEY=""                          # Authorization Bearer Key
BACKUP_DIR="./router_backup"        # 备份目录
BACKUP_FILE="usage_backup.json"     # 主备份文件（始终保持最新全量）
LOG_LEVEL="${LOG_LEVEL:-INFO}"      # DEBUG / INFO / WARN / ERROR
TLS_INSECURE=false
SERVICE_UNIT="cliproxyapi.service"  # 默认 systemd 服务名

# ====================== 内部变量 ==========================
REQUEST_HOST="${ROUTER_HOST}"
BASE_URL="${ROUTER_SCHEME}://${REQUEST_HOST}:${ROUTER_PORT}/v0/management"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"
TMP_RESTART_BACKUP=""

# ====================== 工具函数 ==========================

log() {
    local level="$1"; shift
    local msg="$*"
    local cur_rank msg_rank

    case "$LOG_LEVEL" in
        DEBUG) cur_rank=0 ;;
        INFO)  cur_rank=1 ;;
        WARN)  cur_rank=2 ;;
        ERROR) cur_rank=3 ;;
        *)     cur_rank=1 ;;
    esac

    case "$level" in
        DEBUG) msg_rank=0 ;;
        INFO)  msg_rank=1 ;;
        WARN)  msg_rank=2 ;;
        ERROR) msg_rank=3 ;;
        *)     msg_rank=1 ;;
    esac

    [[ $msg_rank -ge $cur_rank ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}" >&2
}

die() { log "ERROR" "$*"; exit 1; }

check_deps() {
    for dep in curl jq; do
        command -v "$dep" &>/dev/null || die "缺少依赖: $dep"
    done
}

check_config() {
    [[ -z "$API_KEY" ]] && die "API_KEY 未配置"
    [[ "$ROUTER_SCHEME" == "http" || "$ROUTER_SCHEME" == "https" ]] \
        || die "ROUTER_SCHEME 仅支持 http 或 https"
    if [[ "$ROUTER_SCHEME" != "https" && -n "$ROUTER_TLS_NAME" ]]; then
        die "--tls-name 仅适用于 HTTPS"
    fi
}

require_arg_value() {
    local flag="$1"
    local value="${2:-}"
    [[ -n "$value" && "$value" != -* ]] || die "参数 ${flag} 缺少值"
}

validate_snapshot() {
    local snapshot="$1"
    echo "$snapshot" | jq -e '
        .usage
        and (.usage | type == "object")
        and ((.usage.apis // {}) | type == "object")
    ' >/dev/null || return 1
}

write_snapshot_file() {
    local snapshot="$1"
    local target="$2"
    local tmp_file

    tmp_file=$(mktemp "${BACKUP_DIR}/.tmp_usage_XXXXXX") || die "创建临时文件失败"
    echo "$snapshot" | jq '.' > "$tmp_file" \
        || { rm -f "$tmp_file"; die "写入临时文件失败: ${tmp_file}"; }
    mv "$tmp_file" "$target" \
        || { rm -f "$tmp_file"; die "替换备份文件失败: ${target}"; }
}

cleanup_restart_tmp() {
    if [[ -n "${TMP_RESTART_BACKUP}" && -f "${TMP_RESTART_BACKUP}" ]]; then
        rm -f "${TMP_RESTART_BACKUP}" || true
        TMP_RESTART_BACKUP=""
    fi
}
# ====================== API 函数 ==========================

# GET /usage/export — 导出完整快照
api_export() {
    log "INFO" "请求 GET ${BASE_URL}/usage/export"

    local http_code tmp_body
    tmp_body=$(mktemp)
    local exit_code

    if [[ "$TLS_INSECURE" == "true" && -n "$ROUTER_TLS_NAME" ]]; then
        http_code=$(curl -s -k \
            --resolve "${ROUTER_TLS_NAME}:${ROUTER_PORT}:${ROUTER_HOST}" \
            -o "${tmp_body}" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            --connect-timeout 10 \
            --max-time 30 \
            "${BASE_URL}/usage/export")
        exit_code=$?
    elif [[ "$TLS_INSECURE" == "true" ]]; then
        http_code=$(curl -s -k \
            -o "${tmp_body}" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            --connect-timeout 10 \
            --max-time 30 \
            "${BASE_URL}/usage/export")
        exit_code=$?
    elif [[ -n "$ROUTER_TLS_NAME" ]]; then
        http_code=$(curl -s \
            --resolve "${ROUTER_TLS_NAME}:${ROUTER_PORT}:${ROUTER_HOST}" \
            -o "${tmp_body}" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            --connect-timeout 10 \
            --max-time 30 \
            "${BASE_URL}/usage/export")
        exit_code=$?
    else
        http_code=$(curl -s \
            -o "${tmp_body}" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            --connect-timeout 10 \
            --max-time 30 \
            "${BASE_URL}/usage/export")
        exit_code=$?
    fi

    if [[ $exit_code -ne 0 ]]; then
        rm -f "$tmp_body"
        die "curl 请求失败 [exit=${exit_code}]"
    fi

    if [[ "$http_code" != "200" ]]; then
        log "ERROR" "HTTP ${http_code}，响应: $(cat "${tmp_body}")"
        rm -f "$tmp_body"
        return 1
    fi

    cat "$tmp_body"
    rm -f "$tmp_body"
    return 0
}

# ====================== 备份逻辑 ==========================

# 全量备份：直接保存 export 快照
# POST /usage/import - import and merge snapshot
api_import() {
    local source_file="$1"
    log "INFO" "Request POST ${BASE_URL}/usage/import from file: ${source_file}"

    local http_code tmp_body
    tmp_body=$(mktemp)
    local exit_code

    if [[ "$TLS_INSECURE" == "true" && -n "$ROUTER_TLS_NAME" ]]; then
        http_code=$(curl -s -k \
            --resolve "${ROUTER_TLS_NAME}:${ROUTER_PORT}:${ROUTER_HOST}" \
            -X POST \
            -o "${tmp_body}" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            --data-binary "@${source_file}" \
            --connect-timeout 10 \
            --max-time 60 \
            "${BASE_URL}/usage/import")
        exit_code=$?
    elif [[ "$TLS_INSECURE" == "true" ]]; then
        http_code=$(curl -s -k \
            -X POST \
            -o "${tmp_body}" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            --data-binary "@${source_file}" \
            --connect-timeout 10 \
            --max-time 60 \
            "${BASE_URL}/usage/import")
        exit_code=$?
    elif [[ -n "$ROUTER_TLS_NAME" ]]; then
        http_code=$(curl -s \
            --resolve "${ROUTER_TLS_NAME}:${ROUTER_PORT}:${ROUTER_HOST}" \
            -X POST \
            -o "${tmp_body}" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            --data-binary "@${source_file}" \
            --connect-timeout 10 \
            --max-time 60 \
            "${BASE_URL}/usage/import")
        exit_code=$?
    else
        http_code=$(curl -s \
            -X POST \
            -o "${tmp_body}" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            --data-binary "@${source_file}" \
            --connect-timeout 10 \
            --max-time 60 \
            "${BASE_URL}/usage/import")
        exit_code=$?
    fi

    if [[ $exit_code -ne 0 ]]; then
        rm -f "$tmp_body"
        die "curl request failed [exit=${exit_code}]"
    fi

    if [[ "$http_code" != "200" ]]; then
        log "ERROR" "HTTP ${http_code}, response: $(cat "${tmp_body}")"
        rm -f "$tmp_body"
        return 1
    fi

    cat "$tmp_body"
    rm -f "$tmp_body"
    return 0
}

do_restore() {
    local restore_path="$1"
    log "INFO" "======== Restore Start ========"

    [[ -f "$restore_path" ]] || die "restore file not found: ${restore_path}"
    [[ -r "$restore_path" ]] || die "restore file is not readable: ${restore_path}"
    jq -e . "$restore_path" >/dev/null || die "restore file is not valid JSON: ${restore_path}"

    local snapshot
    snapshot=$(cat "$restore_path") || die "failed to read restore file: ${restore_path}"
    validate_snapshot "$snapshot" || die "invalid snapshot structure in restore file: ${restore_path}"

    local import_result
    import_result=$(api_import "$restore_path") || die "restore import failed: ${restore_path}"

    local added skipped total_requests failed_requests
    added=$(echo "$import_result" | jq '.added // 0')
    skipped=$(echo "$import_result" | jq '.skipped // 0')
    total_requests=$(echo "$import_result" | jq '.total_requests // 0')
    failed_requests=$(echo "$import_result" | jq '.failed_requests // 0')

    log "INFO" "Restore completed"
    log "INFO" "  file: ${restore_path}"
    log "INFO" "  added: ${added}"
    log "INFO" "  skipped: ${skipped}"
    log "INFO" "  total_requests: ${total_requests}"
    log "INFO" "  failed_requests: ${failed_requests}"
    log "INFO" "======== Restore End =========="
}
detect_running_service_scope() {
    local service_name="$1"

    if systemctl --user is-active --quiet "${service_name}" 2>/dev/null; then
        echo "user"
        return 0
    fi

    if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
        echo "system"
        return 0
    fi

    return 1
}

restart_service_by_scope() {
    local scope="$1"
    local service_name="$2"

    if [[ "$scope" == "user" ]]; then
        log "INFO" "重启用户服务: systemctl --user restart ${service_name}"
        systemctl --user restart "${service_name}" || return 1
        systemctl --user is-active --quiet "${service_name}" || return 1
        return 0
    fi

    log "INFO" "重启系统服务: systemctl restart ${service_name}"
    if systemctl restart "${service_name}" 2>/dev/null; then
        :
    elif command -v sudo &>/dev/null; then
        sudo systemctl restart "${service_name}" || return 1
    else
        return 1
    fi

    if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
        :
    elif command -v sudo &>/dev/null; then
        sudo systemctl is-active --quiet "${service_name}" || return 1
    else
        return 1
    fi
}

do_restart_with_backup_restore() {
    local service_name="$1"
    local scope snapshot exported_at total_requests

    command -v systemctl &>/dev/null || die "缺少依赖: systemctl"
    mkdir -p "${BACKUP_DIR}" || die "无法创建备份目录: ${BACKUP_DIR}"

    TMP_RESTART_BACKUP=$(mktemp "${BACKUP_DIR}/.tmp_restart_usage_XXXXXX.json") \
        || die "创建重启临时备份文件失败"
    trap cleanup_restart_tmp EXIT

    log "INFO" "======== 重启服务流程开始 ========"
    log "INFO" "Step 1/4: 导出全量快照到临时文件"
    snapshot=$(api_export) || die "导出全量快照失败"
    validate_snapshot "$snapshot" || die "导出的快照格式无效"
    write_snapshot_file "$snapshot" "${TMP_RESTART_BACKUP}"
    exported_at=$(echo "$snapshot" | jq -r '.exported_at // "unknown"')
    total_requests=$(echo "$snapshot" | jq '.usage.total_requests // 0')
    log "INFO" "  临时文件: ${TMP_RESTART_BACKUP}"
    log "INFO" "  exported_at: ${exported_at}, total_requests: ${total_requests}"

    log "INFO" "Step 2/4: 检测并重启正在运行的服务"
    scope=$(detect_running_service_scope "${service_name}") \
        || die "未检测到正在运行的服务: ${service_name}（--user 与系统级都未运行）"
    log "INFO" "  运行作用域: ${scope}"
    restart_service_by_scope "${scope}" "${service_name}" \
        || die "服务重启失败: ${service_name} (${scope})"
    log "INFO" "  服务重启成功"

    log "INFO" "Step 3/4: 从临时文件恢复快照"
    do_restore "${TMP_RESTART_BACKUP}"

    log "INFO" "Step 4/4: 清理临时文件"
    cleanup_restart_tmp
    trap - EXIT

    log "INFO" "======== 重启服务流程完成 ========"
}
do_full_backup() {
    log "INFO" "======== 全量备份开始 ========"

    local snapshot
    snapshot=$(api_export) || die "全量备份失败"

    # 验证返回的是合法 JSON
    validate_snapshot "$snapshot" \
        || die "export 返回内容异常: ${snapshot}"

    write_snapshot_file "$snapshot" "${BACKUP_PATH}"

    local total_requests exported_at
    total_requests=$(echo "$snapshot" | jq '.usage.total_requests // 0')
    exported_at=$(echo "$snapshot"    | jq -r '.exported_at // "unknown"')

    log "INFO" "全量备份完成"
    log "INFO" "  导出时间: ${exported_at}"
    log "INFO" "  总请求数: ${total_requests}"
    log "INFO" "  保存路径: ${BACKUP_PATH}"
    log "INFO" "======== 全量备份结束 ========"
}

# 增量备份：
#   1. 获取当前服务端最新快照（new_snapshot）
#   2. 将旧备份与最新快照按 api/model/details 合并去重
#   3. 从合并后的 details 重新计算全部统计字段
do_incremental_backup() {
    log "INFO" "======== 增量备份开始 ========"

    local old_snapshot_file new_snapshot_file
    old_snapshot_file=$(mktemp "${BACKUP_DIR}/.tmp_old_snapshot_XXXXXX.json") || die "创建旧快照临时文件失败"
    new_snapshot_file=$(mktemp "${BACKUP_DIR}/.tmp_new_snapshot_XXXXXX.json") || {
        rm -f "$old_snapshot_file"
        die "创建新快照临时文件失败"
    }

    # --- Step 1: 读取旧备份 ---
    local old_snapshot
    old_snapshot=$(cat "${BACKUP_PATH}") \
        || {
            rm -f "$old_snapshot_file" "$new_snapshot_file"
            die "读取旧备份文件失败: ${BACKUP_PATH}"
        }
    validate_snapshot "$old_snapshot" \
        || {
            rm -f "$old_snapshot_file" "$new_snapshot_file"
            die "旧备份文件格式无效: ${BACKUP_PATH}"
        }
    printf '%s\n' "$old_snapshot" > "$old_snapshot_file" \
        || {
            rm -f "$old_snapshot_file" "$new_snapshot_file"
            die "写入旧快照临时文件失败"
        }

    local old_total old_exported
    old_total=$(echo "$old_snapshot"    | jq '.usage.total_requests // 0')
    old_exported=$(echo "$old_snapshot" | jq -r '.exported_at // "unknown"')
    log "INFO" "旧备份: exported_at=${old_exported}, total_requests=${old_total}"

    # --- Step 2: 获取服务端最新快照 ---
    local new_snapshot
    new_snapshot=$(api_export) || {
        rm -f "$old_snapshot_file" "$new_snapshot_file"
        die "获取最新快照失败"
    }

    validate_snapshot "$new_snapshot" \
        || {
            rm -f "$old_snapshot_file" "$new_snapshot_file"
            die "export 返回内容异常: ${new_snapshot}"
        }
    printf '%s\n' "$new_snapshot" > "$new_snapshot_file" \
        || {
            rm -f "$old_snapshot_file" "$new_snapshot_file"
            die "写入新快照临时文件失败"
        }

    local new_total new_exported
    new_total=$(echo "$new_snapshot"    | jq '.usage.total_requests // 0')
    new_exported=$(echo "$new_snapshot" | jq -r '.exported_at // "unknown"')
    log "INFO" "新快照: exported_at=${new_exported}, total_requests=${new_total}"

    # --- Step 3: 本地合并（按明细去重后重新汇总，不改动服务端） ---
    log "INFO" "本地合并快照..."

    local merged_snapshot
    merged_snapshot=$(jq -n \
        --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        (input) as $old |
        (input) as $new |
        def safe_total_tokens($d):
            ($d.tokens.total_tokens // 0);

        def details_signature:
            tojson;

        def group_counts(stream; key_expr; value_expr):
            reduce stream[] as $item
                ({}; .[$item | key_expr] = ((.[$item | key_expr] // 0) + ($item | value_expr)));

        def merged_details_by_api_model(a; b):
            reduce (
                [a.apis // {}, b.apis // {}]
                | add
                | keys_unsorted[]
            ) as $api
                ({};
                    . + {
                        ($api): (
                            reduce (
                                [((a.apis[$api] // {}).models // {}), (((b.apis[$api] // {}).models) // {})]
                                | add
                                | keys_unsorted[]
                            ) as $model
                                ({};
                                    . + {
                                        ($model): (
                                            [
                                                ((((a.apis[$api] // {}).models // {})[$model] // {}).details // []),
                                                ((((b.apis[$api] // {}).models // {})[$model] // {}).details // [])
                                            ]
                                            | add
                                            | unique_by(details_signature)
                                            | sort_by(.timestamp // "")
                                        )
                                    }
                                )
                        )
                    }
                );

        def rebuild_usage($details_map):
            ($details_map | to_entries) as $api_entries |
            ($api_entries
                | map(
                    .value
                    | to_entries
                    | map(
                        .key as $model |
                        .value as $details |
                        {
                            key: $model,
                            value: {
                                total_requests: ($details | length),
                                total_tokens: ([ $details[]? | safe_total_tokens(.) ] | add // 0),
                                details: $details
                            }
                        }
                    )
                )
            ) as $models_per_api |
            ([ $api_entries[]?.value[]?[]? ] | sort_by(.timestamp // "")) as $all_details |
            {
                total_requests: ($all_details | length),
                success_count: ([ $all_details[]? | select((.failed // false) | not) ] | length),
                failure_count: ([ $all_details[]? | select(.failed // false) ] | length),
                total_tokens: ([ $all_details[]? | safe_total_tokens(.) ] | add // 0),
                requests_by_day: group_counts($all_details; .timestamp[0:10]; 1),
                requests_by_hour: group_counts($all_details; .timestamp[11:13]; 1),
                tokens_by_day: group_counts($all_details; .timestamp[0:10]; safe_total_tokens(.)),
                tokens_by_hour: group_counts($all_details; .timestamp[11:13]; safe_total_tokens(.)),
                apis: (
                    reduce range(0; $api_entries | length) as $i
                        ({};
                            ($api_entries[$i].key) as $api |
                            ($models_per_api[$i]) as $models |
                            . + {
                                ($api): {
                                    total_requests: ([ $models[]?.value.total_requests ] | add // 0),
                                    total_tokens: ([ $models[]?.value.total_tokens ] | add // 0),
                                    models: ($models | from_entries)
                                }
                            }
                        )
                )
            };

        {
            version: 1,
            exported_at: $now,
            usage: rebuild_usage(merged_details_by_api_model($old.usage; $new.usage))
        }
    ' "$old_snapshot_file" "$new_snapshot_file") || {
        rm -f "$old_snapshot_file" "$new_snapshot_file"
        die "jq 合并失败"
    }
    rm -f "$old_snapshot_file" "$new_snapshot_file"

    # --- Step 4: 统计新增数量 ---
    local merged_total added_count
    merged_total=$(echo "$merged_snapshot" | jq '.usage.total_requests // 0')
    added_count=$((merged_total - old_total))
    # added_count 可能为负（服务重启归零后旧备份更大），此时取 0
    [[ $added_count -lt 0 ]] && added_count=0

    if [[ $added_count -eq 0 ]] && [[ "$new_total" -le "$old_total" ]]; then
        log "INFO" "无新数据（服务端 ${new_total} 条 ≤ 旧备份 ${old_total} 条），跳过写入"
        log "INFO" "======== 增量备份结束（无变化）========"
        return 0
    fi

    validate_snapshot "$merged_snapshot" \
        || die "合并后的快照格式无效"
    write_snapshot_file "$merged_snapshot" "${BACKUP_PATH}"

    log "INFO" "增量备份完成"
    log "INFO" "  旧记录数: ${old_total}"
    log "INFO" "  新记录数: ${merged_total}"
    log "INFO" "  新增条数: ${added_count}"
    log "INFO" "  保存路径: ${BACKUP_PATH}"
    log "INFO" "======== 增量备份结束 ========"
}

# ====================== 历史归档（可选）==========================

# 每次备份前保留一份带时间戳的副本
archive_backup() {
    if [[ -f "${BACKUP_PATH}" ]]; then
        local archive_name
        archive_name="${BACKUP_DIR}/archive/usage_$(date '+%Y%m%d_%H%M%S').json"
        mkdir -p "${BACKUP_DIR}/archive"
        cp "${BACKUP_PATH}" "$archive_name" \
            && log "INFO" "旧备份已归档: ${archive_name}" \
            || log "WARN" "归档失败，继续执行"
    fi
}

# ====================== 参数解析 ==========================

show_help() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  -h, --host   HOST    路由器地址   (默认: ${ROUTER_HOST})
  -p, --port   PORT    端口         (默认: ${ROUTER_PORT})
  -s, --scheme SCHEME  协议         (默认: ${ROUTER_SCHEME})
  --tls-name   DOMAIN  HTTPS 证书域名/SNI
  -k, --key    KEY     API Key
  -d, --dir    DIR     备份目录     (默认: ${BACKUP_DIR})
  -f, --file   FILE    备份文件名   (默认: ${BACKUP_FILE})
  -r, --restore FILE   从指定 JSON 文件恢复并导入 usage（合并去重）
  --restart            重启服务并自动执行临时全量备份->恢复
  --service-unit UNIT  要重启的 systemd 服务名 (默认: ${SERVICE_UNIT})
  --https              等价于 --scheme https
  --insecure           HTTPS 时跳过证书校验
  --full               强制全量备份
  --no-archive         不保留历史副本
  --help               显示帮助

示例:
  $(basename "$0") -k your_api_key
  $(basename "$0") --https -h router.example.com -k your_key
  $(basename "$0") --https -h 127.0.0.1 -p 8320 --tls-name router.example.com -k your_key
  $(basename "$0") -h 192.168.1.1 -p 8317 -k your_key -d /data/backup
  $(basename "$0") --full -k your_key
  $(basename "$0") --restore /data/backup/usage_backup.json -k your_key
  $(basename "$0") --restart --service-unit cliproxyapi.service -k your_key
EOF
}

FORCE_FULL=false
NO_ARCHIVE=false
RESTORE_FILE=""
RESTART_SERVICE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--host)       require_arg_value "$1" "${2:-}"; ROUTER_HOST="$2"; shift 2 ;;
            -p|--port)       require_arg_value "$1" "${2:-}"; ROUTER_PORT="$2"; shift 2 ;;
            -s|--scheme)     require_arg_value "$1" "${2:-}"; ROUTER_SCHEME="$2"; shift 2 ;;
            --tls-name)      require_arg_value "$1" "${2:-}"; ROUTER_TLS_NAME="$2"; shift 2 ;;
            -k|--key)        require_arg_value "$1" "${2:-}"; API_KEY="$2"; shift 2 ;;
            -d|--dir)        require_arg_value "$1" "${2:-}"; BACKUP_DIR="$2"; shift 2 ;;
            -f|--file)       require_arg_value "$1" "${2:-}"; BACKUP_FILE="$2"; shift 2 ;;
            -r|--restore)    require_arg_value "$1" "${2:-}"; RESTORE_FILE="$2"; shift 2 ;;
            --restart)       RESTART_SERVICE=true; shift ;;
            --service-unit)  require_arg_value "$1" "${2:-}"; SERVICE_UNIT="$2"; shift 2 ;;
            --https)         ROUTER_SCHEME="https"; shift ;;
            --insecure)      TLS_INSECURE=true; shift ;;
            --full)          FORCE_FULL=true;  shift ;;
            --no-archive)    NO_ARCHIVE=true;  shift ;;
            --help)          show_help; exit 0 ;;
            *) die "Unknown argument: $1, use --help for usage" ;;
        esac
    done

    if [[ -n "$ROUTER_TLS_NAME" ]]; then
        REQUEST_HOST="$ROUTER_TLS_NAME"
    else
        REQUEST_HOST="$ROUTER_HOST"
    fi
    BASE_URL="${ROUTER_SCHEME}://${REQUEST_HOST}:${ROUTER_PORT}/v0/management"
    BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"

    [[ -n "$RESTORE_FILE" && "$FORCE_FULL" == "true" ]] \
        && die "--restore cannot be used together with --full"
    [[ "$RESTART_SERVICE" == "true" && -n "$RESTORE_FILE" ]] \
        && die "--restart cannot be used together with --restore"
    [[ "$RESTART_SERVICE" == "true" && "$FORCE_FULL" == "true" ]] \
        && die "--restart cannot be used together with --full"
}

# ====================== 主流程 ==========================

main() {
    parse_args "$@"

    log "INFO" "================================================"
    log "INFO" " CLIProxyAPI backup script"
    log "INFO" " Target: ${BASE_URL}"
    if [[ -n "$ROUTER_TLS_NAME" ]]; then
        log "INFO" " Connect: ${ROUTER_HOST}:${ROUTER_PORT} (TLS name: ${ROUTER_TLS_NAME})"
    fi
    log "INFO" " Backup: ${BACKUP_PATH}"
    log "INFO" "================================================"

    check_deps
    check_config

    if [[ "$RESTART_SERVICE" == "true" ]]; then
        do_restart_with_backup_restore "${SERVICE_UNIT}"
        return 0
    fi

    if [[ -n "$RESTORE_FILE" ]]; then
        do_restore "$RESTORE_FILE"
        return 0
    fi

    mkdir -p "${BACKUP_DIR}" || die "failed to create backup dir: ${BACKUP_DIR}"

    if [[ "$FORCE_FULL" == "true" ]]; then
        log "INFO" "Force full backup mode"
        [[ "$NO_ARCHIVE" == "false" ]] && archive_backup
        do_full_backup
    elif [[ ! -f "${BACKUP_PATH}" ]]; then
        log "INFO" "Backup file missing, running full backup"
        do_full_backup
    else
        log "INFO" "Backup file exists, running incremental backup"
        [[ "$NO_ARCHIVE" == "false" ]] && archive_backup
        do_incremental_backup
    fi
}

main "$@"
