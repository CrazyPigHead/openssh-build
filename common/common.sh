#!/bin/bash
# =============================================================================
# OpenSSH 构建工具共享函数库
#
# 被以下脚本 source(宿主与容器内均可运行,不依赖容器专属路径):
#   build.sh        顶层构建入口(宿主)
#   deb/build.sh    deb 容器内构建脚本
#   rpm/build.sh    rpm 容器内构建脚本
#   rpm/rehearsal.sh rpm 彩排脚本
#
# 网络代理:本库默认不设置任何代理,直接继承调用方注入的
# http_proxy / https_proxy / no_proxy(小写与大写均透传给 curl/gpg/apt/dnf);
# 宿主侧可用 normalize_proxy_env 统一代理变量后再注入容器。
#
# 物料目录:DOWNLOADS_DIR(默认 ./downloads,容器内由 wrapper 挂载注入为
# /downloads)。本地已有的物料直接复用(照常校验),缺失时自动下载 ——
# 预置好该目录即可实现完全离线构建。
# =============================================================================
# 不在此处 set -euo pipefail:source 方各自设置,库内一律用 ${var:-} 防御展开
DOWNLOADS_DIR="${DOWNLOADS_DIR:-./downloads}"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*" >&2; }
die() { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# normalize_proxy_env [代理 URL]
# 归一化代理环境变量,消除大小写变体混用对构建的干扰(仅作用于本进程
# 及其子进程,不影响宿主 shell 环境):
#   - 传入 URL(显式代理):以其为准设置小写 http_proxy/https_proxy;清除
#     HTTP_PROXY/HTTPS_PROXY/NO_PROXY/ALL_PROXY/all_proxy 残留变体。
#     其中大写 HTTP_PROXY/HTTPS_PROXY 会被 build.sh 透传进容器,残留旧值
#     (常为宿主回环地址)在容器内不可达,curl/git 等读到即失败;
#     ALL_PROXY 不透传,但残留会干扰宿主侧 fetch 的物料下载
#   - no_proxy 以小写为准并继承大写 NO_PROXY 的原值(无则默认排除回环,
#     避免容器内对 localhost 的访问被发往代理)
#   - 不传 URL:清除全部代理变量(--no-proxy 语义)
normalize_proxy_env() {
  local url="${1:-}"
  if [ -n "$url" ]; then
    if [ -z "${no_proxy:-}" ] && [ -n "${NO_PROXY:-}" ]; then no_proxy="$NO_PROXY"; fi
    [ -n "${no_proxy:-}" ] || no_proxy="localhost,127.0.0.1,::1"
    unset HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY all_proxy
    export http_proxy="$url" https_proxy="$url" no_proxy
  else
    unset http_proxy https_proxy no_proxy \
          HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY all_proxy
  fi
}

# load_version_env <openssh 版本> [versions 目录]
# 加载并校验 versions/<版本>.env,必需变量缺失即报错
load_version_env() {
  local ver="${1:?用法: load_version_env <版本>}"
  local dir="${2:-${VERSIONS_DIR:-./versions}}"
  local f="$dir/$ver.env"
  if [ ! -f "$f" ]; then
    local avail
    avail=$(ls "$dir"/*.env 2>/dev/null | xargs -r -n1 basename | sed 's/\.env$//' | tr '\n' ' ')
    die "版本配置不存在: $f(可用版本: ${avail:-无})"
  fi
  # shellcheck disable=SC1090
  . "$f"
  local req=(OPENSSH_VER OPENSSL_VER ZLIB_VER CBOR_VER FIDO2_VER LIBEDIT_VER NCURSES_VER \
             DEB_EPOCH DEB_REVISION RPM_RELEASE OPENSSH_FP \
             SHA256_openssl SHA256_zlib SHA256_cbor SHA256_fido2 SHA256_libedit SHA256_ncurses)
  local v
  for v in "${req[@]}"; do
    [ -n "${!v:-}" ] || die "$f 缺少变量 $v"
  done
  [ "$OPENSSH_VER" = "$ver" ] || die "$f 内 OPENSSH_VER=$OPENSSH_VER 与请求版本 $ver 不一致"
}

# curl_fetch <url> <目标文件>
# 带重试的下载(curl 自身 --retry 不覆盖连接被重置/空响应等 exit 52/56,
# 需 bash 级重试;--speed-time/--speed-limit 防低速停滞)
curl_fetch() {
  local url="$1" out="$2" i rc=1
  local retries="${FETCH_RETRIES:-8}"
  [ -s "$out" ] && return 0
  for i in $(seq 1 "$retries"); do
    if curl -sfL --connect-timeout 15 --speed-time 30 --speed-limit 10240 \
         -o "$out" "$url"; then
      rc=0; break
    fi
    rm -f "$out"
    echo "下载重试($i/$retries): $url" >&2
    sleep 3
  done
  return $rc
}

# verify_materials [downloads 目录] [skip-ncurses]
# 校验已就位的物料:OpenSSH PGP 验签(指纹固定)+ 其余 SHA256。
# ncurses 仅 rpm 构建使用,deb 传入 skip-ncurses 跳过其下载与校验。
verify_materials() {
  local dir="${1:-$DOWNLOADS_DIR}" skip_ncurses="${2:-}"
  ( cd "$dir"
    local logf=./gpg-verify.log
    gpg --batch --import RELEASE_KEY.asc >/dev/null 2>&1 || true
    # 指纹比对基于 gpg 状态行(--status-fd):状态行格式固定、不受本地化
    # 影响,且由 gpg 生成而非密钥属主可控 —— 人读输出中的 uid 文本可被
    # 伪造密钥注入"Primary key fingerprint:"字样,不能作为校验依据。
    # 取 VALIDSIG 末字段(主密钥指纹,连续 40 位十六进制),比对前把期望值
    # 中的空格去掉并统一大写
    gpg --batch --status-fd 1 --verify "openssh-${OPENSSH_VER}.tar.gz.asc" \
                       "openssh-${OPENSSH_VER}.tar.gz" >"$logf" 2>&1 || true
    cat "$logf" >&2
    local fp_expect fp_got
    fp_expect=$(printf '%s' "$OPENSSH_FP" | tr -d ' ' | tr 'a-f' 'A-F')
    fp_got=$(awk '$1=="[GNUPG:]" && $2=="VALIDSIG" {fp=$NF} END{print fp}' "$logf")
    [ -n "$fp_got" ] && [ "$fp_got" = "$fp_expect" ] \
      || die "OpenSSH PGP 验签失败或指纹不符(期望 ${OPENSSH_FP})"
    rm -f "$logf"

    local n
    local -a checks=(openssl:$SHA256_openssl zlib:$SHA256_zlib cbor:$SHA256_cbor \
                     fido2:$SHA256_fido2 libedit:$SHA256_libedit)
    if [ "$skip_ncurses" != "skip-ncurses" ]; then
      checks+=(ncurses:$SHA256_ncurses)
    fi
    for n in "${checks[@]}"; do
      local key="${n%%:*}" sum="${n##*:}" f
      case "$key" in
        openssl) f="openssl-${OPENSSL_VER}.tar.gz" ;;
        zlib)    f="zlib-${ZLIB_VER}.tar.gz" ;;
        cbor)    f="libcbor-${CBOR_VER}.tar.gz" ;;
        fido2)   f="libfido2-${FIDO2_VER}.tar.gz" ;;
        libedit) f="libedit-${LIBEDIT_VER}.tar.gz" ;;
        ncurses) f="ncurses-${NCURSES_VER}.tar.gz" ;;
      esac
      echo "$sum  $f" | sha256sum -c - | grep -q ': OK' \
        || die "SHA256 校验失败: $dir/$f"
      echo "SHA256 OK: $f" >&2
    done
  )
}

# fetch_materials [downloads 目录] [skip-ncurses]
# 确保物料存在:本地已有则复用并校验,缺失则自动下载后校验。
# 下载经环境注入的代理;GitHub tags 链接的 basename 与本地规范名不同,
# 统一以 -o 规范名落盘。ncurses 仅 rpm 构建需要,deb 传入 skip-ncurses
# 跳过(gnu.org 在部分网络不可达,不应拖累 deb 构建)。
fetch_materials() {
  local dir="${1:-$DOWNLOADS_DIR}" skip_ncurses="${2:-}"
  mkdir -p "$dir"
  local BASE=https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable
  # url|规范文件名
  local -a jobs=(
    "$BASE/openssh-${OPENSSH_VER}.tar.gz|openssh-${OPENSSH_VER}.tar.gz"
    "$BASE/openssh-${OPENSSH_VER}.tar.gz.asc|openssh-${OPENSSH_VER}.tar.gz.asc"
    "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/RELEASE_KEY.asc|RELEASE_KEY.asc"
    "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz|openssl-${OPENSSL_VER}.tar.gz"
    "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz|zlib-${ZLIB_VER}.tar.gz"
    "https://github.com/PJK/libcbor/archive/refs/tags/v${CBOR_VER}.tar.gz|libcbor-${CBOR_VER}.tar.gz"
    "https://github.com/Yubico/libfido2/archive/refs/tags/${FIDO2_VER}.tar.gz|libfido2-${FIDO2_VER}.tar.gz"
    "https://www.thrysoee.dk/editline/libedit-${LIBEDIT_VER}.tar.gz|libedit-${LIBEDIT_VER}.tar.gz"
    "https://ftp.gnu.org/pub/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz|ncurses-${NCURSES_VER}.tar.gz"
    "https://mirrors.kernel.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz|ncurses-${NCURSES_VER}.tar.gz"
    "https://mirrors.tuna.tsinghua.edu.cn/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz|ncurses-${NCURSES_VER}.tar.gz"
  )
  local j url name
  for j in "${jobs[@]}"; do
    url="${j%%|*}"; name="${j##*|}"
    # 同名多源:前一个源已成功下载后,后续同条目直接复用本地文件
    if [ -s "$dir/$name" ]; then
      echo "复用本地物料: $dir/$name" >&2
      continue
    fi
    if [ "$skip_ncurses" = "skip-ncurses" ] && [ "$name" = "ncurses-${NCURSES_VER}.tar.gz" ]; then
      continue
    fi
    log "下载 $name"
    curl_fetch "$url" "$dir/$name" || echo "源不可达: $url" >&2
  done
  local missing=0
  for j in "${jobs[@]}"; do
    name="${j##*|}"
    if [ ! -s "$dir/$name" ] \
       && { [ "$skip_ncurses" != "skip-ncurses" ] || [ "$name" != "ncurses-${NCURSES_VER}.tar.gz" ]; }; then
      echo "FATAL: 物料缺失: $dir/$name(全部下载源均失败,可手工放置)" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || exit 1
  verify_materials "$dir" "$skip_ncurses"
}
