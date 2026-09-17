# =============================================================================
# OpenSSH RPM 构建工具链镜像(Rocky Linux 8 基底,与 Kylin V10 同为 glibc 2.28)
#
# 仅安装构建依赖,不含任何源码/版本信息 —— 版本组合由运行期挂载的
# versions/ 注入,一个镜像可构建所有版本。
#
# 构建上下文为仓库根目录(由顶层 build.sh 编排,无需手工执行):
#   docker build -f rpm/Dockerfile -t openssh-rpm-builder .
#
# 可选构建参数:
#   --build-arg BASE_IMAGE=<镜像>     基底镜像(默认 rockylinux:8;
#                                     直连 Docker Hub 受限时可用镜像仓前缀)
#   --build-arg DNF_MIRROR=<host>     dnf 首选镜像(如 mirrors.aliyun.com/rockylinux)
#   --build-arg http_proxy=...        构建期 dnf 走代理(与 https_proxy 同)
#
# 实际构建在容器运行期发生(ENTRYPOINT),由顶层 build.sh 注入:
#   -v <downloads>:/downloads   物料缓存(缺失自动下载,已有直接复用)
#   -v <out>:/out               产物输出
#   -v <versions>:/versions:ro  版本配置
#   -e OPENSSH_VERSION / http_proxy 等
#
# 彩排验证(安装升级演练)由顶层 build.sh 在独立的原生基底容器中执行
# rpm/rehearsal.sh,不在本镜像内。
# =============================================================================
ARG BASE_IMAGE=rockylinux:8
FROM ${BASE_IMAGE}

# 代理仅作构建期 ARG(不落盘进镜像);Docker 客户端环境有代理时会自动透传
ARG http_proxy
ARG https_proxy
ARG no_proxy
ARG DNF_MIRROR=""

COPY common/rocky-mirrors.sh /usr/local/bin/rocky-mirrors.sh

# 构建依赖(镜像逐级回退 + 失败重试由 rocky_install 承担):
#   pkgconfig 必须显式安装:EL8 的 cmake 不依赖它,缺失时 openssh configure
#   走非 pkg-config 分支导致静态链接修正 sed 失配
#   gcc-c++ 供 libcbor 的 CMake 探测使用
RUN . /usr/local/bin/rocky-mirrors.sh && \
    rocky_install rpm-build gcc gcc-c++ make pkgconfig perl perl-IPC-Cmd \
        perl-Data-Dumper cmake gnupg2 cpio file binutils \
        pam-devel libselinux-devel audit-libs-devel libxcrypt-devel \
        systemd-devel

WORKDIR /work
COPY common/common.sh /opt/openssh-build/common/common.sh
COPY rpm/build.sh rpm/openssh.spec.in /opt/openssh-build/rpm/
COPY rpm/SOURCES/ /opt/openssh-build/rpm/SOURCES/

ENTRYPOINT ["bash", "/opt/openssh-build/rpm/build.sh"]
