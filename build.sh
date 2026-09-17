#!/bin/bash
# =============================================================================
# OpenSSH 通用构建工具 —— 顶层入口(rpm / deb 容器化构建编排)
#
# 用法:
#   ./build.sh <deb|rpm|fetch> [选项]
#
# 示例:
#   ./build.sh deb                          # 以默认版本构建 deb
#   ./build.sh rpm --version 10.5p1         # 指定版本(versions/ 下需有 <版本>.env)
#   ./build.sh deb --revision 1local3       # 覆盖 deb revision
#   ./build.sh rpm --release 1.el8          # 覆盖 rpm release 标签
#   ./build.sh fetch --version 10.5p1       # 仅在宿主机预下载物料(之后可离线构建)
#   ./build.sh deb --shell                  # 进入构建容器交互调试
#
# 物料(源码 tarball):
#   - 默认自动下载到 downloads/(容器内缺失即下载,已存在直接复用);
#   - 全部经 PGP(OpenSSH 指纹)/ SHA256 校验;
#   - 预先将物料放入 downloads/ 即可完全离线构建(等价于挂载注入)。
#
# 网络代理:
#   - 自动透传宿主代理环境变量到构建容器(docker run -e;大小写共 6 个:
#     http_proxy/https_proxy/no_proxy 及其大写变体,ALL_PROXY 不透传);
#   - 或用 --proxy <url> 显式注入(经 normalize_proxy_env 归一化:统一小写
#     http_proxy/https_proxy,清除 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 等残留
#     变体防止旧值污染容器,no_proxy 缺省排除回环);
#   - --no-proxy 清除全部代理变量,不向构建容器透传;
#   - 代理地址为本机回环(127.0.0.1/localhost/::1)时自动附加 --network=host
#     (容器需经宿主网络栈访问该代理);可用 --network 覆盖。
#
# 相关环境变量(均有默认值):
#   OPENSSH_VERSION      默认构建版本(可用 --version 覆盖)
#   DOCKER_REGISTRY_MIRROR  基底镜像本地不存在时使用的镜像仓前缀
#                           (默认 docker.m.daocloud.io/library;置空禁用)
#   DEB_BASE_IMAGE / RPM_BASE_IMAGE  基底镜像名(默认 ubuntu:20.04 / rockylinux:8)
#   APT_MIRROR / DNF_MIRROR   构建镜像内包管理器换源(彩排容器安装原生包亦用)
#   SKIP_OPENSSL_TEST    deb 构建是否跳过 OpenSSL 自测(默认 1,见 deb/build.sh)
#   GLIBC_MAX            rpm 产物 GLIBC 符号上限(默认 2.28)
#   DOCKER_NETWORK_MODE  网络模式(auto/host/bridge;默认 auto)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO_ROOT/common/common.sh"

usage() {
  cat <<'USAGE'
用法: build.sh <deb|rpm|fetch> [选项]

格式:
  deb     构建 deb 三包(openssh-client/-server/-sftp-server,Ubuntu 20.04 基底)
  rpm     构建 rpm 三包(openssh/-clients/-server,Rocky 8 基底,默认面向 Kylin V10)
  fetch   仅在宿主机预下载物料到 downloads/(之后可离线构建)

选项:
  -v, --version <版本>   OpenSSH 版本,对应 versions/<版本>.env(默认 10.5p1)
      --revision <rev>   覆盖 deb revision(env 文件中的 DEB_REVISION)
      --release <rel>    覆盖 rpm release 标签(env 文件中的 RPM_RELEASE)
      --downloads <目录> 物料缓存目录(默认 ./downloads)
      --out <目录>       产物输出根目录(默认 ./out)
      --proxy <url>      注入网络代理(归一化为小写 http_proxy/https_proxy,
                         并清除 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 等残留变体)
      --no-proxy         清除全部代理变量,不向构建容器透传
      --network <模式>   docker 网络模式(auto/host/bridge;auto 时回环代理
                         自动用 host)
      --cache            挂载 work/<格式> 作构建缓存(增量构建)
      --no-rehearsal     (deb/rpm)跳过安装升级彩排验证
      --shell            进入构建容器交互调试(不自动开始构建)
      --list-versions    列出可用版本
  -h, --help             本帮助

环境变量: OPENSSH_VERSION DOCKER_REGISTRY_MIRROR DEB_BASE_IMAGE
  RPM_BASE_IMAGE APT_MIRROR DNF_MIRROR SKIP_OPENSSL_TEST GLIBC_MAX
  DOCKER_NETWORK_MODE(详见文件头注释)
USAGE
}

