#!/bin/bash
# =============================================================================
# OpenSSH RPM 容器内构建脚本(stage1:编译 + 打包 + 字节级校验)
# 由 rpm/Dockerfile 的 ENTRYPOINT 调用,在 Rocky Linux 8 容器内运行。
#
# 版本组合由 versions/<版本>.env 定义(OPENSSH_VERSION 指定),物料自动
# 下载到 DOWNLOADS_DIR(已有则复用),全部经 PGP/SHA256 校验。
#
# 环境变量(容器内由顶层 build.sh 注入,均有默认值):
#   OPENSSH_VERSION   要构建的 OpenSSH 版本(必填)
#   VERSIONS_DIR      版本配置目录(默认 /versions)
#   DOWNLOADS_DIR     物料缓存目录(默认 /downloads)
#   WORK              构建工作目录(默认 /work)
#   OUT               产物输出目录(默认 /out)
#   RPM_RELEASE       覆盖 env 文件中的 release 标签
#   GLIBC_MAX         产物 GLIBC 符号版本上限(默认 2.28,基底 glibc 决定)
#
# 编译逻辑全部在生成的 spec 内完成(%build 静态依赖 + OpenSSH),本脚本负责:
#   1) 物料获取与 PGP / SHA256 校验
#   2) 从 openssh.spec.in 生成 spec(版本替换 + 拆分二进制探测)
#   3) rpmbuild -bb
#   4) 产物校验:静态内嵌断言(ldd 无 crypto 族)、GLIBC 符号上限、
#      包内 ssh -V、RPM 自动依赖清单留档
# =============================================================================
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../common/common.sh"

: "${OPENSSH_VERSION:?需要 OPENSSH_VERSION 指定 versions/ 下的版本}"
RPM_RELEASE_OVERRIDE="${RPM_RELEASE:-}"
load_version_env "$OPENSSH_VERSION" "${VERSIONS_DIR:-/versions}"
[ -n "$RPM_RELEASE_OVERRIDE" ] && RPM_RELEASE="$RPM_RELEASE_OVERRIDE"

WORK="${WORK:-/work}"
OUT="${OUT:-/out}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-/downloads}"
GLIBC_MAX="${GLIBC_MAX:-2.28}"
TOP="$WORK/rpmbuild"
mkdir -p "$TOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS} "$OUT"

log() { printf '\n== %s\n' "$*"; }

# ------------------------------------------------ 1. 物料获取与校验
log "1/4 获取并校验物料(版本组合:OpenSSH ${OPENSSH_VER} + OpenSSL ${OPENSSL_VER})"
fetch_materials "$DOWNLOADS_DIR"

# ------------------------------------------------ 2. 生成 spec
# 拆分二进制按源码树实际内容探测(sshd-session 自 9.8、sshd-auth 自 9.9 引入),
# 使同一模板适配不同 OpenSSH 版本。
# 注意:listing 先完整读入再 grep —— tar | grep -q 的组合在 pipefail 下有
# SIGPIPE 竞态(grep 匹配即退出,tar 可能因管道破裂以 141 退出导致误判)
TARLIST="$(tar tzf "$DOWNLOADS_DIR/openssh-${OPENSSH_VER}.tar.gz")"
WITH_SSHD_SESSION=0
grep -q "^openssh-${OPENSSH_VER}/sshd-session\.c$" <<<"$TARLIST" && WITH_SSHD_SESSION=1
WITH_SSHD_AUTH=0
grep -q "^openssh-${OPENSSH_VER}/sshd-auth\.c$" <<<"$TARLIST" && WITH_SSHD_AUTH=1
log "2/4 生成 spec(拆分二进制: sshd-session=$WITH_SSHD_SESSION sshd-auth=$WITH_SSHD_AUTH)"

sed -e "s|@OPENSSH_VER@|$OPENSSH_VER|g" \
    -e "s|@OPENSSL_VER@|$OPENSSL_VER|g" \
    -e "s|@ZLIB_VER@|$ZLIB_VER|g" \
    -e "s|@CBOR_VER@|$CBOR_VER|g" \
    -e "s|@FIDO2_VER@|$FIDO2_VER|g" \
    -e "s|@LIBEDIT_VER@|$LIBEDIT_VER|g" \
    -e "s|@NCURSES_VER@|$NCURSES_VER|g" \
    -e "s|@RPM_RELEASE@|$RPM_RELEASE|g" \
    -e "s|@WITH_SSHD_SESSION@|$WITH_SSHD_SESSION|g" \
    -e "s|@WITH_SSHD_AUTH@|$WITH_SSHD_AUTH|g" \
    -e "s|@CHANGELOG_DATE@|$(date '+%a %b %d %Y')|g" \
    "$SCRIPT_DIR/openssh.spec.in" > "$TOP/SPECS/openssh.spec"

