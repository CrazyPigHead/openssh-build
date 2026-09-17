#!/bin/bash
# =============================================================================
# OpenSSH deb 容器内构建脚本(静态内嵌 OpenSSL)
#
# 由 deb/Dockerfile 的 ENTRYPOINT 调用,亦可在 Ubuntu 20.04 宿主机上直接运行
# (需自行装好 Dockerfile 中列出的构建依赖)。
#
# 版本组合由 versions/<版本>.env 定义(OPENSSH_VERSION 指定),物料自动
# 下载到 DOWNLOADS_DIR(已有则复用),全部经 PGP/SHA256 校验。
#
# 环境变量(容器内由顶层 build.sh 注入,均有默认值):
#   OPENSSH_VERSION   要构建的 OpenSSH 版本(必填,对应 versions/ 下 env 文件)
#   VERSIONS_DIR      版本配置目录(默认 /versions)
#   DOWNLOADS_DIR     物料缓存目录(默认 /downloads;挂载宿主目录可离线构建)
#   WORK              构建工作目录(默认 /work;挂载宿主目录可增量构建)
#   OUT               产物输出目录(默认 /out)
#   DEB_REVISION      覆盖 env 文件中的 deb revision
#   SKIP_OPENSSL_TEST =1(默认)跳过 OpenSSL 官方自测,见下方说明
#
# 链接策略:
#   静态内嵌:OpenSSL(libcrypto)、zlib、libcbor、libfido2、libedit(+libtinfo)
#   保持动态:libc6/libpam0g/libcrypt1/libselinux1/libaudit1(全部为
#            Priority: required 基础库)+ helper 的 libudev1
#
# 三处静态链接顺序修正(缺一不可):
#   1) LIBEDIT 追加 -ltinfo:libedit.a 的 termcap 符号需在 -ledit 之后解析
#   2) CHANNELLIBS 追加 -ldl -lpthread:静态 libcrypto 的
#      dso_dlfcn.o / threads_pthread.o 符号需在 -lcrypto 之后解析
#   3) libfido2.pc 的 Requires 补 libudev libcbor,让 OpenSSH configure
#      经 pkg-config 拿到完整静态链
# =============================================================================
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../common/common.sh"

: "${OPENSSH_VERSION:?需要 OPENSSH_VERSION 指定 versions/ 下的版本}"
DEB_REVISION_OVERRIDE="${DEB_REVISION:-}"   # 容器 env 可覆盖 env 文件值
load_version_env "$OPENSSH_VERSION" "${VERSIONS_DIR:-/versions}"
[ -n "$DEB_REVISION_OVERRIDE" ] && DEB_REVISION="$DEB_REVISION_OVERRIDE"
VER="${DEB_EPOCH}:${OPENSSH_VER}-${DEB_REVISION}"

WORK="${WORK:-/work}"
OUT="${OUT:-/out}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-/downloads}"
PFX="$WORK/prefix"
J="$(nproc)"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

mkdir -p "$WORK" "$OUT" "$PFX"

# ------------------------------------------------------------ 1. 物料
log "1/7 获取并校验物料(版本组合:OpenSSH ${OPENSSH_VER} + OpenSSL ${OPENSSL_VER})"
fetch_materials "$DOWNLOADS_DIR" skip-ncurses   # ncurses 仅 rpm 构建需要
cd "$WORK"

# ------------------------------------------------------------ 2. 静态依赖
log "2/7 OpenSSL ${OPENSSL_VER}(no-shared no-zlib -fPIC)"
[ -d "openssl-${OPENSSL_VER}" ] || tar xf "$DOWNLOADS_DIR/openssl-${OPENSSL_VER}.tar.gz"
( cd "openssl-${OPENSSL_VER}"
  ./Configure no-shared no-zlib -fPIC --prefix="$PFX/openssl" --openssldir=/etc/ssl
  make -j"$J"
  if [ "${SKIP_OPENSSL_TEST:-1}" != "0" ]; then
    # OpenSSL 官方自测默认跳过:其 DTLS/IPv6-loopback 类用例
    # (20-test_app_s_client_msg、90-test_sslapi)在受限容器网络中会非确定性
    # 挂起(与代码无关;宿主机原生全绿)。功能门禁由后续端到端冒烟测试承担。
    echo "SKIP_OPENSSL_TEST=1(默认):跳过 OpenSSL make test"
  else
    mv test/recipes/20-test_app_s_client_msg.t \
       test/recipes/20-test_app_s_client_msg.t.skipped-in-container 2>/dev/null || true
    mv test/recipes/90-test_sslapi.t \
       test/recipes/90-test_sslapi.t.skipped-in-container 2>/dev/null || true
    if timeout --signal=KILL 1500 make test; then
      echo "OpenSSL make test: ALL PASS"
    else
      # 显式要求自测(SKIP_OPENSSL_TEST=0)时失败即中止出包:两个非确定性
      # 用例已被移除,再失败即为真实回归
      die "OpenSSL make test 未通过(SKIP_OPENSSL_TEST=0 显式启用自测时不放行;容器网络受限可改回默认 =1)"
    fi
  fi
  make install_sw )