# ---------------------------------------------------------------- 默认值
FORMAT=""
VERSION="${OPENSSH_VERSION:-10.5p1}"
DOWNLOADS_DIR="$REPO_ROOT/downloads"
OUTROOT="$REPO_ROOT/out"
WORKCACHE=0
REHEARSAL=1
SHELL_MODE=0
DEB_REVISION_ARG=""
RPM_RELEASE_ARG=""
NETWORK_MODE="${DOCKER_NETWORK_MODE:-auto}"
DOCKER_REGISTRY_MIRROR="${DOCKER_REGISTRY_MIRROR:-docker.m.daocloud.io/library}"
APT_MIRROR="${APT_MIRROR:-}"
DNF_MIRROR="${DNF_MIRROR:-}"

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
  case "$1" in
    deb|rpm|fetch) FORMAT="$1" ;;
    -v|--version)   VERSION="${2:?}"; shift ;;
    --revision)     DEB_REVISION_ARG="${2:?}"; shift ;;
    --release)      RPM_RELEASE_ARG="${2:?}"; shift ;;
    --downloads)    DOWNLOADS_DIR="${2:?}"; shift ;;
    --out)          OUTROOT="${2:?}"; shift ;;
    --proxy)        normalize_proxy_env "${2:?}"; shift ;;
    --no-proxy)     normalize_proxy_env ;;
    --network)      NETWORK_MODE="${2:?}"; shift ;;
    --no-rehearsal) REHEARSAL=0 ;;
    --cache)        WORKCACHE=1 ;;
    --shell)        SHELL_MODE=1 ;;
    --list-versions)
      echo "可用版本(versions/*.env):"
      ls versions/*.env 2>/dev/null | xargs -r -n1 basename | sed 's/\.env$//'
      exit 0 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "未知参数: $1(见 --help)" ;;
  esac
  shift
done

[ -n "$FORMAT" ] || { usage; die "必须指定构建格式: deb|rpm|fetch"; }
command -v docker >/dev/null 2>&1 || die "未安装 docker"

# ---------------------------------------------------------------- 版本解析
load_version_env "$VERSION" "$REPO_ROOT/versions"
[ -n "$DEB_REVISION_ARG" ] && DEB_REVISION="$DEB_REVISION_ARG"
[ -n "$RPM_RELEASE_ARG" ]  && RPM_RELEASE="$RPM_RELEASE_ARG"

# --out/--downloads 允许相对路径:docker -v 对含 / 的相对路径报
# invalid volume spec,对纯名称会误挂为命名卷;统一归一为绝对路径
DOWNLOADS_DIR="$(realpath -m "$DOWNLOADS_DIR")"
OUTROOT="$(realpath -m "$OUTROOT")"

mkdir -p "$DOWNLOADS_DIR"

# ---------------------------------------------------------------- 代理透传
PROXY_RUN_ARGS=()
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  [ -n "${!v:-}" ] && PROXY_RUN_ARGS+=(-e "$v=${!v}")
done
PROXY_BUILD_ARGS=()
for v in http_proxy https_proxy no_proxy; do
  [ -n "${!v:-}" ] && PROXY_BUILD_ARGS+=(--build-arg "$v=${!v}")
done

# 代理指向本机回环时容器必须经宿主网络栈访问 → --network=host
# 检测覆盖大小写与 ALL_PROXY 变体(容器内工具对变量大小写的取舍不一)
network_flag() { # 输出 docker --network 参数(空 = 默认 bridge)
  case "$NETWORK_MODE" in
    host|none|bridge) echo "$NETWORK_MODE"; return ;;
  esac
  local p="${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${all_proxy:-}"
  case "$p" in
    *127.0.0.1*|*localhost*|*"[::1]"*) echo host ;;
    *)                                 echo "" ;;
  esac
}
NET_ARGS=()
_nf="$(network_flag)"
[ -n "$_nf" ] && NET_ARGS+=(--network "$_nf")

# ---------------------------------------------------------------- 基底镜像
resolve_base() { # resolve_base <镜像名>:本地已有用原名,否则加镜像仓前缀
  local img="$1"
  if docker image inspect "$img" >/dev/null 2>&1; then echo "$img"; return; fi
  if [ -n "$DOCKER_REGISTRY_MIRROR" ]; then
    echo "$DOCKER_REGISTRY_MIRROR/$img"
  else
    echo "$img"
  fi
}
DEB_BASE="${DEB_BASE_IMAGE:-$(resolve_base ubuntu:20.04)}"
RPM_BASE="${RPM_BASE_IMAGE:-$(resolve_base rockylinux:8)}"

# 仅 fetch:在宿主机预下载物料(构建容器之外的场景)
if [ "$FORMAT" = fetch ]; then
  for t in curl sha256sum gpg; do
    command -v "$t" >/dev/null 2>&1 || die "宿主机缺少 $t(可改用容器构建自动下载)"
  done
  fetch_materials "$DOWNLOADS_DIR"
  echo "物料已就位: $DOWNLOADS_DIR(可断网构建)"
  exit 0
fi

# ---------------------------------------------------------------- 镜像构建
# 工具链镜像不含源码与版本,总是执行 docker build(未变更时命中层缓存,秒级)
build_toolchain_image() { # build_toolchain_image <dockerfile> <tag> <base> [额外build-arg...]
  local df="$1" tag="$2" base="$3"; shift 3
  local -a extra=("$@")
  log "构建工具链镜像 $tag(基底 $base)"
  docker build "${NET_ARGS[@]}" -f "$df" -t "$tag" \
    --build-arg "BASE_IMAGE=$base" \
    "${PROXY_BUILD_ARGS[@]}" "${extra[@]}" "$REPO_ROOT"
}

# ---------------------------------------------------------------- 彩排
# 构建成功后在全新原生基底容器中演练安装/升级与端到端验证(<格式>/rehearsal.sh)
run_rehearsal() { # run_rehearsal <deb|rpm>
  local fmt="$1" base mirror_name rev_name artifacts
  case "$fmt" in
    deb) base="$DEB_BASE"; mirror_name=APT_MIRROR; rev_name=DEB_REVISION ;;
    rpm) base="$RPM_BASE"; mirror_name=DNF_MIRROR; rev_name=RPM_RELEASE ;;
  esac
  artifacts="/${fmt}s"
  log "彩排:在全新 $base 容器中演练安装/升级与端到端验证"
  docker run --rm "${NET_ARGS[@]}" \
    -e "OPENSSH_VERSION=$VERSION" -e VERSIONS_DIR=/versions \
    -e "$mirror_name=${!mirror_name}" -e "$rev_name=${!rev_name}" \
    "${PROXY_RUN_ARGS[@]}" \
    -v "$REPO_ROOT/versions":/versions:ro \
    -v "$REPO_ROOT/$fmt":/opt/build/$fmt:ro \
    -v "$REPO_ROOT/common":/opt/build/common:ro \
    -v "$OUTDIR":"$artifacts":ro \
    "$base" bash /opt/build/$fmt/rehearsal.sh
}

# ---------------------------------------------------------------- 运行构建
case "$FORMAT" in
  deb)
    OUTDIR="$OUTROOT/deb/${OPENSSH_VER}-${DEB_REVISION}"
    IMAGE="${DEB_IMAGE_TAG:-openssh-deb-builder:latest}"
    image_extra=()
    [ -n "$APT_MIRROR" ] && image_extra+=(--build-arg "APT_MIRROR=$APT_MIRROR")
    build_toolchain_image deb/Dockerfile "$IMAGE" "$DEB_BASE" "${image_extra[@]}"

    mkdir -p "$OUTDIR"
    RUN_ARGS=(--rm
      -e "OPENSSH_VERSION=$VERSION" -e VERSIONS_DIR=/versions
      -e "DEB_REVISION=$DEB_REVISION"
      -e "SKIP_OPENSSL_TEST=${SKIP_OPENSSL_TEST:-1}"
      -e DOWNLOADS_DIR=/downloads -e WORK=/work -e OUT=/out
      -v "$DOWNLOADS_DIR":/downloads
      -v "$OUTDIR":/out
      -v "$REPO_ROOT/versions":/versions:ro)
    if [ "$WORKCACHE" -eq 1 ]; then
      mkdir -p "$REPO_ROOT/work/deb"
      RUN_ARGS+=(-v "$REPO_ROOT/work/deb":/work)
      echo "已启用构建缓存挂载: work/deb(增量构建)"
    fi
    if [ "$SHELL_MODE" -eq 1 ]; then
      exec docker run -it "${NET_ARGS[@]}" "${PROXY_RUN_ARGS[@]}" \
        --entrypoint bash "${RUN_ARGS[@]}" "$IMAGE"
    fi
    docker run "${NET_ARGS[@]}" "${PROXY_RUN_ARGS[@]}" "${RUN_ARGS[@]}" "$IMAGE"

    # ------------------------------------------------ 彩排:原生基底容器演练安装升级
    if [ "$REHEARSAL" -eq 1 ]; then
      run_rehearsal deb
    else
      echo "已跳过彩排(--no-rehearsal):产物未经安装升级演练验证"
    fi
    ;;

  rpm)
    OUTDIR="$OUTROOT/rpm/${OPENSSH_VER}-${RPM_RELEASE}"
    IMAGE="${RPM_IMAGE_TAG:-openssh-rpm-builder:latest}"
    image_extra=()
    [ -n "$DNF_MIRROR" ] && image_extra+=(--build-arg "DNF_MIRROR=$DNF_MIRROR")
    build_toolchain_image rpm/Dockerfile "$IMAGE" "$RPM_BASE" "${image_extra[@]}"

    mkdir -p "$OUTDIR"
    RUN_ARGS=(--rm
      -e "OPENSSH_VERSION=$VERSION" -e VERSIONS_DIR=/versions
      -e "RPM_RELEASE=$RPM_RELEASE"
      -e "GLIBC_MAX=${GLIBC_MAX:-2.28}"
      -e DOWNLOADS_DIR=/downloads -e WORK=/work -e OUT=/out
      -v "$DOWNLOADS_DIR":/downloads
      -v "$OUTDIR":/out
      -v "$REPO_ROOT/versions":/versions:ro)
    if [ "$WORKCACHE" -eq 1 ]; then
      mkdir -p "$REPO_ROOT/work/rpm"
      RUN_ARGS+=(-v "$REPO_ROOT/work/rpm":/work)
      echo "已启用构建缓存挂载: work/rpm(增量构建)"
    fi
    if [ "$SHELL_MODE" -eq 1 ]; then
      exec docker run -it "${NET_ARGS[@]}" "${PROXY_RUN_ARGS[@]}" \
        --entrypoint bash "${RUN_ARGS[@]}" "$IMAGE"
    fi
    docker run "${NET_ARGS[@]}" "${PROXY_RUN_ARGS[@]}" "${RUN_ARGS[@]}" "$IMAGE"

    # ------------------------------------------------ 彩排:原生基底容器演练安装升级
    if [ "$REHEARSAL" -eq 1 ]; then
      run_rehearsal rpm
    else
      echo "已跳过彩排(--no-rehearsal):产物未经安装升级演练验证"
    fi
    ;;
esac

# 非根用户时把容器内 root 属主的产物归还给调用者
if [ "$(id -u)" != 0 ]; then
  docker run --rm -v "$OUTDIR":/out --entrypoint chown "$IMAGE" \
    -R "$(id -u):$(id -g)" /out >/dev/null 2>&1 || \
    echo "提示: 产物属主为 root,可手工: sudo chown -R $(id -u):$(id -g) $OUTDIR"
  docker run --rm -v "$DOWNLOADS_DIR":/d --entrypoint chown "$IMAGE" \
    -R "$(id -u):$(id -g)" /d >/dev/null 2>&1 || true
fi

log "完成: $FORMAT ${OPENSSH_VER}(产物目录 $OUTDIR)"
ls -la "$OUTDIR"
if [ -f "$OUTDIR/sha256.txt" ]; then cat "$OUTDIR/sha256.txt"; fi
