#!/usr/bin/env bash
# =============================================================================
# OpenSSH 构建产物一键安装工具(openssh-build)
#
# 用法:
#   scripts/install_openssh.sh <OpenSSH版本> [--dir <包目录>]
#
# 示例:
#   scripts/install_openssh.sh 10.6p1                              # 用项目 out/ 产物或脚本同目录的包
#   scripts/install_openssh.sh 10.6p1 --dir /mnt/usb/openssh-offline
#
# 参数:
#   <OpenSSH版本>   上游版本号(与 versions/*.env 命名一致,如 10.6p1)。
#                   包文件名须含该版本:deb 形如
#                     openssh-server_1%3a10.6p1-1local1_amd64.deb
#                   rpm 形如
#                     openssh-10.6p1-1.ky10.x86_64.rpm
#                   (deb revision / rpm release 任意)
#   --dir <目录>    到指定目录寻找三包;缺省依次查找:
#                     1) 脚本所在目录(离线场景:三包与脚本拷在一起)
#                     2) 项目 out/ 产物树 out/{deb,rpm}/<版本>-*,
#                        存在多个 revision 时取最高
#
# 行为:
#   - 自动识别设备:deb 系(apt-get + /etc/debian_version)装 deb 包,
#     rpm 系(rpm)装 rpm 包;二者皆非时报错退出;
#   - 版本门禁:设备已装 openssh 低于要安装的版本才安装;已装同版本或
#     更高版本时打印提醒并跳过(退出码 0);
#   - 非交互:deb 设 DEBIAN_FRONTEND=noninteractive,全程无 tty 询问;
#   - 安装通道:deb 系优先 apt(缺依赖能自动补、记账完整),confold/
#     overwrite 透传 dpkg;apt-get check 发现系统已有坏依赖时改走
#     dpkg -i 直装绕开 apt 的全系统体检;apt 失败不重试(后端同为 dpkg);
#   - 配置保留:deb 用 --force-confold,现网已修改的 /etc/ssh/* 原样保留,
#     包内新配置落 .dpkg-dist;rpm 靠 spec 的 %config(noreplace),
#     新配置落 .rpmnew;
#   - 装后自动重启 sshd:deb 系单元名为 ssh.service,rpm 系为 sshd.service;
#     无 systemd 运行环境(容器/chroot)时提示跳过;
#   - 三包互相锁版本,同一事务安装;非 root 自动加 sudo。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"
die() { echo "错误: $*" >&2; exit 1; }
usage() { sed -n '2,/^===/p' "$0" | sed 's/^# \{0,1\}//; /^===/d'; }

# ---------------------------------------------------------------- 参数解析
VER=""
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dir)     [ -n "${2:-}" ] || die "--dir 需要目录参数"; DIR="$2"; shift ;;
    -*)        die "未知参数: $1(见 --help)" ;;
    *)         [ -z "$VER" ] || die "版本号只能提供一个(已收到 $VER 与 $1)"; VER="$1" ;;
  esac
  shift
done
[ -n "$VER" ] || { usage; die "必须提供 OpenSSH 版本号,例如: $0 10.6p1"; }

# ---------------------------------------------------------------- 设备识别
PKG_FAMILY=""
if command -v apt-get >/dev/null 2>&1 && [ -e /etc/debian_version ]; then
  PKG_FAMILY="deb"
elif command -v rpm >/dev/null 2>&1; then
  PKG_FAMILY="rpm"
else
  die "未能识别设备类型(既无 apt-get//etc/debian_version,也无 rpm)"
fi
echo "设备类型: ${PKG_FAMILY} 系"

# ---------------------------------------------------------------- 包目录定位
# 缺省顺序:脚本所在目录 → 项目 out/<设备格式>/<版本>-<revision>(取 revision 最高)
find_pkg_dir() {
  local ext="rpm"
  if [ "$PKG_FAMILY" = deb ]; then ext="deb"; fi
  shopt -s nullglob
  local probe=( "$SCRIPT_DIR"/openssh-*."$ext" )
  shopt -u nullglob
  if [ "${#probe[@]}" -gt 0 ]; then
    echo "$SCRIPT_DIR"
    return 0
  fi
  local out_root="$SCRIPT_DIR/../out"
  local -a cands=()
  shopt -s nullglob
  local d
  for d in "$out_root/$PKG_FAMILY/$VER"-*; do
    if [ -d "$d" ]; then cands+=("$d"); fi
  done
  shopt -u nullglob
  if [ "${#cands[@]}" -eq 0 ]; then
    return 1
  fi
  printf '%s\n' "${cands[@]}" | sort -V | tail -n 1
}
if [ -z "$DIR" ]; then
  DIR="$(find_pkg_dir)" || \
    die "未找到版本 $VER 的安装包(查找过脚本目录 $SCRIPT_DIR 与项目 $SCRIPT_DIR/../out/$PKG_FAMILY/$VER-*)。可用 --dir 指定包含三包的目录"
else
  [ -d "$DIR" ] || die "--dir 目录不存在: $DIR"
fi
DIR="$(cd "$DIR" && pwd)"
echo "包目录: $DIR"

