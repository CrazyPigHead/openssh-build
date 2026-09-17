#!/bin/bash
# =============================================================================
# OpenSSH RPM 彩排脚本(stage2):在与构建基底同族的全新容器上完整演练
# 目标机上的安装/升级路径。由顶层 build.sh 在原生基底容器中执行:
#
#   docker run <BASE_IMAGE> \
#     -v <repo>/rpm:/opt/build/rpm:ro -v <repo>/common:/opt/build/common:ro \
#     -v <repo>/versions:/versions:ro -v <out>:/rpms:ro \
#     -e OPENSSH_VERSION=... [-e RPM_RELEASE=...(顶层 --release 注入)] \
#     bash /opt/build/rpm/rehearsal.sh
#
# 演练内容:
#   1. 安装发行版原生 openssh-server / openssh-clients(模拟现网状态)
#   2. rpm -Uvh 升级到本地构建的三个包 —— 验证升级路径、脚本、文件替换
#   3. 断言:版本、路径布局、兼容软链、privsep 用户/目录、主机密钥生成
#   4. 端到端:UsePAM=yes 公钥登录、压缩、外部 sftp(兼容路径)、
#      internal-sftp、scp、升级后配置 sshd -t
#
# 任何一步失败即非零退出,顶层 build.sh 不认可本次产物。
# =============================================================================
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../common/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../common/rocky-mirrors.sh"

: "${OPENSSH_VERSION:?需要 OPENSSH_VERSION 指定 versions/ 下的版本}"
RPM_RELEASE_OVERRIDE="${RPM_RELEASE:-}"   # 顶层 --release 注入,优先于 env 文件
load_version_env "$OPENSSH_VERSION" "${VERSIONS_DIR:-/versions}"
[ -n "$RPM_RELEASE_OVERRIDE" ] && RPM_RELEASE="$RPM_RELEASE_OVERRIDE"

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

RPMS=/rpms

# ------------------------------------------------ 1. 原生包(模拟现网状态)
log "1/6 安装发行版原生 openssh(模拟现网)"
rocky_install openssh-server openssh-clients diffutils
rpm -q openssh-clients openssh-server
# 留下"管理员自定义"的 /etc/ssh/sshd_config 与 sshd_config 悬空 Subsystem
# 环境特征,模拟 Kylin 现机:Subsystem 指向 /usr/libexec/openssh/sftp-server
sed -i 's|^Subsystem[[:space:]].*|Subsystem sftp /usr/libexec/openssh/sftp-server|' \
  /etc/ssh/sshd_config || true
grep -q '^Subsystem sftp /usr/libexec/openssh/sftp-server' /etc/ssh/sshd_config \
  || echo 'Subsystem sftp /usr/libexec/openssh/sftp-server' >> /etc/ssh/sshd_config

# ---------------------------------------------------------- 2. 升级到本构建
log "2/6 rpm -Uvh 升级到本地构建(${OPENSSH_VER}-${RPM_RELEASE})"
rpm -Uvh "$RPMS"/openssh-"${OPENSSH_VER}"-"${RPM_RELEASE}".*.rpm \
            "$RPMS"/openssh-clients-"${OPENSSH_VER}"-"${RPM_RELEASE}".*.rpm \
            "$RPMS"/openssh-server-"${OPENSSH_VER}"-"${RPM_RELEASE}".*.rpm
rpm -q openssh openssh-clients openssh-server

# ------------------------------------------------------------- 3. 静态断言
log "3/6 布局与依赖断言"
V_OUT=$(ssh -V 2>&1); echo "$V_OUT"
echo "$V_OUT" | grep -q "OpenSSH_${OPENSSH_VER}, OpenSSL ${OPENSSL_VER}" \
  || die "ssh -V 不符: $V_OUT"

for f in /usr/sbin/sshd /usr/libexec/sftp-server /usr/bin/ssh /usr/bin/sftp \
         /usr/bin/scp /usr/bin/ssh-keygen /usr/libexec/ssh-sk-helper; do
  [ -e "$f" ] || die "缺少 $f"
done
if [ "$EXPECT_SSHD_SESSION" -eq 1 ]; then
  [ -e /usr/libexec/sshd-session ] || die "缺少 /usr/libexec/sshd-session"
fi
if [ "$EXPECT_SSHD_AUTH" -eq 1 ]; then
  [ -e /usr/libexec/sshd-auth ] || die "缺少 /usr/libexec/sshd-auth"
fi
[ -L /usr/libexec/openssh/sftp-server ] || die "兼容软链缺失"
readlink /usr/libexec/openssh/sftp-server | grep -q 'sftp-server' || die "软链目标异常"
getent passwd sshd >/dev/null || die "sshd privsep 用户缺失"
[ -d /var/empty/sshd ] || die "/var/empty/sshd 缺失"
ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || die "rpm 脚本未生成主机密钥"
[ -f /usr/lib/systemd/system/sshd.service ] || die "sshd.service 缺失"
grep -q '^Type=simple' /usr/lib/systemd/system/sshd.service || die "unit 非 Type=simple"

for b in /usr/sbin/sshd /usr/bin/ssh /usr/libexec/sftp-server; do
  ldd "$b" | grep -qE 'libcrypto|libssl|libz\.|libfido2|libcbor|libedit|libtinfo' \
    && die "$b 动态依赖加密/压缩族: $(ldd "$b" | grep -E 'libcrypto|libz')"
done
echo "PASS: 静态内嵌与布局断言"

# --------------------------------------------------------------- 4. E2E 登录
log "4/6 端到端:UsePAM 公钥登录 / 压缩 / sftp(外部+兼容路径)/ internal / scp"
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
Subsystem sftp /usr/libexec/openssh/sftp-server
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

# 外部 sftp(经兼容软链路径)
echo sftp_compress_test > "$T/f"
printf "put %s /tmp/rh.up\n" "$T/f" | sftp -b - -P 2299 -i "$T/id" -F /dev/null \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="$T/kh" root@127.0.0.1 \
  || { cat "$T/sshd.log"; die "外部 sftp(兼容路径)上传失败"; }
printf "get /tmp/rh.up %s/back\n" "$T" | sftp -b - -P 2299 -i "$T/id" -F /dev/null \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="$T/kh" root@127.0.0.1 \
  || die "外部 sftp 下载失败"
cmp "$T/f" "$T/back" || die "sftp 传输内容不一致"
echo "PASS: 外部 sftp(/usr/libexec/openssh 兼容路径)"

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
log "5/6 升级后 /etc/ssh/sshd_config 校验"
# admin 未改过发行版原生配置时升级即替换为本包版本;若保留 admin 版
# (现机场景)亦兼容:两版均指向可用路径。这里校验当前生效文件。
/usr/sbin/sshd -t -f /etc/ssh/sshd_config || die "升级后系统 sshd_config 校验失败"
echo "PASS: sshd -t 系统配置"

# --------------------------------------------------------------- 6. 依赖清单
log "6/6 已安装包依赖复核"
rpm -q --requires openssh-server openssh-clients openssh | tee /tmp/req.txt
if grep -qE 'libcrypto|libssl|libz\.so|libfido2|libcbor|libedit' /tmp/req.txt; then
  die "依赖清单含加密/压缩族库"
fi
echo "PASS: 依赖清单干净"

log "彩排全部通过"
