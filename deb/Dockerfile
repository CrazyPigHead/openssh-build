# =============================================================================
# OpenSSH deb 构建工具链镜像(Ubuntu 20.04 基底)
#
# 仅安装构建依赖,不含任何源码/版本信息 —— 版本组合由运行期挂载的
# versions/ 注入,一个镜像可构建所有版本。
#
# 构建上下文为仓库根目录(由顶层 build.sh 编排,无需手工执行):
#   docker build -f deb/Dockerfile -t openssh-deb-builder .
#
# 可选构建参数:
#   --build-arg BASE_IMAGE=<镜像>     基底镜像(默认 ubuntu:20.04;
#                                     直连 Docker Hub 受限时可用镜像仓前缀)
#   --build-arg APT_MIRROR=<host>     apt 换源(如 mirrors.tuna.tsinghua.edu.cn)
#   --build-arg http_proxy=...        构建期 apt 走代理(与 https_proxy 同)
#
# 选择 Ubuntu 20.04 作构建基底是为了 glibc(2.31)向前兼容:产物可装在
# 20.04 及之后的所有 Ubuntu 上(22.04/24.04/26.04 已实测)。
# focal 自带 cmake 3.16 满足 libcbor(>=3.5)/libfido2(>=3.7)。
#
# 实际构建在容器运行期发生(ENTRYPOINT),由顶层 build.sh 注入:
#   -v <downloads>:/downloads   物料缓存(缺失自动下载,已有直接复用)
#   -v <out>:/out               产物输出
#   -v <versions>:/versions:ro  版本配置
#   -e OPENSSH_VERSION / http_proxy 等
# =============================================================================
ARG BASE_IMAGE=ubuntu:20.04
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG APT_MIRROR=""
# 代理仅作构建期 ARG(不落盘进镜像);Docker 客户端环境有代理时会自动透传
ARG http_proxy
ARG https_proxy
ARG no_proxy

RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i "s|archive.ubuntu.com|${APT_MIRROR}|g; s|security.ubuntu.com|${APT_MIRROR}|g" \
            /etc/apt/sources.list; \
    fi && \
    # Acquire::Retries:代理链路偶发单包连接失败,apt 默认不重试即整层失败
    apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        build-essential ca-certificates curl gnupg perl xz-utils \
        pkg-config cmake file \
        libpam0g-dev libselinux1-dev libsepol1-dev libpcre2-dev \
        libaudit-dev libncurses-dev libcrypt-dev libudev-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY common/common.sh /opt/openssh-build/common/common.sh
COPY deb/build.sh /opt/openssh-build/deb/build.sh

ENTRYPOINT ["bash", "/opt/openssh-build/deb/build.sh"]