# -------------------------------------------------------------- deb 系安装
install_deb() {
  local -a debs=() server_debs=()
  local f v
  shopt -s nullglob
  for f in "$DIR"/openssh-*.deb; do
    v="$(dpkg-deb -f "$f" Version)"
    v="${v#*:}"                    # 去掉 epoch(如 1:),按上游版本匹配
    if [ "$v" = "$VER" ] || [[ "$v" == "$VER"-* ]]; then
      debs+=("$f")
      if [[ "$f" == */openssh-server_*.deb ]]; then server_debs+=("$f"); fi
    fi
  done
  shopt -u nullglob
  [ "${#debs[@]}" -ge 3 ] || die "$DIR 下未找到版本 $VER 的三个 .deb(需 client/server/sftp-server)"
  [ "${#server_debs[@]}" -eq 1 ] || die "$DIR 下 openssh-server 的 $VER 包应恰好一个,实得 ${#server_debs[@]}"
  local pkg_ver installed
  pkg_ver="$(dpkg-deb -f "${server_debs[0]}" Version)"
  echo "新包版本: openssh-server $pkg_ver"

  # 版本门禁:仅当 已装版本 < 新包版本 才安装
  installed="$(dpkg-query -W -f='${Version}' openssh-server 2>/dev/null || true)"
  if [ -n "$installed" ]; then
    if dpkg --compare-versions "$pkg_ver" gt "$installed"; then
      echo "当前已安装: openssh-server $installed(可升级)"
    else
      echo "提醒: 当前已安装 openssh-server $installed,不低于新包 $pkg_ver,跳过安装。"
      exit 0
    fi
  else
    echo "当前未安装 openssh-server,将执行全新安装"
  fi

  # 安装通道:系统依赖健康走 apt;apt 因全系统体检拒装时用 dpkg 直装绕开。
  # 两通道都带 --force-overwrite,用于接管旧布局包(带 openssh-common 等)
  # 占用的文件;apt 安装失败不回退重试——apt 后端就是 dpkg,同样的包换
  # dpkg 再跑不会有不同结果,只会留下半装状态,失败就带完整报错退出
  if $SUDO apt-get check >/dev/null 2>&1; then
    $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
      apt-get install -y --allow-downgrades \
      -o Dpkg::Options::="--force-confold" \
      -o Dpkg::Options::="--force-overwrite" \
      "${debs[@]}"
  else
    echo "提示: 系统存在未满足的依赖(apt-get check 未通过),跳过 apt 直接 dpkg 安装"
    $SUDO env DEBIAN_FRONTEND=noninteractive \
      dpkg -i --force-confold --force-overwrite "${debs[@]}"
  fi
  echo "安装完成:"
  dpkg-query -W -f='  ${Package} ${Version}\n' openssh-client openssh-sftp-server openssh-server
}

# -------------------------------------------------------------- rpm 系安装
install_rpm() {
  local -a rpms=() base_rpms=()
  local f ver name
  shopt -s nullglob
  for f in "$DIR"/openssh-*.rpm; do
    ver="$(rpm -qp --qf '%{VERSION}' "$f")"
    if [ "$ver" = "$VER" ]; then
      rpms+=("$f")
      name="$(rpm -qp --qf '%{NAME}' "$f")"
      if [ "$name" = openssh ]; then base_rpms+=("$f"); fi
    fi
  done
  shopt -u nullglob
  [ "${#rpms[@]}" -ge 3 ] || die "$DIR 下未找到版本 $VER 的三个 .rpm"
  [ "${#base_rpms[@]}" -eq 1 ] || die "$DIR 下主包 openssh-$VER 应恰好一个,实得 ${#base_rpms[@]}"
  echo "新包版本: $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "${base_rpms[0]}")"

  # 版本门禁:rpm -U --test 预检(rpm 自身比较语义)。
  # 报 already installed = 已装同版/更新版 → 提醒跳过;其他失败 → 依赖/冲突问题,报错退出
  if rpm -q openssh >/dev/null 2>&1; then
    echo "当前已安装:"
    rpm -q openssh openssh-clients openssh-server || true
    local err
    if err="$(LC_ALL=C $SUDO rpm -U --test "${rpms[@]}" 2>&1)"; then
      echo "预检通过(相对当前构成升级),开始安装"
    elif grep -q 'already installed' <<<"$err"; then
      echo "提醒: 当前已安装同版本或更新版本的 openssh,跳过安装。"
      exit 0
    else
      { echo "rpm 预检失败(依赖或冲突问题):"; printf '%s\n' "$err"; } >&2
      exit 1
    fi
  else
    echo "当前未安装 openssh,将执行全新安装"
  fi

  $SUDO rpm -Uvh "${rpms[@]}"
  echo "安装完成:"
  rpm -q openssh openssh-clients openssh-server
}

# ---------------------------------------------------- 装后重启 sshd 服务
# deb 系单元名为 ssh.service,rpm 系为 sshd.service,按设备类型优先、另一名兜底;
# 无 systemd 运行环境(容器/chroot)时跳过;重启失败视为安装未完成,退出非 0
restart_sshd() {
  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo "提示: 当前无 systemd 运行环境(容器/chroot),跳过重启;新版本将在服务下次启动时生效"
    return 0
  fi
  local svc="" cand
  for cand in ssh sshd; do
    if systemctl list-unit-files "$cand.service" 2>/dev/null | grep -q "^$cand\.service"; then
      svc="$cand"
      break
    fi
  done
  if [ -z "$svc" ]; then
    echo "提示: 未找到 ssh.service / sshd.service 单元,跳过重启(服务可能由其他方式管理)"
    return 0
  fi
  echo "重启服务: ${svc}.service"
  if ! $SUDO systemctl restart "$svc.service"; then
    echo "错误: ${svc}.service 重启失败,请手工检查: systemctl status ${svc}" >&2
    exit 1
  fi
  echo "已重启: ${svc}.service(当前状态: $(systemctl is-active "$svc.service" 2>/dev/null || echo unknown))"
}

# ---------------------------------------------------------------- 执行与自检
if [ "$PKG_FAMILY" = deb ]; then
  install_deb
else
  install_rpm
fi
restart_sshd
ssh -V
echo "提示: 现网 /etc/ssh/* 配置未改动;包内新配置(如有)落为 .dpkg-dist/.rpmnew,可对比后手工合并。"