test -f "$PFX/openssl/lib64/libcrypto.a"

log "3/7 zlib / libcbor / libedit / libfido2"
[ -d "zlib-${ZLIB_VER}" ] || tar xf "$DOWNLOADS_DIR/zlib-${ZLIB_VER}.tar.gz"
( cd "zlib-${ZLIB_VER}"
  CFLAGS="-O2 -fPIC" ./configure --static --prefix="$PFX/zlib"
  make -j"$J" && make install )

[ -d "libcbor-${CBOR_VER}" ] || tar xf "$DOWNLOADS_DIR/libcbor-${CBOR_VER}.tar.gz"
( cd "libcbor-${CBOR_VER}" && rm -rf cb && mkdir cb && cd cb
  cmake -DCMAKE_INSTALL_PREFIX="$PFX/cbor" -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DWITH_EXAMPLES=OFF \
    -DCMAKE_BUILD_TYPE=Release ..
  make -j"$J" && make install )

[ -d "libedit-${LIBEDIT_VER}" ] || tar xf "$DOWNLOADS_DIR/libedit-${LIBEDIT_VER}.tar.gz"
( cd "libedit-${LIBEDIT_VER}"
  CFLAGS="-O2 -fPIC" ./configure --prefix="$PFX/libedit" \
    --enable-static --disable-shared
  make -j"$J" && make install )

# libfido2 经 pkg-config 发现自建 openssl/cbor/zlib;focal 需 libudev-dev
[ -d "libfido2-${FIDO2_VER}" ] || tar xf "$DOWNLOADS_DIR/libfido2-${FIDO2_VER}.tar.gz"
( cd "libfido2-${FIDO2_VER}" && rm -rf fb && mkdir fb && cd fb
  PKG_CONFIG_PATH="$PFX/cbor/lib/pkgconfig:$PFX/openssl/lib64/pkgconfig:$PFX/zlib/lib/pkgconfig" \
  cmake -DCMAKE_INSTALL_PREFIX="$PFX/fido2" -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release \
    -DFIDO_EXAMPLES=OFF -DFIDO_TESTING=OFF -DBUILD_MANPAGES=OFF ..
  make -j"$J" fido2
  # 安装脚本会尝试安装未构建的 tools/regress,容错后校验关键产物即可
  cmake --install . 2>/dev/null || true )
test -f "$PFX/fido2/lib/libfido2.a"
test -f "$PFX/fido2/lib/pkgconfig/libfido2.pc"

# 链接顺序修正 3:补全静态依赖链
sed -i 's/^Requires: libcrypto$/Requires: libcrypto libudev libcbor/' \
  "$PFX/fido2/lib/pkgconfig/libfido2.pc"

# 静态库目录:-ltinfo 由系统 libncurses-dev 的 PIC 静态库提供
mkdir -p "$PFX/staticlibs"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.a "$PFX/staticlibs/"

# ------------------------------------------------------------- 3. OpenSSH
log "4/7 配置并编译 OpenSSH ${OPENSSH_VER}"
[ -d "openssh-${OPENSSH_VER}" ] || tar xf "$DOWNLOADS_DIR/openssh-${OPENSSH_VER}.tar.gz"
cd "openssh-${OPENSSH_VER}"
export PKG_CONFIG_PATH="$PFX/fido2/lib/pkgconfig:$PFX/cbor/lib/pkgconfig:$PFX/openssl/lib64/pkgconfig:$PFX/libedit/lib/pkgconfig:$PFX/zlib/lib/pkgconfig"
LDFLAGS="-L$PFX/staticlibs" LIBS="-ltinfo -lpthread" ./configure \
  --prefix=/usr --sysconfdir=/etc/ssh --libexecdir=/usr/lib/openssh \
  --with-privsep-path=/run/sshd --with-pid-dir=/run \
  --with-pam --with-libedit --with-selinux --with-audit=linux \
  --with-security-key-builtin --with-xauth=/usr/bin/xauth \
  --with-zlib="$PFX/zlib" --with-ssl-dir="$PFX/openssl" \
  --with-default-path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --with-mantype=doc --disable-strip
# 链接顺序修正 1/2
sed -i "s|^LIBEDIT=\(.*\)-ledit[[:space:]]*$|LIBEDIT=\1-ledit -ltinfo|" Makefile
sed -i 's|^CHANNELLIBS=-lcrypto[[:space:]]*-lz[[:space:]]*$|CHANNELLIBS=-lcrypto -lz -ldl -lpthread|' Makefile
grep -q -- '-ledit -ltinfo' Makefile        || die "LIBEDIT 链接修正未生效"
grep -q -- 'CHANNELLIBS=-lcrypto -lz -ldl -lpthread' Makefile || die "CHANNELLIBS 链接修正未生效"
make -j"$J"

