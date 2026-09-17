#!/bin/bash
# =============================================================================
# OpenSSH deb 彩排脚本:在与构建基底同族的全新容器上完整演练
# 目标机上的安装/升级路径。由顶层 build.sh 在原生基底容器中执行:
#
#   docker run <BASE_IMAGE> \
#     -v <repo>/deb:/opt/build/deb:ro -v <repo>/common:/opt/build/common:ro \
#     -v <repo>/versions:/versions:ro -v <out>:/debs:ro \
#     -e OPENSSH_VERSION=... [-e DEB_REVISION=...(顶层 --revision 注入)] \
#     bash /opt/build/deb/rehearsal.sh
#
# 演练内容:
#   1. 安装发行版原生 openssh-server / openssh-client(模拟现网状态),
#      并在 sshd_config 留下管理员自定义痕迹(演练 conffile 保留)
#   2. apt 本地事务升级到本地构建的三个包(--force-confold 保留系统配置)
#      —— 验证升级路径、维护脚本(preinst/postinst)、文件替换
#   3. 断言:版本、路径布局、privsep 用户/目录、主机密钥生成、
#      ssh-keysign setuid、conffile 保留
#   4. 端到端:UsePAM=yes 公钥登录、压缩、外部 sftp(/usr/lib/openssh)、
#      internal-sftp、scp
#   5. 升级后系统配置 sshd -t + SysV init 脚本 start/status/stop 演练
#   6. 已安装包状态:版本精确匹配、依赖清单无加密族
#
# 任何一步失败即非零退出,顶层 build.sh 不认可本次产物。
# =============================================================================
set -euo pipefail
export LANG=C LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../common/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../common/ubuntu-mirrors.sh"

: "${OPENSSH_VERSION:?需要 OPENSSH_VERSION 指定 versions/ 下的版本}"
DEB_REVISION_OVERRIDE="${DEB_REVISION:-}"   # 顶层 --revision 注入,优先于 env 文件
load_version_env "$OPENSSH_VERSION" "${VERSIONS_DIR:-/versions}"
[ -n "$DEB_REVISION_OVERRIDE" ] && DEB_REVISION="$DEB_REVISION_OVERRIDE"

VER="${DEB_EPOCH}:${OPENSSH_VER}-${DEB_REVISION}"
# focal 的 apt 2.0.11 对文件名含冒号(epoch)的本地 deb 会静默不动作,
# 产物文件名用 %3a 编码冒号(与 deb/build.sh 打包侧一致)
VER_FILE="${VER//:/%3a}"

# 版本比较:OpenSSH >= 9.8 才有 sshd-session,>= 9.9 才有 sshd-auth
ver_ge() { # ver_ge <major> <minor>
  # 注意:不能写成单条 local num=.. m="${num..}" —— 同条 local 的所有词先展开
  # 后赋值,引用前面的变量会因未绑定而报错(set -u)
  local num m n
  num="${OPENSSH_VER%p*}"; m="${num%%.*}"; n="${num#*.}"
  [ "$m" -gt "$1" ] || { [ "$m" -eq "$1" ] && [ "${n%%.*}" -ge "$2" ]; }
}
EXPECT_SSHD_SESSION=0; ver_ge 9 8 && EXPECT_SSHD_SESSION=1
EXPECT_SSHD_AUTH=0;    ver_ge 9 9 && EXPECT_SSHD_AUTH=1

log() { printf '\n== %s\n' "$*"; }
die() { echo "REHEARSAL FAIL: $*" >&2; exit 1; }

DEBS=/debs

# ------------------------------------------------ 1. 原生包(模拟现网状态)
log "1/6 安装发行版原生 openssh(模拟现网)"
ubuntu_install openssh-server openssh-client
dpkg-query -W -f='${Package} ${Version}\n' openssh-server openssh-client
# 留下"管理员自定义"的 /etc/ssh/sshd_config 环境特征:自定义标记 +
# Subsystem 显式指向发行版原生路径(focal 默认即此路径,幂等确保)。
# 升级必须原样保留该文件(--force-confold),新配置落在 .dpkg-dist
sed -i 's|^#\?Subsystem[[:space:]].*|Subsystem sftp /usr/lib/openssh/sftp-server|' \
  /etc/ssh/sshd_config || true
grep -q '^Subsystem sftp /usr/lib/openssh/sftp-server' /etc/ssh/sshd_config \
  || echo 'Subsystem sftp /usr/lib/openssh/sftp-server' >> /etc/ssh/sshd_config
echo '# rehearsal admin marker: 升级后必须保留' >> /etc/ssh/sshd_config