S="$TOP/SOURCES"
for f in openssh-$OPENSSH_VER.tar.gz openssh-$OPENSSH_VER.tar.gz.asc \
         openssl-$OPENSSL_VER.tar.gz zlib-$ZLIB_VER.tar.gz \
         libcbor-$CBOR_VER.tar.gz libfido2-$FIDO2_VER.tar.gz \
         libedit-$LIBEDIT_VER.tar.gz ncurses-$NCURSES_VER.tar.gz; do
  cp -a "$DOWNLOADS_DIR/$f" "$S/"
done
cp -a "$SCRIPT_DIR"/SOURCES/* "$S/"

# ---------------------------------------------------------------- 3. rpmbuild
log "3/4 rpmbuild(含全部静态依赖编译,约数分钟)"
# --cache 复用 work/rpm 时 RPMS 会跨版本/release 累积旧包,先清空避免
# 旧 NEVRA 混入产物拷贝与 sha256/requires 清单
rm -rf "$TOP/RPMS/$(uname -m)"
mkdir -p "$TOP/RPMS/$(uname -m)"
rpmbuild --define "_topdir $TOP" -bb "$TOP/SPECS/openssh.spec" 2>&1 | tee /tmp/rpmbuild.log
ls "$TOP/RPMS/$(uname -m)/"

# ------------------------------------------------------------ 4. 产物字节校验
log "4/4 产物校验:静态内嵌 / GLIBC 符号上限 / ssh -V / 依赖清单"
VR=/tmp/verifyroot; rm -rf "$VR"; mkdir -p "$VR"
ARCH=$(uname -m)
for r in "$TOP"/RPMS/$ARCH/*.rpm; do
  d="$VR/$(basename "$r" .rpm)"; mkdir -p "$d"
  (cd "$d" && rpm2cpio "$r" | cpio -idmu --quiet)
done

# 4a. 所有 ELF:不得动态依赖加密/压缩/FIDO/edit 族
BAD=0
while IFS= read -r -d '' elf; do
  if ldd "$elf" 2>/dev/null | grep -qE 'libcrypto|libssl|libz\.|libfido2|libcbor|libedit|libtinfo'; then
    echo "FAIL: $elf 存在动态加密依赖:"; ldd "$elf"; BAD=1
  fi
done < <(find "$VR" -type f -exec sh -c 'file -b "$1" | grep -q ELF' _ {} \; -print0)
[ "$BAD" -eq 0 ] || exit 1
echo "PASS: 无 libcrypto/libssl/libz/libfido2/libcbor/libedit/libtinfo 动态依赖"

# 4b. GLIBC 符号版本上限(由构建基底 glibc 决定,默认 2.28 = Kylin V10 / Rocky 8)
BAD=0
while IFS= read -r -d '' elf; do
  v=$(objdump -T "$elf" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' \
      | sed 's/GLIBC_//' | sort -uV | tail -1)
  if [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$v" "$GLIBC_MAX" | sort -V | tail -1)" != "$GLIBC_MAX" ]; then
    echo "FAIL: $elf 引用 GLIBC_$v (> $GLIBC_MAX)"; BAD=1
  fi
done < <(find "$VR" -type f -exec sh -c 'file -b "$1" | grep -q ELF' _ {} \; -print0)
[ "$BAD" -eq 0 ] || exit 1
echo "PASS: 所有 ELF 的 GLIBC 符号版本 <= $GLIBC_MAX"

# 4c. 包内 ssh -V
CLI="$VR/openssh-clients-${OPENSSH_VER}-${RPM_RELEASE}.$ARCH"
V_OUT=$("$CLI/usr/bin/ssh" -V 2>&1); echo "$V_OUT"
echo "$V_OUT" | grep -q "OpenSSH_$OPENSSH_VER, OpenSSL $OPENSSL_VER" \
  || { echo "FAIL: 包内 ssh -V 不符" >&2; exit 1; }
echo "PASS: 包内字节 ssh -V 正确"

# 4d. RPM 元数据:自动依赖清单留档、分包互依
: > "$OUT/requires.txt"
for r in "$TOP"/RPMS/$ARCH/*.rpm; do
  { echo "=== $(basename "$r") ==="; rpm -qp --requires "$r"; } >> "$OUT/requires.txt"
done
if grep -qE 'libcrypto|libssl|libz\.so|libfido2|libcbor|libedit' "$OUT/requires.txt"; then
  echo "FAIL: RPM 依赖中出现加密/压缩族库"; grep -E 'libcrypto|libssl|libz\.so|libfido2|libcbor|libedit' "$OUT/requires.txt"; exit 1
fi
echo "PASS: RPM 自动依赖不含加密/压缩族"

# ------------------------------------------------------------------ 5. 取件
log "汇出产物"
cp -a "$TOP"/RPMS/$ARCH/*.rpm "$OUT/"
echo "== 构建完成,产物:"
ls -la "$OUT"/*.rpm
sha256sum "$OUT"/*.rpm | tee "$OUT/sha256.txt"
