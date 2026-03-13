#!/bin/bash
set -euo pipefail

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本 (使用 sudo)"
  exit 1
fi

# 检查系统发行版并确定 Docker 软件源
if [ ! -r /etc/os-release ]; then
  echo "无法读取 /etc/os-release，无法判断系统发行版"
  exit 1
fi

. /etc/os-release

# 兼容 Ubuntu / Debian 及其衍生发行版
if [ "${ID:-}" = "ubuntu" ] || echo "${ID_LIKE:-}" | grep -qw "ubuntu"; then
  docker_repo_distro="ubuntu"
elif [ "${ID:-}" = "debian" ] || echo "${ID_LIKE:-}" | grep -qw "debian"; then
  docker_repo_distro="debian"
else
  echo "当前系统为 ${ID:-unknown}，仅支持 Debian/Ubuntu 生态发行版"
  exit 1
fi

# 更新系统包索引
apt update

# 安装必要的依赖
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

if [ "$docker_repo_distro" = "ubuntu" ]; then
  if [ -n "${UBUNTU_CODENAME:-}" ]; then
    distro_codename="$UBUNTU_CODENAME"
  elif [ -n "${VERSION_CODENAME:-}" ]; then
    distro_codename="$VERSION_CODENAME"
  else
    distro_codename="$(lsb_release -cs)"
  fi
else
  if [ -n "${DEBIAN_CODENAME:-}" ]; then
    distro_codename="$DEBIAN_CODENAME"
  elif [ -n "${VERSION_CODENAME:-}" ]; then
    distro_codename="$VERSION_CODENAME"
  else
    distro_codename="$(lsb_release -cs)"
  fi
fi

docker_repo_url="https://download.docker.com/linux/$docker_repo_distro"

# 添加 Docker 官方 GPG 密钥
curl -fsSL "$docker_repo_url/gpg" | gpg --dearmor --yes -o /usr/share/keyrings/docker-archive-keyring.gpg

# 添加 Docker 软件源
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] $docker_repo_url $distro_codename stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 再次更新包索引并安装 Docker
apt update
apt install -y docker-ce docker-ce-cli containerd.io

# 启动并启用 Docker 服务
systemctl start docker
systemctl enable docker

# 验证 Docker 安装
docker_version=$(docker --version)
echo "Docker 安装成功：$docker_version"

# 添加当前用户到 docker 组（允许非 root 用户运行 Docker）
if [ -n "${SUDO_USER:-}" ]; then
  usermod -aG docker "$SUDO_USER"
  echo "已将用户 $SUDO_USER 添加到 docker 组，请重新登录以应用更改"
fi

# 测试 Docker 是否正常工作
echo "正在运行测试容器..."
docker run --rm hello-world

# 删除 hello-world 镜像
echo "正在删除 hello-world 镜像..."
docker rmi hello-world >/dev/null 2>&1 || true

echo "Docker 安装和配置完成"