# ---------------------------------------------------------- 2. 升级到本构建
log "2/6 apt 本地事务升级到本地构建(${VER})"
apt-get install -y --allow-downgrades \
  -o Dpkg::Options::="--force-confold" \
  "$DEBS/openssh-client_${VER_FILE}_amd64.deb" \
  "$DEBS/openssh-sftp-server_${VER_FILE}_amd64.deb" \
  "$DEBS/openssh-server_${VER_FILE}_amd64.deb"
dpkg-query -W -f='${Package} ${Version}\n' \
  openssh-client openssh-sftp-server openssh-server

# ------------------------------------------------------------- 3. 静态断言
log "3/6 布局与依赖断言"
V_OUT=$(ssh -V 2>&1); echo "$V_OUT"
echo "$V_OUT" | grep -q "OpenSSH_${OPENSSH_VER}, OpenSSL ${OPENSSL_VER}" \
  || die "ssh -V 不符: $V_OUT"

for f in /usr/sbin/sshd /usr/lib/openssh/sftp-server /usr/bin/ssh /usr/bin/sftp \
         /usr/bin/scp /usr/bin/ssh-keygen /usr/lib/openssh/ssh-sk-helper; do
  [ -e "$f" ] || die "缺少 $f"
done
if [ "$EXPECT_SSHD_SESSION" -eq 1 ]; then
  [ -e /usr/lib/openssh/sshd-session ] || die "缺少 /usr/lib/openssh/sshd-session"
fi
if [ "$EXPECT_SSHD_AUTH" -eq 1 ]; then
  [ -e /usr/lib/openssh/sshd-auth ] || die "缺少 /usr/lib/openssh/sshd-auth"
fi
getent passwd sshd >/dev/null || die "sshd privsep 用户缺失"
[ -d /run/sshd ] || die "/run/sshd 特权分离目录缺失"
[ -u /usr/lib/openssh/ssh-keysign ] || die "ssh-keysign 无 setuid 位"
ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || die "维护脚本未生成主机密钥"
# focal 容器无 systemd:unit 落盘即可。官方镜像的 policy-rc.d 默认拒绝
# 容器内服务启动,postinst 的启停代码在 apt 事务中执行无错即可;
# init 脚本本身在第 5 步单独演练
[ -f /lib/systemd/system/ssh.service ] || die "ssh.service 缺失"
grep -q '^Type=simple' /lib/systemd/system/ssh.service || die "unit 非 Type=simple"

# conffile 保留断言:管理员自定义与现网 Subsystem 均应原样保留
grep -q 'rehearsal admin marker' /etc/ssh/sshd_config \
  || die "sshd_config 管理员自定义内容被升级覆盖"
grep -q '^Subsystem sftp /usr/lib/openssh/sftp-server' /etc/ssh/sshd_config \
  || die "升级后 sshd_config Subsystem 路径异常"
[ -f /etc/ssh/sshd_config.dpkg-dist ] \
  || echo "提示: dpkg 未落 .dpkg-dist(现网配置与包内一致,未触发保留询问)"

for b in /usr/sbin/sshd /usr/bin/ssh /usr/lib/openssh/sftp-server; do
  ldd "$b" | grep -qE 'libcrypto|libssl|libz\.|libfido2|libcbor|libedit|libtinfo' \
    && die "$b 动态依赖加密/压缩族: $(ldd "$b" | grep -E 'libcrypto|libz')"
done
echo "PASS: 静态内嵌与布局断言"

# --------------------------------------------------------------- 4. E2E 登录
log "4/6 端到端:UsePAM 公钥登录 / 压缩 / sftp(外部+内部)/ scp"
T=/tmp/rh; rm -rf "$T"; mkdir -p "$T"; cd "$T"
ssh-keygen -q -t ed25519 -N '' -f "$T/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$T/id"
cat "$T/id.pub" > "$T/authorized_keys"
chmod 600 "$T/authorized_keys"

cat > "$T/sshd_config" <<CFG
Port 2299
ListenAddress 127.0.0.1
HostKey $T/host_key
PidFile $T/sshd.pid
AuthorizedKeysFile $T/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
UsePAM yes
StrictModes no
Subsystem sftp /usr/lib/openssh/sftp-server
CFG
/usr/sbin/sshd -t -f "$T/sshd_config" || die "sshd -t 测试配置失败"
/usr/sbin/sshd -E "$T/sshd.log" -f "$T/sshd_config"
trap 'kill "$(cat "$T/sshd.pid")" 2>/dev/null || true' EXIT
sleep 1

OPTS="-p 2299 -i $T/id -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=$T/kh -o IdentitiesOnly=yes -o BatchMode=yes"

OUT=$(ssh $OPTS root@127.0.0.1 'echo LOGIN_OK && echo $((6*7))')
echo "$OUT" | grep -q LOGIN_OK || { cat "$T/sshd.log"; die "公钥登录失败"; }
echo "$OUT" | grep -q 42 || die "远端命令执行异常"

