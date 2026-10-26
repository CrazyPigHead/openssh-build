# OpenSSH 构建工具(openssh-build)

通用的 OpenSSH **rpm / deb 容器化构建工具**:在一个工具链镜像里完成
源码校验 → 静态依赖编译 → OpenSSH 编译 → 打包 → 字节级校验 →
(rpm/deb)安装升级彩排,支持通过版本配置文件构建**不同版本的 OpenSSH**。

- **产物形态**
  - deb:三个包 `openssh-client` / `openssh-server` / `openssh-sftp-server`
    (Ubuntu 20.04 基底,glibc 2.31 向前兼容 20.04 ~ 26.04,仅 amd64)
  - rpm:三个包 `openssh` / `openssh-clients` / `openssh-server`
    (Rocky 8 基底,glibc 2.28,默认面向 Kylin V10 Lance,仅 x86_64)
- **链接策略**:加密/压缩栈全部**静态内嵌**(OpenSSL libcrypto、zlib、libcbor、
  libfido2、libedit、libtinfo),安装后不依赖系统对应运行库;仅动态依赖
  glibc、PAM、audit、selinux、crypt 等必装基础库
- **安全**:OpenSSH tarball 经 PGP 验签(发布密钥指纹固定),其余依赖
  SHA256 固定校验;版本与校验值集中在 `versions/` 下

## 快速开始

```bash
./build.sh deb                  # 构建默认版本(10.5p1)三个 deb 并自动跑安装升级彩排验证
./build.sh rpm                  # 构建 rpm 并自动跑安装升级彩排验证

# 或用 make
make deb
make rpm
```

产物落在 `out/<格式>/<OpenSSH版本>-<revision>/`(附 `sha256.txt` 与
rpm 的 `requires.txt`)。首次构建约 5 ~ 15 分钟(含镜像内编译全部静态依赖),
其后命中层缓存秒级完成。

## 目录结构

```
openssh-build/
├── build.sh            顶层构建入口(编排 docker build/run、代理、彩排)
├── Makefile            便捷入口(make deb / make rpm / make fetch)
├── versions/           版本组合与校验值(每个版本一个 .env,新增版本只加文件)
│   └── 10.5p1.env
├── common/
│   ├── common.sh       共享库:版本加载、物料下载(curl 重试)、PGP/SHA256 校验
│   ├── rocky-mirrors.sh  Rocky 8 dnf 换源 + 镜像回退安装(构建/彩排共用)
│   └── ubuntu-mirrors.sh  Ubuntu apt 换源 + 镜像回退安装(deb 彩排用)
├── deb/                deb 构建模块(详见 deb/README.md)
│   ├── Dockerfile      工具链镜像(ubuntu:20.04,不含源码与版本)
│   ├── build.sh        容器内全流程:物料→静态依赖→OpenSSH→冒烟→打包→终验
│   └── rehearsal.sh    彩排:原生基底容器 apt 升级 + 端到端验证
├── rpm/                rpm 构建模块(详见 rpm/README.md)
│   ├── Dockerfile      工具链镜像(rockylinux:8,不含源码与版本)
│   ├── build.sh        容器内:物料→生成 spec→rpmbuild→字节级校验
│   ├── openssh.spec.in spec 模板(版本占位符 + 拆分二进制自适应)
│   ├── rehearsal.sh    彩排:原生包上 rpm -Uvh 升级 + 端到端验证
│   └── SOURCES/        打包资产(sshd.service / pam / ssh_config / sshd_config)
├── downloads/          物料缓存:自动下载落盘于此;预放物料即可离线构建
├── work/               构建缓存(--cache 时挂载进容器做增量构建)
├── out/                产物输出(out/archive/ 为历史归档)
├── scripts/            目标机一键安装工具(自动识别 deb/rpm 系、版本门禁、保留现有配置)
└── docs/               历史文档(构建纪要、handoff、上游调研)
```

## 物料(源码)获取方式

**默认:自动下载**。构建容器内发现 `downloads/` 缺某物料即从官方源下载
(带重试),下载后与本地物料走完全相同的校验流程;下载结果持久化在宿主
`downloads/`,下次构建直接复用。

**离线:预置/挂载物料**。把官方原始 tarball 放入 `downloads/`(文件名须与
`versions/*.env` 中版本对应,规范名参见 `common/common.sh` 的 fetch 列表;
OpenSSH 需同时放 `openssh-<版本>.tar.gz`、`.asc` 与 `RELEASE_KEY.asc`),
构建全程零外网。`downloads/` 本身就是以挂载形式注入容器的,自备物料目录
可用 `--downloads <目录>` 指定。

```bash
./build.sh fetch --version 10.5p1   # 或先在有网环境预下载物料
./build.sh deb --version 10.5p1     # 之后可断网构建
```

## 网络代理

构建需要访问:基底镜像仓库(可用 `DOCKER_REGISTRY_MIRROR` 走镜像仓)、
发行版软件源(apt/dnf)、上游源码站点(cdn.openbsd.org / github.com 等)。

```bash
# 方式一:自动透传宿主代理环境变量(推荐)
export http_proxy=http://127.0.0.1:1090 https_proxy=http://127.0.0.1:1090
./build.sh deb

# 方式二:显式注入(推荐在有残留代理变量的环境使用)
./build.sh deb --proxy http://10.0.0.8:3128

# 不想透传时
./build.sh deb --no-proxy
```