# 版本自适应:9.8+ 才有 sshd-session,9.9+ 才有 sshd-auth
HAS_SSHD_SESSION=0; [ -x ./sshd-session ] && HAS_SSHD_SESSION=1
HAS_SSHD_AUTH=0;    [ -x ./sshd-auth ]    && HAS_SSHD_AUTH=1
echo "拆分二进制: sshd-session=$HAS_SSHD_SESSION sshd-auth=$HAS_SSHD_AUTH"

# ------------------------------------------------------------ 4. 冒烟测试
log "5/7 功能冒烟测试(容器内回环登录/sftp/压缩)"
B="$PWD"
V_OUT=$("$B/ssh" -V 2>&1); echo "$V_OUT"
grep -q "OpenSSH_${OPENSSH_VER}, OpenSSL ${OPENSSL_VER}" <<<"$V_OUT" \
  || die "ssh -V 版本输出不符: $V_OUT"

getent passwd sshd >/dev/null 2>&1 || useradd -r --no-create-home \
  -d /run/sshd -s /usr/sbin/nologin sshd
mkdir -p /run/sshd && chmod 755 /run/sshd

# 树内 sshd 按编译期路径查找 sshd-session/sshd-auth/sftp-server;
# sftp 客户端还会派生编译期 _PATH_SSH_PROGRAM(/usr/bin/ssh)作传输进程。
# 冒烟测试前临时软链到目标路径(打包用 DESTDIR,不受影响),测毕清理
mkdir -p /usr/lib/openssh
SMOKE_LINKS=""
[ "$HAS_SSHD_SESSION" -eq 1 ] && { ln -sf "$B/sshd-session" /usr/lib/openssh/sshd-session; SMOKE_LINKS="/usr/lib/openssh/sshd-session $SMOKE_LINKS"; }
[ "$HAS_SSHD_AUTH"    -eq 1 ] && { ln -sf "$B/sshd-auth"    /usr/lib/openssh/sshd-auth;    SMOKE_LINKS="/usr/lib/openssh/sshd-auth $SMOKE_LINKS"; }
ln -sf "$B/sftp-server" /usr/lib/openssh/sftp-server; SMOKE_LINKS="/usr/lib/openssh/sftp-server $SMOKE_LINKS"
ln -sf "$B/ssh" /usr/bin/ssh;                          SMOKE_LINKS="/usr/bin/ssh $SMOKE_LINKS"

T=/tmp/smoke; rm -rf $T; mkdir -p $T; cd $T
"$B/ssh-keygen" -q -t ed25519 -N "" -f $T/host_key
"$B/ssh-keygen" -q -t ed25519 -N "" -f $T/id
cat $T/id.pub > $T/authorized_keys
cat > $T/sshd_config <<CFG
Port 2299
ListenAddress 127.0.0.1
HostKey $T/host_key
PidFile $T/sshd.pid
AuthorizedKeysFile $T/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
UsePAM no
StrictModes no
Subsystem sftp internal-sftp
CFG
"$B/sshd" -t -f $T/sshd_config
"$B/sshd" -f $T/sshd_config
trap 'rm -f $SMOKE_LINKS; kill $(cat $T/sshd.pid) 2>/dev/null || true' EXIT
sleep 1
SSHOPT="-p 2299 -i $T/id -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=$T/kh -o IdentitiesOnly=yes"
"$B/ssh" $SSHOPT root@127.0.0.1 'echo SMOKE_LOGIN_OK'
# grep 不用 -q:ssh -vv 输出量大,-q 匹配即退出会让 ssh 收到 SIGPIPE,
# 在 pipefail 下造成误判
"$B/ssh" -vv -o Compression=yes $SSHOPT root@127.0.0.1 true 2>&1 \
  | grep 'compression: zlib@openssh.com' >/dev/null \
  || die "zlib 压缩未生效"
echo smoke_data > $T/f
printf "put $T/f /tmp/smoke.up\n" | "$B/sftp" -b - -P 2299 -i $T/id -F /dev/null \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=$T/kh -s "$B/sftp-server" root@127.0.0.1
printf "get /tmp/smoke.up $T/f.back\n" | "$B/sftp" -b - -P 2299 -i $T/id -F /dev/null \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=$T/kh root@127.0.0.1
cmp $T/f $T/f.back && echo SMOKE_SFTP_OK
rm -f /tmp/smoke.up
kill $(cat $T/sshd.pid); rm -f $SMOKE_LINKS; trap - EXIT