# grep 不用 -q:ssh -vv 输出量大,-q 匹配即退出会让 ssh 收到 SIGPIPE,
# 在 pipefail 下造成误判
ssh -vv -o Compression=yes $OPTS root@127.0.0.1 true 2>&1 \
  | grep 'compression: zlib@openssh.com' >/dev/null || die "zlib 压缩未生效"

# 外部 sftp(发行版原生 Subsystem 路径)
echo sftp_compress_test > "$T/f"
printf "put %s /tmp/rh.up\n" "$T/f" | sftp -b - -P 2299 -i "$T/id" -F /dev/null \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="$T/kh" root@127.0.0.1 \
  || { cat "$T/sshd.log"; die "外部 sftp(/usr/lib/openssh 路径)上传失败"; }
printf "get /tmp/rh.up %s/back\n" "$T" | sftp -b - -P 2299 -i "$T/id" -F /dev/null \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="$T/kh" root@127.0.0.1 \
  || die "外部 sftp 下载失败"
cmp "$T/f" "$T/back" || die "sftp 传输内容不一致"
echo "PASS: 外部 sftp(/usr/lib/openssh 路径)"

# scp
scp -P 2299 -i "$T/id" -F /dev/null -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile="$T/kh" "$T/f" root@127.0.0.1:/tmp/rh.scp \
  || die "scp 上传失败"
ssh $OPTS root@127.0.0.1 'cmp /tmp/rh.up /tmp/rh.scp && echo SCP_OK' | grep -q SCP_OK \
  || die "scp 与 sftp 内容不一致"

kill "$(cat "$T/sshd.pid")"; trap - EXIT

# internal-sftp 实例
sed 's|^Subsystem.*|Subsystem sftp internal-sftp|' "$T/sshd_config" > "$T/sshd_config2"
sed -i 's|Port 2299|Port 2300|' "$T/sshd_config2"
/usr/sbin/sshd -E "$T/sshd2.log" -f "$T/sshd_config2"
trap 'kill "$(cat "$T/sshd.pid")" 2>/dev/null || true' EXIT
sleep 1
OPTS2="-p 2300 -i $T/id -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=$T/kh2 -o IdentitiesOnly=yes -o BatchMode=yes"
printf "put %s /tmp/rh.up2\n" "$T/f" | sftp -b - -P 2300 -i "$T/id" -F /dev/null \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="$T/kh2" root@127.0.0.1 \
  || { cat "$T/sshd2.log"; die "internal-sftp 失败"; }
ssh $OPTS2 root@127.0.0.1 'cmp /tmp/rh.up /tmp/rh.up2 && echo INTERNAL_OK' | grep -q INTERNAL_OK \
  || die "internal-sftp 内容不一致"
kill "$(cat "$T/sshd.pid")"; trap - EXIT
echo "PASS: internal-sftp"

# ------------------------------------------- 5. 升级后的系统配置可用性
log "5/6 升级后系统配置与 SysV init 脚本校验"
# --force-confold 保留了现网(admin 自定义过)的配置,校验其对新 sshd 仍可用
/usr/sbin/sshd -t -f /etc/ssh/sshd_config || die "升级后系统 sshd_config 校验失败"
echo "PASS: sshd -t 系统配置"

# init 脚本 start/status/stop 全流程演练(无 systemd 系统的启动路径)。
# 经 /etc/default/ssh 指定非 22 端口,避免 host 网络模式下与宿主 sshd 冲突
echo 'SSHD_OPTS="-p 2280"' >> /etc/default/ssh
/etc/init.d/ssh start || die "init 脚本 start 失败"
sleep 1
( echo > /dev/tcp/127.0.0.1/2280 ) 2>/dev/null || die "init 启动的 sshd 未监听 2280"
/etc/init.d/ssh status >/dev/null 2>&1 || die "init 脚本 status 异常"
/etc/init.d/ssh stop >/dev/null 2>&1 || die "init 脚本 stop 失败"
( echo > /dev/tcp/127.0.0.1/2280 ) 2>/dev/null && die "init stop 后端口仍被监听"
echo "PASS: SysV init 脚本 start/status/stop"

# --------------------------------------------------------------- 6. 包状态
log "6/6 已安装包状态与依赖复核"
for p in openssh-client openssh-sftp-server openssh-server; do
  got=$(dpkg-query -W -f='${Version}' "$p")
  [ "$got" = "$VER" ] || die "$p 版本不符: $got(期望 $VER)"
done
DEPS=$(dpkg-query -W -f='${binary:Package} ${Depends}\n' \
  openssh-client openssh-sftp-server openssh-server | tee /tmp/req.txt)
echo "$DEPS" | grep -qE 'libssl|libcrypto|zlib1g|libfido2|libcbor|libedit[0-9]|libtinfo' \
  && die "依赖清单含加密/压缩族库"
echo "PASS: 版本与依赖清单干净"

log "彩排全部通过"