`--proxy <url>` 会在**本次构建进程内**归一化代理变量(不改宿主 shell
环境):以给定 URL 统一小写 `http_proxy/https_proxy`,并清除宿主环境
残留的 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY` 等变体 —— 大写
`HTTP_PROXY/HTTPS_PROXY` 会被透传进 bridge 容器,残留的回环地址在其中
不可达,容器内 curl/git 等读到即失败;`ALL_PROXY` 不透传,但残留会
干扰宿主侧 `fetch` 的物料下载。`no_proxy` 以小写为准(未设置时默认
`localhost,127.0.0.1,::1`,已有则保留、大写 `NO_PROXY` 值会被继承)。
`--no-proxy` 清除全部代理变量。

代理指向本机回环地址(127.0.0.1/localhost/::1)时,构建容器自动附加
`--network=host` 以访问宿主代理(大小写与 `ALL_PROXY` 变体均参与检测);
`--network` 可强制覆盖。

**稳定性**:apt/dnf 与物料下载均自带重试(deb 工具链镜像 apt 配置
`Acquire::Retries=3`,rpm 侧 `rocky_install` 为逐镜像回退 + 重试,物料
下载默认重试 8 次);代理偶发连接抖动可直接重跑构建。若代理短暂返回
损坏内容(apt 报 `invalid signature`),重跑即可恢复。内网直连环境
通常需要:

```bash
DOCKER_REGISTRY_MIRROR=docker.m.daocloud.io/library  # 默认值,基底镜像走镜像仓
APT_MIRROR=mirrors.tuna.tsinghua.edu.cn              # deb 工具链镜像/彩排 apt 换源
DNF_MIRROR=mirrors.ustc.edu.cn/rocky                 # rpm 工具链/彩排 dnf 换源
```

## 支持不同版本

版本组合(OpenSSH / OpenSSL / zlib / libcbor / libfido2 / libedit / ncurses)、
打包版本(deb revision / rpm release)与校验值全部集中在
`versions/<OpenSSH版本>.env`:

```bash
./build.sh --list-versions          # 查看可用版本
./build.sh deb --version <版本>      # 构建指定版本
./build.sh rpm --version <版本> --release 1.el8   # 换目标发行版标签
```

新增版本:`cp versions/10.5p1.env versions/<新版本>.env`,改版本号并填入新
物料 SHA256(OpenSSH 沿用 PGP 指纹),确认新 OpenSSL 与 OpenSSH 兼容
(上游 CI 矩阵)后即可构建。打包脚本对 `sshd-session`(9.8+)与
`sshd-auth`(9.9+)按源码树自适应,**OpenSSH ≥ 9.8 的版本均可尝试**;
更早版本未适配(二进制拆分与配置布局差异较大)。

更换 rpm 目标发行版时,同步调整 `RPM_RELEASE` 与 `GLIBC_MAX`(构建基底
glibc 决定产物符号上限,默认 2.28 对应 Rocky 8 / Kylin V10)。

## 质量门禁(每次构建自动执行)

| 阶段 | 内容 |
|---|---|
| 物料 | PGP 验签(OpenSSH,指纹固定)/ SHA256(其余依赖) |
| 构建 | 链接修正生效断言、`ssh -V` 版本一致性 |
| deb 冒烟 | 容器内回环登录、zlib 压缩、sftp 上传下载 |
| deb 终验 | 包内字节 `ldd` 无加密族动态依赖、`dpkg-deb` 元数据 |
| deb 彩排 | 全新基底容器:装原生 openssh → apt 本地事务升级(`--force-confold` 保留 conffile)→ 布局/密钥/conffile 保留断言 → UsePAM 公钥登录/压缩/外部+内部 sftp/scp/系统配置校验(`--no-rehearsal` 跳过) |
| rpm 校验 | 全 ELF `ldd` 无加密族、GLIBC 符号 ≤ 上限、包内 `ssh -V`、自动依赖清单 |
| rpm 彩排 | 全新基底容器:装原生 openssh → `rpm -Uvh` 升级 → 布局/软链/密钥断言 → UsePAM 公钥登录/压缩/外部+内部 sftp/scp/系统配置校验(`--no-rehearsal` 跳过) |

## 常用选项速查

```bash
./build.sh deb --cache              # 挂载 work/deb 增量构建(改脚本调试时提速)
./build.sh deb --no-rehearsal     # 只出包,不跑彩排(deb/rpm 均可)
./build.sh deb --shell              # 进入构建容器交互调试
./build.sh deb --out /tmp/o         # 指定产物目录
SKIP_OPENSSL_TEST=0 ./build.sh deb  # 容器内跑 OpenSSL 官方自测(默认跳过,见 deb/README.md)
```

## 安装产物

推荐用一键安装工具(自动识别 deb/rpm 系;已装版本不低于新包时提醒跳过;
非交互;系统带坏依赖时自动改走 dpkg 直装;保留现有配置;装后自动重启
sshd,无 systemd 环境自动跳过):

```bash
scripts/install_openssh.sh 10.6p1                    # 缺省依次找:脚本同目录 → out/<deb|rpm>/<版本>-*
scripts/install_openssh.sh 10.6p1 --dir /path/to/pkgs  # 离线场景:三包与脚本拷至同一目录
```

也可手工安装(deb 三包互相锁版本,须同事务安装;--force-confold 用于覆盖
官方包时保留原 sshd_config):

```bash
# deb(三包互相锁版本,须同事务安装;--force-confold 用于覆盖官方包时保留原 sshd_config)
apt install ./openssh-client_<v>_amd64.deb ./openssh-sftp-server_<v>_amd64.deb \
            ./openssh-server_<v>_amd64.deb

# rpm(三包放同目录同事务升级)
rpm -Uvh openssh-<v>.x86_64.rpm openssh-clients-<v>.x86_64.rpm openssh-server-<v>.x86_64.rpm
```

细节与已知注意点(升级兼容、Kylin 对齐设计、踩坑记录)见
[deb/README.md](deb/README.md) 与 [rpm/README.md](rpm/README.md)。
