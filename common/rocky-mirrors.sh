#!/bin/bash
# =============================================================================
# Rocky Linux 8 dnf 源配置与带镜像回退的包安装(函数库,被 source)
#
# 使用方:
#   rpm/Dockerfile     构建工具链镜像时装构建依赖
#   rpm/rehearsal.sh   彩排容器运行期安装发行版原生 openssh
#
# 背景(实测教训):
#   - 多 baseurl 并列时 dnf 会选中低延迟但低速的源 → 必须单源 + 失败换源
#   - rocky extras 仓库部分镜像未同步(ustc 缺失会拖垮整个事务)→ 直接移除
#   - 镜像偶发 403/限流 → 每个镜像内部再重试
# DNF_MIRROR 非空时优先尝试该镜像(如 mirrors.aliyun.com/rockylinux)。
# =============================================================================

_rocky_rewrite_repos() {
  # 将 Rocky-*.repo 改写为指向 $1 的单 baseurl 形式
  local host="$1" f seg
  rm -f /etc/yum.repos.d/Rocky-Extras.repo
  for f in /etc/yum.repos.d/Rocky-*.repo; do
    case "$f" in
      *BaseOS*)    seg=BaseOS ;;
      *AppStream*) seg=AppStream ;;
      *) continue ;;
    esac
    sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
           -e "s|^#\?baseurl=.*|baseurl=https://$host/\$releasever/$seg/\$basearch/os/|" "$f"
  done
}

rocky_install() {
  # 用法: rocky_install pkg1 pkg2 ...
  # 逐镜像(用户指定 → ustc → 阿里云 → 官方)逐重试安装,全部失败才报错
  local -a hosts=()
  local host i ok=0
  [ -n "${DNF_MIRROR:-}" ] && hosts+=("$DNF_MIRROR")
  hosts+=(mirrors.ustc.edu.cn/rocky mirrors.aliyun.com/rockylinux dl.rockylinux.org/pub/rocky)
  for host in "${hosts[@]}"; do
    _rocky_rewrite_repos "$host"
    echo "== dnf 尝试镜像: $host" >&2
    for i in 1 2 3; do
      if dnf -y install "$@"; then ok=1; break; fi
      echo "dnf 重试($i/3): $host" >&2
      sleep 5
    done
    [ "$ok" -eq 1 ] && break
  done
  [ "$ok" -eq 1 ] || { echo "FATAL: 全部镜像安装失败: $*" >&2; return 1; }
  dnf clean all >/dev/null 2>&1 || true
}
