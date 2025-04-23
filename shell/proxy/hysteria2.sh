#!/bin/bash

install_hysteria() {
    bash <(curl -fsSL https://get.hy2.sh/)
    echo "Hysteria安装完成！"
}

generate_config() {
    # 获取端口号，默认443
    read -p "请输入端口号（默认443）:" port
    port=${port:-443}

    # 获取域名，不能为空并校验格式
    read -p "请输入域名:" domain
    until [[ -n "$domain" && "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
        read -p "域名不能为空且需符合格式（如example.com），请重新输入:" domain
    done

    # 获取CA邮箱，不能为空
    read -p "请输入CA邮箱:" email
    until [[ -n "$email" ]]; do
        read -p "CA邮箱不能为空，请重新输入:" email
    done

    # 获取Cloudflare API Token，不能为空
    read -p "请输入Cloudflare API Token:" cloudflare_api_token
    until [[ -n "$cloudflare_api_token" ]]; do
        read -p "Cloudflare API Token不能为空，请重新输入:" cloudflare_api_token
    done

    # 获取密码，为空则随机生成
    read -p "请输入密码（为空则随机生成16位）:" password
    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 12)
    fi

    # 生成YML文件
    cat > /etc/hysteria/config.yaml <<EOF
listen: :$port

acme:
  domains:
    - $domain
  email: $email
  ca: zerossl
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: $cloudflare_api_token

auth:
  type: password
  password: $password

masquerade:
  type: proxy
  proxy:
    url: https://leetcode.cn/
    rewriteHost: true
EOF

    echo "\n\e[1;42;97m配置文件/etc/hysteria/config.yaml生成成功！\e[0m"
}

start_hysteria_service() {
    systemctl start hysteria-server.service
    systemctl enable hysteria-server.service
    echo "\n\e[1;42;97mHysteria服务已启动并设置为开机自启！\e[0m"
}

output_summary() {
    service_status_cmd="systemctl status hysteria-server.service"
    service_restart_cmd="systemctl restart hysteria-server.service"
    service_logs_cmd="journalctl --no-pager -e -u hysteria-server.service"
    echo -e "\n=================== 完成 ==================="
    echo -e "生成的密码: \e[1;42;97m$password\e[0m"
    echo -e "\n服务状态查看: \e[1;34m$service_status_cmd\e[0m"
    echo -e "服务重启命令: \e[1;34m$service_restart_cmd\e[0m"
    echo -e "查看服务日志: \e[1;34m$service_logs_cmd\e[0m"
    echo -e "==========================================="
}

# 执行流程
install_hysteria
generate_config
start_hysteria_service
output_summary