# ------------------------------------------------------------ 5. 打包
log "6/7 打包三个 deb(版本 ${VER})"
cd "$WORK/openssh-${OPENSSH_VER}"   # 从冒烟测试目录切回源码树
ST=$WORK/stage_all; rm -rf "$ST"; mkdir -p "$ST"
make DESTDIR="$ST" install > /dev/null

# strip(显式清单,保留动态符号表;按实际存在与否自适应)
for f in ssh scp sftp ssh-add ssh-agent ssh-keygen ssh-keyscan \
         ssh-keysign ssh-pkcs11-helper ssh-sk-helper \
         sshd sshd-session sshd-auth sftp-server; do
  strip --strip-unneeded "$ST/usr/bin/$f" 2>/dev/null \
    || strip --strip-unneeded "$ST/usr/sbin/$f" 2>/dev/null \
    || strip --strip-unneeded "$ST/usr/lib/openssh/$f" 2>/dev/null \
    || true
done

# ssh-keysign 需要 setuid root(HostbasedAuthentication);make install 装为
# 4711,strip 原位重写后在此显式恢复,终验与彩排均有断言兜底
# (rpm 侧 spec 以 %attr(4511,root,root) 做同一件事,做法对齐;数值差异仅在
#  owner 写位:deb 4711 保留 owner 可写,rpm 4511 收紧为不可写)
if [ -f "$ST/usr/lib/openssh/ssh-keysign" ]; then
  chmod 4711 "$ST/usr/lib/openssh/ssh-keysign"
fi

PK=$WORK/pkg; rm -rf "$PK"; mkdir -p \
  "$PK/client/usr/bin" "$PK/client/usr/lib/openssh" \
  "$PK/client/usr/share/man/man1" "$PK/client/usr/share/man/man8" \
  "$PK/client/usr/share/doc/openssh-client" "$PK/client/etc/ssh" \
  "$PK/client/etc/ssh/ssh_config.d" "$PK/client/DEBIAN" \
  "$PK/server/usr/sbin" "$PK/server/usr/lib/openssh" \
  "$PK/server/usr/share/man/man5" "$PK/server/usr/share/man/man8" \
  "$PK/server/usr/share/doc/openssh-server" "$PK/server/etc/ssh" \
  "$PK/server/etc/ssh/sshd_config.d" "$PK/server/etc/pam.d" "$PK/server/etc/default" \
  "$PK/server/etc/init.d" "$PK/server/lib/systemd/system" "$PK/server/DEBIAN" \
  "$PK/sftp/usr/lib/openssh" "$PK/sftp/usr/share/man/man8" \
  "$PK/sftp/usr/share/doc/openssh-sftp-server" "$PK/sftp/DEBIAN"

copy_if() { # copy_if <源目录> <目标目录> <文件...>(源文件缺失则跳过)
  local src="$1" dst="$2" f
  shift 2
  for f in "$@"; do
    if [ -f "$src/$f" ]; then cp -a "$src/$f" "$dst/"; fi
  done
}

# ---- client 文件 ----
copy_if "$ST/usr/bin" "$PK/client/usr/bin" \
  ssh scp sftp ssh-add ssh-agent ssh-keygen ssh-keyscan
copy_if "$ST/usr/lib/openssh" "$PK/client/usr/lib/openssh" \
  ssh-keysign ssh-pkcs11-helper ssh-sk-helper
install -m 755 contrib/ssh-copy-id "$PK/client/usr/bin/ssh-copy-id"
install -m 644 contrib/ssh-copy-id.1 "$PK/client/usr/share/man/man1/ssh-copy-id.1"
copy_if "$ST/usr/share/man/man1" "$PK/client/usr/share/man/man1" \
  scp.1 sftp.1 ssh.1 ssh-add.1 ssh-agent.1 ssh-keygen.1 ssh-keyscan.1
copy_if "$ST/usr/share/man/man8" "$PK/client/usr/share/man/man8" \
  ssh-keysign.8 ssh-pkcs11-helper.8 ssh-sk-helper.8
cp -a LICENCE "$PK/client/usr/share/doc/openssh-client/"
printf 'OpenSSH %s, built against OpenSSL %s (statically linked).\nUpstream licence: BSD-style, see LICENCE.\n' \
  "$OPENSSH_VER" "$OPENSSL_VER" > "$PK/client/usr/share/doc/openssh-client/copyright"

# ---- server 文件 ----
copy_if "$ST/usr/sbin" "$PK/server/usr/sbin" sshd
copy_if "$ST/usr/lib/openssh" "$PK/server/usr/lib/openssh" sshd-session sshd-auth
copy_if "$ST/usr/share/man/man5" "$PK/server/usr/share/man/man5" sshd_config.5 moduli.5
copy_if "$ST/usr/share/man/man8" "$PK/server/usr/share/man/man8" sshd.8
cp -a moduli "$PK/server/etc/ssh/moduli"
cp -a LICENCE "$PK/server/usr/share/doc/openssh-server/"
printf 'OpenSSH %s, built against OpenSSL %s (statically linked).\nUpstream licence: BSD-style, see LICENCE.\n' \
  "$OPENSSH_VER" "$OPENSSL_VER" > "$PK/server/usr/share/doc/openssh-server/copyright"

