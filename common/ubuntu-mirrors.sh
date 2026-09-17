#!/bin/bash
# =============================================================================
# Ubuntu apt 源配置与带镜像回退的包安装(函数库,被 source)
#
# 使用方:
#   deb/rehearsal.sh   彩排容器运行期安装发行版原生 openssh
#
# 设计对齐 common/rocky-mirrors.sh 的实测教训:镜像偶发 403/限流/慢速 →
# 单源 + 每镜像内部重试 + 逐级换源。APT_MIRROR 非空时优先尝试
# (如 mirrors.tuna.tsinghua.edu.cn)。
# =============================================================================

_ubuntu_rewrite_sources() {
  # 将 sources.list 的软件源主机替换为 $1(保留 http 方案与 /ubuntu 路径)。
  # 首次调用备份原始 sources.list,之后每次从备份重生成,保证换源可叠加
  # (sed 只认 archive/security.ubuntu.com,直接改写会丢原始主机)。
  local host="$1"
  [ -f /etc/apt/sources.list.orig ] || \
    cp -a /etc/apt/sources.list /etc/apt/sources.list.orig
  sed -e "s|archive\.ubuntu\.com|$host|g" \
      -e "s|security\.ubuntu\.com|$host|g" \
      /etc/apt/sources.list.orig > /etc/apt/sources.list
}

ubuntu_install() {
  # 用法: ubuntu_install pkg1 pkg2 ...
  # 逐镜像(用户指定 → 清华 → 阿里云 → 官方源)逐重试安装,全部失败才报错
  local -a hosts=()
  local host i ok=0
  [ -n "${APT_MIRROR:-}" ] && hosts+=("$APT_MIRROR")
  hosts+=(mirrors.tuna.tsinghua.edu.cn mirrors.aliyun.com archive.ubuntu.com)
  for host in "${hosts[@]}"; do
    _ubuntu_rewrite_sources "$host"
    echo "== apt 尝试镜像: $host" >&2
    for i in 1 2 3; do
      if apt-get update && apt-get install -y "$@"; then ok=1; break; fi
      echo "apt 重试($i/3): $host" >&2
      sleep 5
    done
    [ "$ok" -eq 1 ] && break
  done
  [ "$ok" -eq 1 ] || { echo "FATAL: 全部镜像安装失败: $*" >&2; return 1; }
}
