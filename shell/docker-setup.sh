#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本 (使用 sudo)"
  exit 1
fi

# 更新系统包索引
apt update

# 安装必要的依赖
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

# 添加 Docker 官方 GPG 密钥
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# 添加 Docker 软件源
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 再次更新包索引并安装 Docker
apt update
apt install -y docker-ce docker-ce-cli containerd.io

# 启动并启用 Docker 服务
systemctl start docker
systemctl enable docker

# 验证 Docker 安装
docker_version=$(docker --version)
if [ $? -eq 0 ]; then
  echo "Docker 安装成功：$docker_version"
else
  echo "Docker 安装失败，请检查错误信息"
  exit 1
fi

# 添加当前用户到 docker 组（允许非 root 用户运行 Docker）
if [ -n "$SUDO_USER" ]; then
  usermod -aG docker "$SUDO_USER"
  echo "已将用户 $SUDO_USER 添加到 docker 组，请重新登录以应用更改"
fi

# 测试 Docker 是否正常工作
echo "正在运行测试容器..."
docker run --name hello-world-test hello-world

# 删除测试容器
echo "正在删除测试容器..."
docker rm hello-world-test

# 删除 hello-world 镜像
echo "正在删除 hello-world 镜像..."
docker rmi hello-world

echo "Docker 安装和配置完成"