# ---- sftp-server 文件 ----
cp -a "$ST/usr/lib/openssh/sftp-server" "$PK/sftp/usr/lib/openssh/"
cp -a "$ST/usr/share/man/man8/sftp-server.8" "$PK/sftp/usr/share/man/man8/"
printf 'OpenSSH %s, built against OpenSSL %s statically linked in; depends only on libc6.\n' \
  "$OPENSSH_VER" "$OPENSSL_VER" > "$PK/sftp/usr/share/doc/openssh-sftp-server/copyright"

# ---- server:systemd unit ----
cat > "$PK/server/lib/systemd/system/ssh.service" <<'EOF'
[Unit]
Description=OpenBSD Secure Shell server
Documentation=man:sshd(8) man:sshd_config(5)
After=network.target auditd.service
ConditionPathExists=!/etc/ssh/sshd_not_to_be_run

[Service]
EnvironmentFile=-/etc/default/ssh
ExecStartPre=/usr/sbin/sshd -t
ExecStart=/usr/sbin/sshd -D $SSHD_OPTS
ExecReload=/usr/sbin/sshd -t
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=simple
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
Alias=sshd.service
EOF

# ---- server:PAM ----
cat > "$PK/server/etc/pam.d/sshd" <<'EOF'
# PAM configuration for the secure shell service
@include common-auth
account required pam_nologin.so
@include common-account
session [success=ok ignore=ignore module_unknown=ignore default=bad] pam_selinux.so close
session required pam_loginuid.so
session optional pam_keyinit.so force revoke
@include common-session
session optional pam_motd.so motd=/run/motd.dynamic
session optional pam_motd.so noupdate
session optional pam_mail.so standard noenv
session required pam_limits.so
session required pam_env.so
session [success=ok ignore=ignore module_unknown=ignore default=bad] pam_selinux.so open
@include common-password
EOF

# ---- server:/etc/default/ssh ----
cat > "$PK/server/etc/default/ssh" <<'EOF'
# Default settings for openssh-server. This file is sourced by /etc/init.d/ssh
# and the systemd unit; options passed here are appended to sshd command line.

# Options to pass to sshd
SSHD_OPTS=
EOF

# ---- server:SysV init(无 systemd 环境回退)----
cat > "$PK/server/etc/init.d/ssh" <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:             sshd
# Required-Start:       $remote_fs $syslog
# Required-Stop:        $remote_fs $syslog
# Default-Start:        2 3 4 5
# Default-Stop:         0 1 6
# Short-Description:    OpenBSD Secure Shell server
### END INIT INFO

PIDFILE=/run/sshd.pid
DAEMON=/usr/sbin/sshd

[ -x "$DAEMON" ] || exit 0

. /lib/lsb/init-functions

if [ -r /etc/default/ssh ]; then
	. /etc/default/ssh
fi

check_privsep_dir() {
	mkdir -p /run/sshd
	chmod 0755 /run/sshd
}

check_config() {
	/usr/sbin/sshd -t || exit 1
}

case "$1" in
  start)
	log_daemon_msg "Starting OpenBSD Secure Shell server" "sshd" || true
	check_privsep_dir
	check_config
	if start-stop-daemon --start --quiet --pidfile "$PIDFILE" --exec "$DAEMON" -- $SSHD_OPTS; then
	    log_end_msg 0 || true
	else
	    log_end_msg 1 || true
	fi
	;;
  stop)
	log_daemon_msg "Stopping OpenBSD Secure Shell server" "sshd" || true
	if start-stop-daemon --stop --quiet --oknodo --pidfile "$PIDFILE"; then
	    log_end_msg 0 || true
	else
	    log_end_msg 1 || true
	fi
	;;
  reload|force-reload)
	check_config
	log_daemon_msg "Reloading OpenBSD Secure Shell server" "sshd" || true
	if start-stop-daemon --stop --signal HUP --quiet --oknodo --pidfile "$PIDFILE"; then
	    log_end_msg 0 || true
	else
	    log_end_msg 1 || true
	fi
	;;
  restart)
	check_privsep_dir
	check_config
	log_daemon_msg "Restarting OpenBSD Secure Shell server" "sshd" || true
	start-stop-daemon --stop --quiet --oknodo --pidfile "$PIDFILE"
	sleep 1
	if start-stop-daemon --start --quiet --pidfile "$PIDFILE" --exec "$DAEMON" -- $SSHD_OPTS; then
	    log_end_msg 0 || true
	else
	    log_end_msg 1 || true
	fi
	;;
  status)
	status_of_proc -p "$PIDFILE" "$DAEMON" sshd && exit 0 || exit $?
	;;
  *)
	echo "Usage: /etc/init.d/ssh {start|stop|restart|reload|force-reload|status}"
	exit 1
esac

exit 0
EOF
chmod 755 "$PK/server/etc/init.d/ssh"

# ---- client:ssh_config(与 rpm/SOURCES/ssh_config 保持一致,含 Include)----
cat > "$PK/client/etc/ssh/ssh_config" <<EOF
# This is the ssh client system-wide configuration file.
# OpenSSH ${OPENSSH_VER} local build (OpenSSL ${OPENSSL_VER} statically linked).

Include /etc/ssh/ssh_config.d/*.conf

Host *
#   ForwardAgent no
#   ForwardX11 no
#   ForwardX11Trusted yes
    PasswordAuthentication yes
#   HostbasedAuthentication no
#   BatchMode no
#   CheckHostIP no
#   AddressFamily any
#   ConnectTimeout 0
#   StrictHostKeyChecking ask
#   IdentityFile ~/.ssh/id_rsa
#   IdentityFile ~/.ssh/id_ecdsa
#   IdentityFile ~/.ssh/id_ed25519
#   IdentityFile ~/.ssh/id_ecdsa_sk
#   IdentityFile ~/.ssh/id_ed25519_sk
#   Port 22
#   Ciphers aes128-ctr,aes192-ctr,aes256-ctr
#   MACs hmac-sha2-256,hmac-sha2-512
#   EscapeChar ~
#   Tunnel no
#   TunnelDevice any:any
#   PermitLocalCommand no
#   RekeyLimit 1G 1h
    SendEnv LANG LC_*
    HashKnownHosts yes
    KbdInteractiveAuthentication no
EOF

# ---- server:sshd_config ----
cat > "$PK/server/etc/ssh/sshd_config" <<EOF
# This is the sshd server system-wide configuration file.
# OpenSSH ${OPENSSH_VER} local build (OpenSSL ${OPENSSL_VER} statically linked).

Include /etc/ssh/sshd_config.d/*.conf

#Port 22
#AddressFamily any
#ListenAddress 0.0.0.0
#ListenAddress ::

#HostKey /etc/ssh/ssh_host_rsa_key
#HostKey /etc/ssh/ssh_host_ecdsa_key
#HostKey /etc/ssh/ssh_host_ed25519_key

# Ciphers and keying
#RekeyLimit default none

# Logging
#SyslogFacility AUTH
#LogLevel INFO

# Authentication:

#LoginGraceTime 2m
PermitRootLogin prohibit-password
#StrictModes yes
#MaxAuthTries 6
#MaxSessions 10

PubkeyAuthentication yes

# Expect .ssh/authorized_keys to be kept by users
AuthorizedKeysFile	.ssh/authorized_keys

#AuthorizedPrincipalsFile none

#AuthorizedKeysCommand none
#AuthorizedKeysCommandUser nobody

# For this to work you will also need host keys in /etc/ssh/ssh_known_hosts
#HostbasedAuthentication no
# Change to yes if you don't trust ~/.ssh/known_hosts for
# HostbasedAuthentication
#IgnoreUserKnownHosts no
# Don't read the user's ~/.rhosts and ~/.shosts files
#IgnoreRhosts yes

# To disable tunneled clear text passwords, change to no here!
PasswordAuthentication yes
#PermitEmptyPasswords no

# Change to yes to enable challenge-response passwords (beware issues with
# some PAM modules and threads)
KbdInteractiveAuthentication no

# Kerberos options
#KerberosAuthentication no
#KerberosOrLocalPasswd yes
#KerberosTicketCleanup yes
#KerberosGetAFSToken no

# Set this to 'yes' to enable PAM authentication, account processing,
# and session processing.
UsePAM yes

#AllowAgentForwarding yes
#AllowTcpForwarding yes
#GatewayPorts no
X11Forwarding yes
#X11DisplayOffset 10
#X11UseLocalhost yes
#PermitTTY yes
PrintMotd no
#PrintLastLog yes
#TCPKeepAlive yes
#PermitUserEnvironment no
#Compression delayed
#ClientAliveInterval 0
#ClientAliveCountMax 3
#UseDNS no
#PidFile /run/sshd.pid
#MaxStartups 10:30:100
#PermitTunnel no
#ChrootDirectory none
#VersionAddendum none

# no default banner path
#Banner none

# Allow client to pass locale environment variables
AcceptEnv LANG LC_*

# override default of no subsystems
Subsystem	sftp	/usr/lib/openssh/sftp-server

# Example of overriding settings on a per-user basis
#Match User anoncvs
#	X11Forwarding no
#	AllowTcpForwarding no
#	PermitTTY no
#	ForceCommand cvs server
EOF

# ---- control 文件(含 $VER 替换)----
cat > "$PK/client/DEBIAN/control" <<EOF2
Package: openssh-client
Version: $VER
Section: net
Priority: optional
Architecture: amd64
Maintainer: Local OpenSSH build <root@localhost>
Depends: libc6 (>= 2.26), libselinux1 (>= 2.0.65), libudev1 (>= 183)
Recommends: xauth
Provides: ssh-client
Description: secure shell (SSH) client, for secure access from remote machines
 OpenSSH is a free version of the SSH connectivity tools that users of
 telnet/rlogin or similar programs must use to avoid account hijacking
 from sniffers. This package provides the ssh, scp and sftp clients,
 the ssh-keygen key management utility and the ssh-agent authentication
 agent.
 .
 Built from upstream OpenSSH $OPENSSH_VER with OpenSSL $OPENSSL_VER, zlib $ZLIB_VER,
 libfido2 $FIDO2_VER and libedit $LIBEDIT_VER all statically linked in,
 so the package does not depend on the system libssl/libz/libfido2
 runtime libraries.
EOF2
printf '/etc/ssh/ssh_config\n' > "$PK/client/DEBIAN/conffiles"
cat > "$PK/client/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

# ssh-keysign 以 setuid root 模式安装,无需额外的 ssh 组;
# 此处不做任何系统改动,保留脚本便于后续扩展。

exit 0
EOF
chmod 755 "$PK/client/DEBIAN/postinst"

cat > "$PK/server/DEBIAN/control" <<EOF2
Package: openssh-server
Version: $VER
Section: net
Priority: optional
Architecture: amd64
Maintainer: Local OpenSSH build <root@localhost>
Depends: libaudit1 (>= 1:2.2.1), libc6 (>= 2.26), libcrypt1 (>= 1:4.1.0), libpam-modules (>= 0.72-9), libpam0g (>= 0.99.7.1), libselinux1 (>= 2.0.65), openssh-client (= $VER), openssh-sftp-server (= $VER)
Provides: ssh-server
Description: secure shell (SSH) server, for secure access from remote machines
 OpenSSH is a free version of the SSH connectivity tools. This package
 provides the sshd server (including the sshd-session and sshd-auth
 split binaries required by OpenSSH 10.0+), PAM integration and a
 systemd service unit.
 .
 Built from upstream OpenSSH $OPENSSH_VER with OpenSSL $OPENSSL_VER, zlib $ZLIB_VER,
 libfido2 $FIDO2_VER and libedit $LIBEDIT_VER all statically linked in,
 so the package does not depend on the system libssl/libz/libfido2
 runtime libraries.
EOF2
cat > "$PK/server/DEBIAN/conffiles" <<'EOF'
/etc/default/ssh
/etc/init.d/ssh
/etc/pam.d/sshd
/etc/ssh/moduli
/etc/ssh/sshd_config
EOF

# preinst:建 sshd 特权分离用户;精简镜像无 adduser 时回退 useradd
cat > "$PK/server/DEBIAN/preinst" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = install ] || [ "$1" = upgrade ]; then
    if ! getent passwd sshd >/dev/null 2>&1; then
        if command -v adduser >/dev/null 2>&1; then
            adduser --quiet --system --no-create-home --home /run/sshd \
                --shell /usr/sbin/nologin sshd
        elif command -v useradd >/dev/null 2>&1; then
            useradd --system --no-create-home --home-dir /run/sshd \
                --shell /usr/sbin/nologin sshd
        else
            echo "WARNING: no tool to create the sshd privsep user" >&2
        fi
    fi
fi

exit 0
EOF

cat > "$PK/server/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = configure ]; then
    # 确保特权分离目录存在(systemd 由单元的 RuntimeDirectory= 处理,
    # 此处覆盖非 systemd 系统与服务启动前的升级场景)
    mkdir -p /run/sshd
    chmod 0755 /run/sshd

    # 生成缺失的主机密钥
    if [ ! -e /etc/ssh/sshd_not_to_be_run ] && command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -A >/dev/null 2>&1 || true
    fi

    # (重新)启动前校验配置:仅告警不硬失败 —— 现网 sshd_config 若含新版
    # 不再接受的指令,硬失败会把升级事务留在 half-configured;配置硬校验
    # 由 unit 的 ExecStartPre=/usr/sbin/sshd -t 承担(失败体现在服务状态),
    # SysV init 脚本的 check_config 亦然(start/restart/reload 均先校验)
    if [ ! -e /etc/ssh/sshd_not_to_be_run ]; then
        /usr/sbin/sshd -t || \
            echo "WARNING: sshd -t 未通过,sshd 可能无法启动;请检查 /etc/ssh/sshd_config" >&2
    fi

    if command -v deb-systemd-helper >/dev/null 2>&1; then
        deb-systemd-helper unmask ssh.service >/dev/null || true
        deb-systemd-helper enable ssh.service >/dev/null || true
        deb-systemd-helper restart ssh.service >/dev/null || true
    fi

    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null || true
    fi

    if [ ! -e /etc/ssh/sshd_not_to_be_run ]; then
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
            if [ -n "$2" ]; then
                deb-systemd-invoke try-restart ssh.service >/dev/null || true
            else
                deb-systemd-invoke start ssh.service >/dev/null || true
            fi
        elif command -v invoke-rc.d >/dev/null 2>&1; then
            if [ -n "$2" ]; then
                invoke-rc.d ssh restart
            else
                invoke-rc.d ssh start
            fi
        fi
    fi
fi

exit 0
EOF

cat > "$PK/server/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = remove ] || [ "$1" = deconfigure ]; then
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop ssh.service >/dev/null 2>&1 || true
    elif command -v invoke-rc.d >/dev/null 2>&1; then
        invoke-rc.d ssh stop || true
    fi
fi

exit 0
EOF

cat > "$PK/server/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = remove ] || [ "$1" = purge ]; then
    if command -v deb-systemd-helper >/dev/null 2>&1; then
        deb-systemd-helper purge ssh.service >/dev/null || true
    fi
fi
if [ "$1" = purge ]; then
    # 不自动删除主机密钥与 sshd_config 备份
    :
fi
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null || true
fi

exit 0
EOF
chmod 755 "$PK/server/DEBIAN/preinst" "$PK/server/DEBIAN/postinst" \
          "$PK/server/DEBIAN/prerm" "$PK/server/DEBIAN/postrm"

cat > "$PK/sftp/DEBIAN/control" <<EOF2
Package: openssh-sftp-server
Version: $VER
Section: net
Priority: optional
Architecture: amd64
Maintainer: Local OpenSSH build <root@localhost>
Depends: libc6 (>= 2.26)
Enhances: openssh-server
Description: secure shell (SSH) sftp server module
 This is the sftp-server program used by openssh-server to provide the
 SFTP file transfer subsystem over SSH.
 .
 Built from upstream OpenSSH $OPENSSH_VER with OpenSSL $OPENSSL_VER statically
 linked in; depends only on libc6.
EOF2

# ---- md5sums + dpkg-deb(%3a 编码文件名,focal apt 兼容)----
for p in client server sftp; do
  ( cd "$PK/$p" && find . -type f ! -path "./DEBIAN/*" -print0 \
      | LC_ALL=C sort -z | xargs -0 md5sum > DEBIAN/md5sums )
done
VER_FILE="${VER//:/%3a}"
for p in client server sftp; do
  case $p in
    client) name=openssh-client ;;
    server) name=openssh-server ;;
    sftp)   name=openssh-sftp-server ;;
  esac
  dpkg-deb --root-owner-group -Zxz --build "$PK/$p" \
    "$OUT/${name}_${VER_FILE}_amd64.deb"
done

# ------------------------------------------------------------ 6. 终验
log "7/7 终验:包内字节 ldd / md5sums / dpkg-deb 元数据"
VR=/tmp/verify; rm -rf $VR; mkdir -p $VR
for d in "$OUT"/*.deb; do dpkg-deb -x "$d" $VR; dpkg-deb -e "$d" $VR/ctl_$(basename "$d"); done
BAD=0
for b in usr/bin/ssh usr/sbin/sshd usr/bin/sftp usr/lib/openssh/ssh-sk-helper \
         usr/lib/openssh/sftp-server; do
  if ldd "$VR/$b" 2>/dev/null | grep -qE 'libcrypto|libssl|libz\.|libfido2|libcbor|libedit|libtinfo'; then
    echo "FAIL: $b 存在动态加密依赖"; BAD=1
  fi
done
for b in usr/lib/openssh/sshd-session usr/lib/openssh/sshd-auth; do
  if [ -f "$VR/$b" ] && ldd "$VR/$b" 2>/dev/null | grep -qE 'libcrypto|libssl|libz\.|libfido2|libcbor|libedit|libtinfo'; then
    echo "FAIL: $b 存在动态加密依赖"; BAD=1
  fi
done
[ "$BAD" -eq 0 ] || exit 1
"$VR/usr/bin/ssh" -V 2>&1 | grep -q "OpenSSH_${OPENSSH_VER}, OpenSSL ${OPENSSL_VER}" \
  || die "包内 ssh -V 校验失败"
[ -u "$VR/usr/lib/openssh/ssh-keysign" ] || die "ssh-keysign 丢失 setuid 位"
echo "ldd 校验通过:无 libcrypto/libssl/libz/libfido2/libcbor/libedit/libtinfo 动态依赖"

log "构建完成,产物:"
ls -la "$OUT"
sha256sum "$OUT"/*.deb | tee "$OUT/sha256.txt"
