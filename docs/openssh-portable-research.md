# OpenSSH Portable 调研:项目介绍、源码编译与 DEB/RPM 打包

> 调研日期:2026-08-28。全部结论基于一手资料(官网 openssh.com、官方 CDN、GitHub 官方镜像仓库文件、Debian/Fedora 官方打包仓库、官方 man 手册),关键结论后附行内来源链接;未能在一手资料中核实的说法均明确标注。
>
> 本地背景:本仓库旁边目录 `openssh-10.4p1-1/` 中已有一套此前按「Debian 官方打包」路线构建出的 `10.4p1-1~focal` 系列 DEB 包(openssh-client / openssh-server / openssh-common / openssh-sftp-server / openssh-client-gssapi / openssh-server-gssapi / ssh),本文针对该背景给出针对性建议。

---

## 目录

1. [项目介绍](#1-项目介绍)
2. [从源码编译(Linux x86_64)](#2-从源码编译linux-x86_64)
3. [DEB 打包(Debian/Ubuntu 路径)](#3-deb-打包debianubuntu-路径)
4. [RPM 打包(RHEL/Fedora/openSUSE 路径)](#4-rpm-打包rhelfedoraopensuse-路径)
5. [两条打包路径的对比与建议](#5-两条打包路径的对比与建议)
6. [主要一手资料索引](#6-主要一手资料索引)

---

## 1. 项目介绍

### 1.1 OpenSSH 是什么

OpenSSH 是 SSH 协议(version 2)的完整实现,用于安全的远程登录、命令执行和文件传输。官网称其为 "the premier connectivity tool for remote login with the SSH protocol",通过加密所有流量来防御窃听、连接劫持和 DNS/IP 欺骗。官方 release notes 中每版均重申:"OpenSSH is a 100% complete SSH protocol 2.0 implementation and includes sftp client and server support."

来源:[openssh.com 首页](https://www.openssh.com/)、[txt/release-10.5](https://www.openssh.com/txt/release-10.5)、[GitHub README.md](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.md)

### 1.2 OpenSSH Portable("p" 版)与 OpenBSD 原版的关系

- **开发模式**:OpenSSH 的"原生"开发在 OpenBSD 源码树中进行,产出一个小而纯净的 OpenBSD 版本;portable 团队在此基础上叠加可移植性代码,使其能运行在其他 Unix 类系统上。官网原文:"Normal OpenSSH development produces a very small, secure, and easy to maintain version for the OpenBSD project... [the portable team] takes that pure version and adds portability code so that OpenSSH can run on many other operating systems."
- **为什么需要 portable 版**:因为 OpenSSH 负责认证,会碰到大量 Unix 系统间差异——"since OpenSSH does authentication, it runs into a *lot* of differences between Unix operating systems."
- **可移植性层的实现**:源码树中的 `openbsd-compat/` 目录即为兼容层;README.md 描述:"Portable OpenSSH polyfills OpenBSD APIs that are not available elsewhere, adds sshd sandboxing for more operating systems and includes support for OS-native authentication and auditing (e.g. using PAM)."
- **版本命名规则**:portable 版本带 `p` 后缀,例如 `10.5p1`;官网原文:"Portable releases are marked with a 'p' (e.g. 4.0p1)",而 OpenBSD 官方源码 "will never use the 'p' suffix"。即 `10.5p1` 表示基于 OpenSSH 10.5 的第 1 个 portable 发布。portable 版跟随官方开发但发布不同步("follows development of the official version, but releases are not synchronized")。
- **支持的系统**:官网列有 Linux、Solaris、AIX、HP-UX、macOS、Cygwin 等;README.md 表述为 "most Unix-like operating systems, including Linux, OS X and Cygwin"。
- **上游组织**:开发归属 OpenBSD 项目;portable 侧的开发资源托管在 mindrot:git 镜像 [anongit.mindrot.org/openssh.git](https://anongit.mindrot.org/openssh.git)、[GitHub 官方镜像 openssh/openssh-portable](https://github.com/openssh/openssh-portable)、邮件列表 [openssh-unix-dev@lists.mindrot.org](https://lists.mindrot.org/mailman/listinfo/openssh-unix-dev)、Bug 跟踪 [bugzilla.mindrot.org](https://bugzilla.mindrot.org/)。捐赠通过 OpenBSD Foundation 接受。

来源:[openssh.com/portable.html](https://www.openssh.com/portable.html)、[README.md](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.md)、[openssh.com 首页](https://www.openssh.com/)

### 1.3 许可证

仓库根目录的 `LICENCE` 文件明确:"all components are under a BSD licence, or a licence more free than that. OpenSSH contains no GPL code."(部分历史代码为公共领域/更宽松许可,详见该文件逐条列出。)

来源:[LICENCE](https://raw.githubusercontent.com/openssh/openssh-portable/master/LICENCE)、[openssh.com 首页](https://www.openssh.com/)("made available under a BSD-style license")

### 1.4 组成组件

README.md:"It includes a client `ssh` and server `sshd`, file transfer utilities `scp` and `sftp` as well as tools for key generation (`ssh-keygen`), run-time key storage (`ssh-agent`) and a number of supporting programs." 结合仓库源码文件与手册页,完整组件包括:

| 组件 | 作用 |
|---|---|
| `ssh(1)` | 客户端 |
| `sshd(8)` | 服务端监听进程 |
| `scp(1)` / `sftp(1)` | 文件传输客户端 |
| `sftp-server(8)` | SFTP 服务端(含 `internal-sftp`) |
| `ssh-agent(1)` / `ssh-add(1)` | 密钥代理与加载工具 |
| `ssh-keygen(1)` | 密钥生成、证书签发、KRL 等 |
| `ssh-keyscan(8)` | 主机公钥收集 |
| `ssh-keysign(8)` | 主机认证签名辅助 |
| `ssh-sk-helper(8)` | FIDO 硬件密钥辅助进程 |
| `ssh-pkcs11-helper(8)` | PKCS#11 辅助进程 |
| `sshd-session` / `sshd-auth` | 10.0 起 sshd 拆分出的每连接会话与预认证进程(见 1.5) |
| `ssh-copy-id(1)` | contrib/ 中的实用脚本 |

来源:[README.md](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.md)、[README.privsep](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.privsep)、[仓库文件列表](https://github.com/openssh/openssh-portable)

### 1.5 当前最新稳定版本与最近大版本要点

**截至 2026-08-28,官网首页与官方 CDN 显示最新稳定版为 OpenSSH 10.5(portable 版 `10.5p1`),发布于 2026-08-11**(本机此前构建的 10.4p1 已被取代)。官方 CDN 目录中已存在 `openssh-10.5p1.tar.gz`。

版本时间线与要点(均摘自官方 release notes 全文):

| 版本 | 发布日期 | 要点 |
|---|---|---|
| [10.0](https://www.openssh.com/txt/release-10.0) | 2025-04-09 | **默认启用混合后量子密钥交换 `mlkem768x25519-sha256`**("considered to be safe against attack by quantum computers... considerably faster than the previous default");客户端默认优先 AES-GCM 而非 AES-CTR;**彻底移除 DSA** 签名算法;将用户认证阶段代码从 `sshd-session` 拆分到新的 **`sshd-auth`** 二进制(预认证攻击面完全隔离,发行版需打包 sshd-auth);sshd 端默认禁用有限域(modp)Diffie-Hellman KEX;版本字符串变为 `SSH-2.0-OpenSSH_10.0` |
| [10.1](https://www.openssh.com/txt/release-10.1) | 2025-10-06 | 客户端在协商到**非后量子** KEX 算法时发出警告(防 "store now, decrypt later",由新选项 `WarnWeakCrypto` 控制);预告未来弃用 SHA1 SSHFP 记录;DSCP/IPQoS 处理大改 |
| [10.2](https://www.openssh.com/txt/release-10.2) | 2025-10-10 | bugfix 版,主要修复 ControlPersist 导致会话不可用等问题 |
| [10.3](https://www.openssh.com/txt/release-10.3) | 2026-04-02 | 移除对不支持 rekey 的实现的 bug 兼容;修复证书空 `principals` 被当通配符的安全隐患;多项安全修复 |
| [10.4](https://www.openssh.com/txt/release-10.4) | 2026-07-06 | 多项安全修复(sftp 下载路径、scp 远程到远程写父目录、GSSAPI 预认证 DoS 等);`sshd -G` 输出改混合大小写;Linux 上 seccomp 沙箱启用失败由警告变为 fatal;新增实验性 **ML-DSA 44 + Ed25519 复合后量子签名** |
| [10.5](https://www.openssh.com/txt/release-10.5) | 2026-08-11 | 安全修复:ssh-agent 锁定与 `session-bind@openssh.com` 扩展交互缺陷(锁定时拒绝绑定导致本应受限本地的操作可被远程执行)、客户端远程转发 realloc UAF 等;**不兼容变化:libcrypto 必须支持 ECC(含 NISTP521 曲线)**(`--without-openssl` 构建不受影响);`ssh -Z` 新特性等 |

来源:[openssh.com 首页](https://www.openssh.com/)、[releasenotes.html](https://www.openssh.com/releasenotes.html)、[CDN 目录](https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/)

### 1.6 安全维护风格与发布节奏

- **安全报告渠道**:仓库 [SECURITY.md](https://raw.githubusercontent.com/openssh/openssh-portable/master/SECURITY.md) 指向 [openssh.com/security.html](https://www.openssh.com/security.html);README.md 要求安全漏洞直接报告至 openssh@openssh.com(非安全问题走 Bugzilla / 邮件列表)。
- **代码质量基础设施**:README.md 顶部徽章显示项目接入 GitHub Actions CI(C/C++、VM 矩阵,覆盖 Ubuntu/macOS/Windows-Cygwin 及大量 OpenSSL/LibreSSL 版本组合)、OSS-Fuzz、Coverity、CIFuzz。
- **发布节奏**:从已核实的日期看,近年大体为"春季一个功能大版本(x.0/x.2)+ 秋季一个版本"的节奏;**10.5 的 release notes 明确声明**:由于收到大量(含 AI 辅助发现的)安全报告,"the OpenSSH team will, for now, be making more frequent releases to get bugfixes into users' hands more quickly rather than batching them until the next planned release"——事实上 10.4(2026-07-06)与 10.5(2026-08-11)仅间隔约 5 周。每个版本发布时同步提供 portable tarball 及相对 OpenBSD 源码的 diff(`openssh-10.5p1-vs-openbsd.diff.gz`)。

来源:[txt/release-10.5](https://www.openssh.com/txt/release-10.5)、[README.md](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.md)、[CDN 目录](https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/)

---

## 2. 从源码编译(Linux x86_64)

> 构建系统为 **autoconf + make**。注意:上游仓库(master 与 V_10_5 分支均核实)**不存在 `CMakeLists.txt`**——"OpenSSH Portable 提供 CMake 构建"这一说法未在一手资料中核实。

### 2.1 获取源码

**方式一:官方 tarball(推荐,README.md:"We recommend the use of a stable release for most users")**

官方 CDN 目录:<https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/>(完整 [mirror 列表](https://www.openssh.com/portable.html#downloads) 另有 cloudflare.cdn.openbsd.org、ftp.openbsd.org、mirror.leaseweb.com 等;历史版本在 `old/` 子目录)。

```bash
VER=10.5p1
BASE=https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable
curl -LO "$BASE/openssh-$VER.tar.gz"
curl -LO "$BASE/openssh-$VER.tar.gz.asc"          # PGP 签名(注意后缀是 .asc)
curl -LO "$BASE/RELEASE_KEY.asc"                  # 发布公钥
```

**签名验证**(portable.html 原文:发布文件使用 PGP 签名,公钥为 ftp 站上的 `RELEASE_KEY.asc`,指纹 `7168B983815A5EEF59A4ADFD2A3F414E736060BA`):

```bash
gpg --import RELEASE_KEY.asc
gpg --verify openssh-$VER.tar.gz.asc openssh-$VER.tar.gz
# 确认输出中的主指纹为 7168B983815A5EEF59A4ADFD2A3F414E736060BA
```

说明:官方目录中**未提供**独立的 SHA256 摘要清单文件(已核实目录列表,只有 `ChangeLog`、`UPGRADING`、`INSTALL`、`README`、`TODO`、`old/` 等);官方推荐的完整性验证方式是上述 PGP 签名。

来源:[openssh.com/portable.html](https://www.openssh.com/portable.html)、[CDN 目录](https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/)、[RELEASE_KEY.asc](https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/RELEASE_KEY.asc)

**方式二:git(官方镜像)**

```bash
git clone https://github.com/openssh/openssh-portable   # 官方 GitHub 镜像(README.md 原文)
# 或
git clone https://anongit.mindrot.org/openssh.git        # mindrot 官方匿名 git(portable.html 原文)
```

注意两点(README.md "Building from git"):

- git 主分支**不含预生成的 `configure`**,需先 `autoreconf`(要求 autoconf 2.69、automake 1.16.1 或更新,见 INSTALL);
- release 分支/tag 形如 `V_10_5`(已核实该分支存在),其行为与 tarball 一致,自带 `configure`。

### 2.2 构建依赖

**上游声明(README.md + INSTALL,一手原文要点)**:

| 依赖 | 要求 |
|---|---|
| C 编译器 | "A working C compiler, standard library and headers"(C89 或更好、支持 variadic macros) |
| libcrypto | LibreSSL ≥ 3.1.0 / **OpenSSL ≥ 1.1.1**(configure.ac 中硬性检查:`OpenSSL >= 1.1.1 required`)/ AWS-LC / BoringSSL。**可以完全不用 libcrypto 构建**,但 "the resulting binaries will have only a subset of the cryptographic algorithms normally available"(`--without-openssl`)。**10.5 起新增要求:libcrypto 必须支持 ECC 且含 NISTP521 曲线**(默认构建的所有受支持 libcrypto 版本均满足;`--without-openssl` 构建不受影响) |
| zlib | 可选;不装则不支持传输压缩(`--without-zlib` / Compression 选项禁用) |
| libfido2 | 可选;FIDO 硬件密钥支持,自动检测启用,依赖 libcbor,推荐 ≥ 1.5.0 |
| autoconf/automake | 仅 git 构建需要(tarball 自带 configure) |

来源:[README.md](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.md)、[INSTALL](https://raw.githubusercontent.com/openssh/openssh-portable/master/INSTALL)、[configure.ac](https://raw.githubusercontent.com/openssh/openssh-portable/master/configure.ac)、[txt/release-10.5](https://www.openssh.com/txt/release-10.5)

**Debian / Ubuntu 软件包**(包名依据上游官方 CI 脚本 [.github/setup_ci.sh](https://raw.githubusercontent.com/openssh/openssh-portable/master/.github/setup_ci.sh):其中明确列出 `libpam0g-dev`、`libedit-dev`、`libselinux1-dev selinux-policy-dev libaudit-dev`、`libfido2-dev libu2f-host-dev libcbor-dev`、`libkrb5-dev`;`build-essential`/`zlib1g-dev`/`libssl-dev`/`autoconf`/`automake` 为对应上游依赖的常规 Debian 包名,CI runner 上系预装故未逐条出现):

```bash
sudo apt update
sudo apt install -y build-essential autoconf automake \
    zlib1g-dev libssl-dev libcrypt-dev \
    libpam0g-dev libedit-dev \
    libselinux1-dev selinux-policy-dev libaudit-dev \
    libfido2-dev libcbor-dev \
    libkrb5-dev          # 仅在 --with-kerberos5 时需要
```

**RHEL / Fedora / CentOS Stream 软件包**(对应同一组上游依赖的 RHEL 命名;上游 CI 未直接在 RHEL 上运行,RHEL 包名清单未在上游一手资料中直接给出——已核实上游 CI 的包管理器使用与 RHEL 相同的 `*-devel` 命名风格):

```bash
sudo dnf install -y gcc make autoconf automake \
    openssl-devel zlib-devel \
    pam-devel libedit-devel \
    libselinux-devel libaudit-devel \
    libfido2-devel \
    krb5-devel            # 仅在 --with-kerberos5 时需要
```

### 2.3 标准构建流程(INSTALL 第 2 节 "Building / Installation")

INSTALL 给出的最小流程是 `./configure && make && make install`,默认安装到 `/usr/local/{bin,etc,sbin}`;并演示了 `--prefix=/opt`、`--sysconfdir=/etc/ssh` 的用法。结合 README.md 的构建说明:

```bash
# --- 从 release tarball(自带 configure)---
tar zxvf openssh-10.5p1.tar.gz
cd openssh-10.5p1

# --- 或从 git ---
# git clone https://github.com/openssh/openssh-portable && cd openssh-portable && autoreconf

./configure \
  --prefix=/usr/local \
  --sysconfdir=/etc/ssh \
  --with-pam \
  --with-libedit \
  --with-selinux \
  --with-privsep-path=/var/empty \
  --with-privsep-user=sshd

make            # 构建
make tests      # 可选:运行回归测试(README.md: "make && make tests")
sudo make install
```

**当前 master `configure.ac` 中的关键选项**(以下选项名已逐一从 [configure.ac](https://raw.githubusercontent.com/openssh/openssh-portable/master/configure.ac) 核实存在;上述选项在 10.x 中均未被移除或改名):

| 选项 | 说明(依据 configure.ac 帮助文本 / INSTALL / README.md) |
|---|---|
| `--prefix=PREFIX` / `--sysconfdir=DIR` | 标准安装路径选项(INSTALL:配置文件默认装到 `${prefix}/etc`,即 `/usr/local/etc`) |
| `--with-pam` | 启用 PAM 支持(OpenPAM / Linux PAM / Solaris PAM);编译入后还需在 sshd_config 开启 `UsePAM` |
| `--with-pam-service=NAME` | 指定 PAM 服务名 |
| `--with-libedit` | 为 sftp 启用命令行编辑(INSTALL:使用 NetBSD libedit) |
| `--with-selinux` | 启用 SELinux 支持 |
| `--with-kerberos5` | 启用 Kerberos/GSSAPI(Heimdal 或 MIT) |
| `--with-privsep-path=PATH` | privilege separation 的 chroot 目录,**默认 `/var/empty`** |
| `--with-privsep-user=USER` | 预认证阶段降权使用的用户,**默认 `sshd`**(Cygwin 除外) |
| `--with-sandbox=STYLE` | sshd-auth 沙箱实现:`no` / `capsicum` / `darwin` / `rlimit` / `seccomp_filter`;多数平台自动检测,主要用于显式禁用 |
| `--with-ssl-dir=DIR` | 指定 Libre/OpenSSL 安装位置 |
| `--with-ssl-engine` | 启用 libcrypto 硬件 ENGINE 支持 |
| `--without-openssl` | 完全不使用 OpenSSL 构建,仅保留部分算法 |
| `--with-security-key-builtin` | 将 FIDO 支持内建到 ssh 中(而非默认的 ssh-sk-helper 独立进程) |
| `--with-pid-dir=PATH` | sshd.pid 所在目录 |
| `--with-default-path=PATH` | sshd 会话的默认 $PATH |
| `--with-audit=MODULE` | 审计模块(debug / bsm) |
| `--with-ldns` | DNSSEC 相关(自建 ldns) |

其他还有 `--without-zlib`、`--with-pie`、`--without-hardening`、`--without-stackprotect`、`--disable-utmp/utmpx/wtmp/lastlog` 等平台性选项,完整列表以 `./configure --help` 为准。若需传编译/链接参数,INSTALL 给出示例:`CC="..." CFLAGS="-O" LDFLAGS="-s" LIBS="-lrubbish" ./configure`。

来源:[INSTALL](https://raw.githubusercontent.com/openssh/openssh-portable/master/INSTALL)、[README.md](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.md)、[configure.ac](https://raw.githubusercontent.com/openssh/openssh-portable/master/configure.ac)

### 2.4 安装前置条件:privsep 用户与目录、host key

INSTALL 明确:"To support Privilege Separation (which is now required) you will need to create the user, group and directory used by sshd for privilege separation. See README.privsep for details."(特权分离现为**必需**。)

[README.privsep](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.privsep) 给出的准备命令(原文):

```bash
mkdir /var/empty
chown root:sys /var/empty
chmod 755 /var/empty
groupadd sshd
useradd -g sshd -c 'sshd privsep' -d /var/empty -s /bin/false sshd
```

要求:该用户不得与其他服务共用、不拥有文件、密码锁定、shell 为 `/bin/nologin` 或 `/bin/false`、home 指向 privsep 目录;`/var/empty` 应为空、其他账户不可读写。若发行版已有 `sshd` 用户与 `/var/empty`(或想用别的前缀),用 `--with-privsep-user` / `--with-privsep-path` 匹配即可。

**Host key 生成**(INSTALL 第 3 节):

```bash
sudo make host-key        # 或手动:
sudo /usr/local/bin/ssh-keygen -A    # 为所有支持的类型生成密钥(写入 --sysconfdir 指定目录)
```

关于 `/run/sshd`:上游 README.privsep 的默认 privsep 路径是 `/var/empty`;**上游一手资料(README.privsep / INSTALL)未提及 `/run/sshd`**——该目录是 Debian 等发行版打包时的选择(Debian 打包用 `--with-privsep-path=/run/sshd`,见 3.1),此说法未在上游一手资料中核实。

**PAM 配置文件**(INSTALL 第 2 节):若启用 `--with-pam`,需手动安装 PAM 控制文件到 `/etc/pam.d/sshd`(服务名为 sshd 可执行文件的 basename);通用模板在 `contrib/sshd.pam.generic`,Red Hat 系参考 `contrib/redhat/sshd.pam`。INSTALL 警告:"Failure to install a valid PAM file may result in an inability to use password authentication."

来源:[INSTALL](https://raw.githubusercontent.com/openssh/openssh-portable/master/INSTALL)、[README.privsep](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.privsep)、[contrib/README](https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/README)

### 2.5 systemd 服务文件的来源(重要澄清)

**上游不提供 systemd 单元文件。** 已核实(GitHub API,2026-08-28):

- master 分支与 `V_10_5` 分支的 `contrib/` 目录内容均为:`aix/`、`cygwin/`、`hpux/`、`redhat/`、`suse/`、`solaris/`、`findssl.sh`、`gnome-ssh-askpass[1234].c`、`Makefile`、`README`、`ssh-copy-id`、`ssh-copy-id.1`、`sshd.pam.freebsd`、`sshd.pam.generic`——**没有 `contrib/systemd/`,也没有任何 `.service` 文件**;[contrib/README](https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/README) 亦未提及 systemd。
- 上游在仓库根目录提供的进程管理脚本是 SysV 风格的 **`opensshd.init.in`**(configure 生成 `opensshd.init`,处理 start/stop/状态与 PID 文件)和 Solaris SMF 清单 **`openssh.xml.in`**。

因此若需要 systemd 管理,惯常做法是使用发行版提供的单元(如 Debian `openssh-server` 包的 `ssh.service`/`sshd.service`),或自行编写指向所安装 sshd 路径的单元(此为通行实践,非上游文档内容)。

来源:[contrib 目录列表(GitHub API)](https://github.com/openssh/openssh-portable/tree/master/contrib)、[opensshd.init.in](https://raw.githubusercontent.com/openssh/openssh-portable/master/opensshd.init.in)

### 2.6 常见坑与路径建议

1. **不要覆盖发行版的 OpenSSH**。INSTALL 的默认安装位置是 `/usr/local/{bin,etc,sbin}`,与发行版包(`/usr/bin`、`/usr/sbin`、`/etc/ssh`)天然分离;若强行 `--prefix=/usr`,自编译文件会被后续发行版安全更新悄悄覆盖(或反之阻塞更新),且系统服务、man page、PATH 解析都会混乱。建议:
   - 测试/并存:保持默认 `/usr/local` 或用独立前缀如 `--prefix=/opt/openssh-10.5p1 --sysconfdir=/etc/ssh`(INSTALL 原文示例:`--prefix=/opt --sysconfdir=/etc/ssh` 将二进制装入 `/opt/{bin,lib,sbin}` 而配置在 `/etc/ssh`);
   - 替换系统 sshd:先停用发行版服务再接管,并意识到后续需自行跟踪上游安全更新(更稳妥的做法是直接打包,见第 3、4 章)。
2. **PAM 文件**:见 2.4,漏装会导致密码认证不可用(INSTALL 原文警告)。
3. **配置兼容性**:跨大版本升级前阅读 [releasenotes.html](https://www.openssh.com/releasenotes.html) 的 "Potentially-incompatible changes"(如 10.0 移除 DSA、10.4 的 `sshd -G` 输出变化)及 CDN 上的 [UPGRADING](https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/UPGRADING) 文件。
4. **10.0+ 的新二进制**:打包/部署脚本需包含 `sshd-session` 与 `sshd-auth`(10.0 release notes:"Downstream distributors of OpenSSH will need to package the sshd-auth binary")。
5. **libcrypto 需以 `-fPIC` 编译**:INSTALL 提示,若链接自编译的非位置无关 libcrypto,可能需要给 OpenSSH 配 `--without-pie`。
6. **git 构建忘跑 `autoreconf`** 会在 configure 阶段报错(README.md 已说明 git 主分支需 autoconf 生成 configure)。

### 2.7 使用自建 OpenSSL 静态内嵌 libcrypto 构建

**适用场景**:宿主系统的 libcrypto 太老(如 focal/bullseye 的 OpenSSL 1.1.1,虽仍满足上游 `>= 1.1.1` 的最低要求),但想用上 OpenSSL 3.x 的新算法与安全修复,且不想动系统 `libssl` 包;或需要产出运行时不依赖系统 libcrypto 的自包含 ssh/sshd 二进制。注意与 `--without-openssl` 区分:后者是完全不链接 libcrypto(仅剩部分算法,见 2.2 节),本节是**把一份新版 libcrypto 静态内嵌进二进制**。

#### 原理:让 `--with-ssl-dir` 指向只有 `.a` 没有 `.so` 的目录

OpenSSH 链接的是 `-lcrypto`,动态还是静态取决于链接时 `-L` 搜索路径先命中的库形态。上游 `configure.ac` 对 `--with-ssl-dir=PATH` 的处理逻辑(已核对源码):

- 存在 `$PATH/lib` → 库目录用 `$PATH/lib`;存在 `$PATH/lib64` → 用 `$PATH/lib64`;**两者都没有 → 把 `$PATH` 本身当作库目录**(configure.ac 注释原文 "Built but not installed",即可以直接指向未安装的 OpenSSL 构建树);
- 向 `LDFLAGS` 追加 `-L<库目录>`(仅在平台支持且未 `--without-rpath` 时附带 rpath 选项;**Linux 下默认只加 `-L` 不加 rpath**);
- 向 `CPPFLAGS` 追加 `-I$PATH/include`(不存在则 `-I$PATH`),头文件路径一并处理;
- 若 `$PATH/bin/openssl` 或 `$PATH/apps/openssl` 存在且可运行,则前置到 PATH 供构建期使用。

因此只要 `--with-ssl-dir` 指向的目录里**只有 `libcrypto.a`、没有 `libcrypto.so`**,configure 的链接测试与最终链接都会静态内嵌 OpenSSL。

来源:[configure.ac(--with-ssl-dir 实现)](https://raw.githubusercontent.com/openssh/openssh-portable/V_10_5/configure.ac)、[INSTALL](https://raw.githubusercontent.com/openssh/openssh-portable/V_10_5/INSTALL)

#### 关键约束:libcrypto 必须以 `-fPIC` 编译

上游 INSTALL 原文:"libcrypto should be compiled as a position-independent library (i.e. -fPIC, eg by configuring OpenSSL as `./config [options] -fPIC` ...) otherwise OpenSSH will not be able to link with it. If you must use a non-position-independent libcrypto, then you may need to configure OpenSSH `--without-pie`." OpenSSH 默认按 PIE + 默认加固编译,静态库同样必须自带位置无关代码;改用非 PIC libcrypto 就得放弃 PIE,失去 ASLR 加固,不建议。

来源:[INSTALL](https://raw.githubusercontent.com/openssh/openssh-portable/V_10_5/INSTALL)

#### 流程 A(推荐):OpenSSL 安装到独立前缀,只装静态库

```bash
# --- 1) 构建并安装静态版 OpenSSL(以 3.5 LTS 线为例,调研日当前补丁版 3.5.7)---
OSSL_VER=3.5.7
curl -LO "https://github.com/openssl/openssl/releases/download/openssl-${OSSL_VER}/openssl-${OSSL_VER}.tar.gz"
curl -LO "https://github.com/openssl/openssl/releases/download/openssl-${OSSL_VER}/openssl-${OSSL_VER}.tar.gz.asc"
tar xf openssl-${OSSL_VER}.tar.gz && cd openssl-${OSSL_VER}

# no-shared:只产 .a 不产 .so(OpenSSL INSTALL.md:"Do not create shared
#            libraries, only static ones");zlib:压缩支持;-fPIC:见上
./Configure no-shared zlib -fPIC \
    --prefix=/opt/openssl-${OSSL_VER} \
    --openssldir=/etc/ssl
make -j"$(nproc)"
make test        # OpenSSH INSTALL 原文强烈建议自建 libcrypto 先跑上游自测
sudo make install
# 产物:/opt/openssl-3.5.7/{include,lib/libcrypto.a,lib/libssl.a,...},无任何 .so

# --- 2) 构建 OpenSSH,指向该前缀 ---
cd ../openssh-10.5p1
./configure \
  --prefix=/opt/openssh-10.5p1 \
  --with-ssl-dir=/opt/openssl-${OSSL_VER} \
  --with-privsep-path=/var/empty --with-privsep-user=sshd \
  --with-pam --with-libedit            # 其余选项按需,同 2.3 节
make -j"$(nproc)"
make tests       # 可选
sudo make install
```

由于 `/opt/openssl-.../lib` 下只有 `libcrypto.a`,无需任何额外链接参数即完成静态内嵌。

#### 流程 B(免安装):直接指向 OpenSSL 构建树

OpenSSL 默认构建会把静态库生成在**构建树顶层**、头文件在构建树 `include/`(OpenSSL INSTALL.md:"The libraries will be built in the top-level directory"),配合上文 configure.ac "Built but not installed" 的回退逻辑,可以省掉 `make install`:

```bash
cd openssl-${OSSL_VER}          # 已 ./Configure no-shared zlib -fPIC && make
cd ../openssh-10.5p1
./configure --with-ssl-dir="$(cd ../openssl-${OSSL_VER} && pwd)" ...
```

注意:此方式下若 Configure 时**没有**加 `no-shared`,构建树顶层会同时出现 `libcrypto.so`,链接会退化为动态;且 Linux 下默认不加 rpath,运行时还要靠 `LD_LIBRARY_PATH` 指向构建树。要静态内嵌必须 `no-shared`。

#### 验证

```bash
/opt/openssh-10.5p1/bin/ssh -V
# 输出形如: OpenSSH_10.5p1, OpenSSL 3.5.7 ...   ← 编译期内嵌的 OpenSSL 版本号
ldd /opt/openssh-10.5p1/sbin/sshd | grep -iE 'crypto|ssl'   # 应无任何输出
ldd /opt/openssh-10.5p1/bin/ssh   | grep -iE 'crypto|ssl'   # 应无任何输出
```

#### 代价与注意事项

1. **安全更新责任转移**:系统 libssl 的 CVE 更新不会自动进入内嵌二进制,OpenSSL 出安全修复时必须重编 OpenSSH;反之升级也不受宿主 libssl 影响。
2. **不是"全静态二进制"**:本节只内嵌 libcrypto;zlib、libfido2、libpam 等其余依赖仍按 configure 检测结果动态链接(glibc ≥ 2.34 已把 pthread/dl 并入 libc,静态 libcrypto 一般无需再补 `-ldl -pthread`;老 glibc 上若报 `dlopen`/`pthread_*` 符号未定义,在 configure 时加 `LIBS="-ldl -pthread"`)。完全静态(含 libc)不在上游支持范围。
3. **不建议用 `-Wl,-Bstatic` 强制**: `-lcrypto` 由 configure 自行追加到链接命令,`LDFLAGS` 里的 `-Bstatic`/`-Bdynamic` 很难保证正确包裹它;让 `-L` 目录里只有 `.a` 才是可靠做法。
4. OpenSSL 源码与 `.asc` 签名统一从官方渠道获取:[openssl.org/source](https://www.openssl.org/source/) 页或 [GitHub 官方 releases](https://github.com/openssl/openssl/releases);许可无冲突(OpenSSH 为 BSD,OpenSSL 3.x 为 Apache-2.0,静态链接无额外义务)。

---

## 3. DEB 打包(Debian/Ubuntu 路径)

> 资料可达性说明:salsa.debian.org 对本机 IP 有防护,以下 Debian 打包内容均经 Debian 官方源码浏览服务 [sources.debian.org/src/openssh](https://sources.debian.org/src/openssh/) 核实(含 `/data/` 原始文件接口,内容与 salsa 仓库一致)。

### 3.1 Debian 官方打包结构与拆分逻辑

**源码包格式**。Debian 的 openssh 源码包采用 `3.0 (quilt)` 格式(已核实 [debian/source/format](https://sources.debian.org/src/openssh/1%3A10.4p1-5/debian/source/format/) 内容就是一行 `3.0 (quilt)`),即:上游 orig tarball(`openssh_10.4p1.orig.tar.gz`,可附 `.asc` 签名)+ `debian/` 目录打包为 `openssh_10.4p1-5.debian.tar.xz` + `openssh_10.4p1-5.dsc`。dpkg-source(1) 对该格式的定义:"A source package in this format consists either of a `.orig.tar.gz` associated to a `.diff.gz` or a single `.tar.gz`…Optionally the original tarball might be accompanied by a detached upstream signature `.orig.tar.gz.asc`"([dpkg-source(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/dpkg-source.1.html))。补丁放在 `debian/patches/`,由 `3.0 (quilt)` 格式在解包时自动应用。

**当前子包拆分(sid,`1:10.4p1-5`)**。从官方 [debian/control](https://sources.debian.org/src/openssh/1%3A10.4p1-5/debian/control/) 核实,源码包 `openssh` 产出 9 个二进制包:

| 二进制包 | 职责(来自 Description/Depends) |
|---|---|
| `openssh-common` | 公共文件;`openssh-client (<< 1:10.3p1-6~)` 对其 Breaks/Replaces |
| `openssh-client` | SSH 客户端(ssh/scp/ssh-keygen 等),`Provides: ssh-client`,`Recommends: xauth` |
| `openssh-server` | sshd;`Depends:` `openssh-common (= ${binary:Version})`、`openssh-sftp-server`、`libpam-modules`、`ucf`、`procps` 等;`Provides: ssh-server` |
| `openssh-sftp-server` | sftp-server 模块;`Enhances: openssh-server` |
| `openssh-tests` | 回归测试(配合 autopkgtest) |
| `ssh` | 元包,仅 `Depends: openssh-client (>= ${binary:Version}), openssh-server (>= ${binary:Version})` |
| `ssh-askpass-gnome` | GTK 图形口令提示(Build-Profile `<!pkg.openssh.nognome>` 可关) |
| `openssh-client-udeb` / `openssh-server-udeb` | debian-installer 专用微型包 |

**拆分逻辑**:server 与 client 分离以便最小化安装面;`openssh-sftp-server` 独立是历史演进(对 `<< 1:6.5p1-5` 的 server 有 Breaks/Replaces);各二进制包用 `${binary:Version}` 严格锁同版本;文档通过 `dh_installdocs --link-doc=openssh-common` 集中。

**与本机已有子包列表的对照(重要发现)**。`openssh-10.4p1-1/` 目录中的 `openssh-client-gssapi`、`openssh-server-gssapi` 恰好对应 Debian **2026-08 的新拆分**:[debian/changelog](https://sources.debian.org/data/main/o/openssh/1%3A10.4p1-5/debian/changelog) `1:10.4p1-5`(2026-08-23)条目原文:

> "Drop GSS-API authentication and key exchange support, to reduce pre-authentication attack surface. Users who need these features should install openssh-client-gssapi or openssh-server-gssapi instead."

即 GSSAPI 支持已从主源码包剥离到**独立源码包 [openssh-gssapi](https://sources.debian.org/src/openssh-gssapi/)**(`1:10.4p1-5`,sid),其 control 中定义了 `Package: openssh-client-gssapi`("secure shell (SSH) client, with GSS-API support")和 `Package: openssh-server-gssapi`("secure shell (SSH) server, with GSS-API key exchange")。历史对照(均已逐一核对 control 原文):Ubuntu xenial(`1:7.2p2`)、Debian wheezy(`1:6.0p1`)以来的官方打包均**无** gssapi 子包(GSSAPI 编译进主包,`ssh-krb5` 是过渡包);focal 官方打包 `1:8.2p1-4ubuntu0.13` 的 [control](https://git.launchpad.net/ubuntu/+source/openssh/plain/debian/control?h=applied/ubuntu/focal-updates) 亦无。

**debian/rules 要点**([rules](https://sources.debian.org/src/openssh/1%3A10.4p1-5/debian/rules/)):入口为 `dh $@ --with=runit`,out-of-tree 双构建(`debian/build-deb` 与 `debian/build-udeb`);关键 configure 参数:`--sysconfdir=/etc/ssh`、`--libexecdir=${prefix}/lib/openssh`、`--with-privsep-path=/run/sshd`、`--with-pid-dir=/run`、`--with-pam`、`--with-libedit`、`--with-tcp-wrappers`、`--with-selinux`、`--with-audit=linux`、`--with-security-key-builtin`、`--with-xauth=/usr/bin/xauth`、`--disable-strip`、`--with-mantype=doc`。服务管理:`dh_installinit -R --name=ssh`、systemd units(`ssh.service`、`--no-enable ssh.socket`、`sshd-keygen.service`)、`dh_installpam --name=sshd`、`dh_runit -popenssh-server`。安装时用 `ucf` 管理 `sshd_config`(server 的 Depends 含 `ucf`,并以 `check-ucf-md5sums` 做测试)。

### 3.2 完整流程(可照抄命令)

#### a. 安装打包工具

```bash
sudo apt update
sudo apt install build-essential devscripts debhelper quilt
```

(`devscripts` 提供 `debuild`/`dch`/`uscan`/`uupdate`;`quilt` 用于操作 `debian/patches`。)

#### b. 获取官方打包源码并换成新版上游 tarball 重打包

启用 `deb-src` 源(`sources.list(5)` 定义了 `deb-src` 行类型,[manpage](https://manpages.ubuntu.com/manpages/focal/en/man5/sources.list.5.html)):

```bash
# 临时启用 deb-src(以 focal 为例;写成单独文件更干净)
echo "deb-src http://archive.ubuntu.com/ubuntu focal main universe" | \
  sudo tee /etc/apt/sources.list.d/deb-src.list
sudo apt update

apt source openssh          # 下载并解开官方打包源码
sudo apt build-dep openssh  # 安装编译依赖(见下)
```

换上游 tarball 重打包(核心是 orig tarball 命名 + `dch` 增加版本条目)。官方 `debian/watch` 已核实指向 `https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-(.*)\.tar\.gz` 并用 `pgpsigurlmangle` 校验签名([watch 原文](https://sources.debian.org/data/main/o/openssh/1%3A10.4p1-5/debian/watch)),因此 `uscan` 可自动完成下载:

```bash
cd openssh-*/

# 方式一:uscan 自动比对并下载新版
uscan --verbose --download-current-version  # 或直接 uscan 检查新版

# 方式二:手动放置新 tarball(3.0 (quilt) 要求命名为 <source>_<版本>.orig.tar.gz)
cd ..
curl -LO https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.4p1.tar.gz
curl -LO https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.4p1.tar.gz.asc
mv openssh-10.4p1.tar.gz  openssh_10.4p1.orig.tar.gz
gpg --verify openssh_10.4p1.orig.tar.gz.asc   # 建议校验

# 基于旧打包目录合成新版源码树(保留 debian/)
cd openssh-*/            # 旧版源码树
uupdate ../openssh_10.4p1.orig.tar.gz   # devscripts 工具,生成 ../openssh-10.4p1 新目录

cd ../openssh-10.4p1
# 写入新版本条目(格式: 1:10.4p1-1~focal 这种 <epoch>:<upstream>-<revision>)
dch -v 1:10.4p1-1~focal "New upstream release 10.4p1, rebuilt for focal."
dch --distribution focal --release   # 也可用 --distribution 指定发行版
```

版本号格式依据 [deb-version(5)](https://manpages.debian.org/unstable/dpkg/deb-version.5.en.html)(原文从 [dpkg 源码 man/deb-version.pod](https://sources.debian.org/src/dpkg/1.23.7/man/deb-version.pod) 核实):版本为 `[epoch:]upstream-version[-debian-revision]`;epoch 为整数(openssh 历史上一直用 `1:`);**tilde 排序规则原文:"a tilde sorts before anything, even the end of a part"**,因此 `10.4p1-1~focal < 10.4p1-1`,适合做"不会覆盖官方正式版"的本地后缀。`dch`(debchange)是官方维护 `debian/changelog` 的工具,支持 `--increment`/`--newversion`/`--distribution`([debchange(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/dch.1.html))。

> 提示:若要复刻 Debian 新拆分,还需同样处理 [openssh-gssapi 源码包](https://sources.debian.org/src/openssh-gssapi/)(其 `debian/` 同样在 sources.debian.org 可浏览)。

#### c. 安装编译依赖

```bash
sudo apt build-dep openssh   # 在源码目录内执行亦可
```

`apt-get build-dep` 是官方手册记载的子命令([apt-get(8)](https://manpages.ubuntu.com/manpages/focal/en/man8/apt-get.8.html))。sid 打包声明的 Build-Depends(已核实):`debhelper (>= 13.1~)`、`debhelper-compat (= 13)`、`dh-exec`、`dh-runit (>= 2.8.8)`、`dh-sequence-installsysusers`、`libedit-dev`、`libfido2-dev (>= 1.5.0)`、`libpam0g-dev | libpam-dev`、`libssl-dev (>= 1.1.1)`、`libselinux-dev`、`libaudit-dev`、`libwrap0-dev`、`libwtmpdb-dev`、`pkgconf`、`zlib1g-dev` 等;focal 上按 3.4 节处理差异。

#### d. 构建

本机直接构建(单命令):

```bash
cd openssh-10.4p1
debuild -us -uc -b        # 仅二进制包,-us/-uc 不签名
# 或者:
dpkg-buildpackage -us -uc -b
```

依据:`debuild(1)` 是 "a wrapper around the **dpkg-buildpackage** … to build a Debian package",构建完成后自动运行 lintian 并可用 `debsign` 签名,`-us`/`-uc` 表示 unsigned source/changes、`-b` 表示 "build binary packages, no source files"、`-S` 仅源码包([debuild(1)](https://manpages.debian.org/unstable/devscripts/debuild.1.en.html)、[dpkg-buildpackage(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/dpkg-buildpackage.1.html))。产物(`.deb`、`.changes`、`.buildinfo`)生成在源码树的**上级目录**。

干净环境构建(chroot):

```bash
# pbuilder(手册: pbuilder(8);create/update/build 三命令已核实)
sudo apt install pbuilder
sudo pbuilder create --distribution focal --architecture amd64 \
     --mirror http://archive.ubuntu.com/ubuntu --debootstrapopts --variant=buildd
sudo pbuilder update                      # 定期更新 base.tgz
sudo pbuilder build ../openssh_1%3A10.4p1-1~focal.dsc
# 结果默认在 /var/cache/pbuilder/result/

# sbuild(手册: sbuild(1);"The easiest way to set up sbuild for use with the
#          schroot backend is by using sbuild-createchroot … user has to be added
#          to the sbuild group, for example by running sbuild-adduser")
sudo apt install sbuild
sudo sbuild-createchroot --include=ca-certificates \
     focal /srv/chroot/focal-amd64 http://archive.ubuntu.com/ubuntu/
sudo sbuild-adduser "$USER" && newgrp sbuild
sbuild -d focal ../openssh_1%3A10.4p1-1~focal.dsc
```

来源:[pbuilder(8)](https://manpages.ubuntu.com/manpages/focal/en/man8/pbuilder.8.html)、[sbuild(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/sbuild.1.html)

#### e. 产物安装与验证

```bash
cd /var/cache/pbuilder/result/   # 或 debuild 输出目录
sudo apt install ./openssh-common_10.4p1-1~focal_*.deb \
                 ./openssh-client_10.4p1-1~focal_*.deb \
                 ./openssh-sftp-server_10.4p1-1~focal_*.deb \
                 ./openssh-server_10.4p1-1~focal_*.deb
# 或逐个 dpkg -i(apt 会自动解决依赖,dpkg 不会)
sudo dpkg -i openssh-server_10.4p1-1~focal_amd64.deb

# 验证
ssh -V
dpkg -l | grep openssh
sshd -t && systemctl status ssh    # 校验配置与服务
```

**升级 `openssh-server` 的注意事项**:

- `sshd_config` 是 conffile,由 dpkg 的 conffile 机制 + `ucf` 管理(server Depends 含 `ucf`)。非交互升级保留本地修改可用:

```bash
sudo apt -o Dpkg::Options::="--force-confold" install ./openssh-server_*.deb
```

`--force-confold` 的 dpkg(1) 官方定义:"If a conffile has been modified and the version in the package did change, always keep the old version without prompting"([dpkg(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/dpkg.1.html))。这正是 `openssh-10.4p1-1/install_debs.sh` 中所用选项的依据。
- 升级会触发服务管理脚本重启 sshd(rules 使用 `dh_installinit`/systemd units)。**在远程机器上操作时建议先开一个备用会话/串口控制台**,避免配置错误导致失联(此为运维常识,具体重启行为细节未在一手资料中单独核实)。
- `openssh-server` 与 `openssh-client`、`openssh-common`、`openssh-sftp-server` 有 `= ${binary:Version}` 严格同版本依赖,**四个包必须一起安装/升级**(control 已核实)。

### 3.3 替代简化路径(非官方,仅供临时使用)

- **[fpm](https://fpm.readthedocs.io/en/latest/)**:官方定位原文 "fpm isn't a new packaging system, it's a tool to help you make packages for existing systems with less effort",典型用法 `fpm -s dir -t deb -n mypkg …`。局限:只做"文件目录 → 包"的封装,不执行 Debian 官方构建流水线(`debian/rules`、dh 序列、shlibs 自动依赖、conffile/ucf、服务脚本均需手工模仿),得到的包不适合分发。
- **checkinstall**:项目长期无维护、无活跃官方文档,**未在一手资料中核实**;不建议用于 openssh 这种含服务与 conffile 的核心组件。
- **手动 `dpkg-deb --build`**:自己拼 `DEBIAN/control` 与文件树后打包。可行但同样绕过依赖计算与服务管理,仅适合一次性测试。

对 openssh 这类"客户端 + 服务端 + PAM + systemd + conffile + 特权分离用户"的组件,官方打包(3.2 节)是唯一能正确处理上述全部细节的路径。

### 3.4 Ubuntu focal 上构建较新 openssh 的注意事项

focal 仓库实际版本(已从 [archive.ubuntu.com focal Packages 索引](http://archive.ubuntu.com/ubuntu/dists/focal/) 核实):

| 包 | focal 版本 | sid 打包要求 | 结论 |
|---|---|---|---|
| `debhelper` | `12.10ubuntu1` | `>= 13.1~` + `debhelper-compat (= 13)` | **不满足**,需回退打包写法或自行移植 |
| `libfido2-dev` | `1.3.1-1ubuntu2` | `>= 1.5.0` | 不满足 sid 要求;上游 INSTALL:"libfido2 >= 1.5.0 is strongly recommended. Limited functionality is possible with earlier libfido2 versions" |
| `libssl-dev` / `openssl` | `1.1.1f-1ubuntu2` | sid 要求 `>= 1.1.1`;上游 INSTALL 要求 "OpenSSL 1.1.1 or greater" | **满足**(对比:Fedora spec 自行要求 `openssl-devel >= 1:3.5.0`,那是 Fedora 为启用新 KEX 的选择,非上游硬性要求) |
| `dh-runit` | `2.8.14ubuntu2`(universe) | `>= 2.8.8` | 满足 |
| `dh-exec` / `quilt` / `devscripts` / `pbuilder` | `0.23.2` / `0.65-3` / `2.20.2ubuntu2` / `0.230.4` | — | 可用 |
| `libwtmpdb-dev`、`dh-sequence-installsysusers` | focal 无 | sid 打包使用 | **缺失**,需从 rules/control 中移除相应功能 |

实操建议(与本机既有路线一致):

1. **以 focal 原生 `1:8.2p1-4` 打包为基底**(compat 9、无需 `dh-sequence-installsysusers`/`libwtmpdb`),替换 tarball 为新版并 `dch` 写入如 `1:10.5p1-1~focal`,再按需叠加需要的子包拆分——这是 focal 上阻力最小的官方式路径。
2. 直接搬用 sid master 的 `debian/` 到 focal 会因 debhelper 13、sysusers、libwtmpdb、libfido2 >= 1.5 构建失败,需要降级改写;或用 pbuilder/sbuild 建 **focal chroot** 并在其中混入新依赖(backport 依赖成本高,不推荐大规模混源)。
3. 上游硬性依赖很少:C 编译器、zlib(`>= 1.1.4`)、libcrypto(OpenSSL `>= 1.1.1`/LibreSSL `>= 3.1.0`),以及**必需的特权分离用户/组与目录**(`README.privsep`;Debian 打包用 `--with-privsep-path=/run/sshd`)([上游 INSTALL](https://github.com/openssh/openssh-portable/blob/master/INSTALL))。
4. 若目标只是"在 focal 上用新版 OpenSSH"而不必产出 deb,可完全绕开打包:按 2.7 节自建静态 OpenSSL(解决 focal libssl 1.1.1 过老的问题)后直接编译安装到独立前缀(`/opt/...`),不触碰系统 libssl 与 apt 中的 openssh 包。

---

## 4. RPM 打包(RHEL/Fedora/openSUSE 路径)

> 资料可达性说明:src.fedoraproject.org、docs.fedoraproject.org 均有 Anubis 反爬防护,以下 Fedora spec 内容经官方镜像网络成员 [mirrors.kernel.org](https://mirrors.kernel.org/fedora/development/rawhide/Everything/source/tree/Packages/o/) 下载官方 SRPM `openssh-10.5p1-1.fc46.src.rpm` 解包核实;rpmbuild/rpm 等手册从官方 RPM 包内 manpage 提取核对。

### 4.1 上游 contrib/ 目录核实结论

上游 master 的 `contrib/` 实际内容(经 [GitHub API](https://github.com/openssh/openssh-portable/tree/master/contrib) 枚举核实):目录 `aix/`、`cygwin/`、`hpux/`、`redhat/`、`solaris/`、`suse/`;文件 `Makefile`、`README`、`findssl.sh`、`gnome-ssh-askpass{1,2,3,4}.c`、`ssh-copy-id`、`sshd.pam.freebsd`、`sshd.pam.generic`。[contrib/README](https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/README) 原文定位:

> "aix: Files to build an AIX native (installp or SMIT installable) package."
> "redhat: RPM spec file and scripts for building Redhat packages"
> "suse: RPM spec file and scripts for building SuSE packages"

即**上游确实自带 RPM spec 与打包脚本**。两个 spec 的实况(已抓全文核实):

- [`contrib/suse/openssh.spec`](https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/suse/openssh.spec):247 行,`Version: 10.5p1`(随上游自动更新),但使用老式 `PreReq`/`BuildPrereq`/`BuildRoot` 语法,仅拆分主包 + `askpass` 两个包,面向老 SuSE init 脚本(`rc.sshd`),现代 openSUSE 上基本不可直接用。
- [`contrib/redhat/openssh.spec`](https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/redhat/openssh.spec):818 行,`%global ver 10.5p1`,子包 `clients`/`server`/`askpass`/`askpass-gnome`,`%configure` 含 `--sysconfdir=%{_sysconfdir}/ssh`、`--libexecdir=%{_libexecdir}/openssh`、`--with-privsep-path=%{_var}/empty/sshd`、`--with-pam`、`--with-kerberos5` 等。可用作自建起点,但与 Fedora 官方 spec 是**独立维护的两份文件**(后者包含大量发行版补丁与现代宏)。

### 4.2 Fedora 官方 spec 的结构要点

以下基于从官方镜像提取的 rawhide `openssh-10.5p1-1.fc46.src.rpm` 内的 `openssh.spec`([dist-git 源](https://src.fedoraproject.org/rpms/openssh/blob/rawhide/f/openssh.spec),本次经 [kernel.org 镜像 SRPM](https://mirrors.kernel.org/fedora/development/rawhide/Everything/source/tree/Packages/o/) 核实):

- **头信息**:`Name: openssh`,`Version: %{openssh_ver}`(`%global openssh_ver 10.5p1`),`Release: 1%{?dist}`,`Source0: https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-%{version}.tar.gz`(附 `.asc` 签名,`%prep` 中用 `gpgv2 --quiet --keyring %{SOURCE3} %{SOURCE1} %{SOURCE0}` 验签)。
- **补丁系列**:`Patch0001` … `Patch0053` 共 53 个(Selinux/MLS 支持、`gssapi-keyex`、`crypto-policies`、FIPS、audit、scp 行为等大量 Fedora 专属改动),`%prep` 用 `%autosetup -T -b 0 -p1` 应用后执行 `autoreconf`。
- **BuildRequires**(节选):`pam-devel`、`openssl-devel >= 1:3.5.0`、`libselinux-devel >= 2.3-5`、`audit-libs-devel >= 2.0.5`、`libfido2-devel`、`krb5-devel`、`libedit-devel ncurses-devel`、`systemd-devel`、`systemd-rpm-macros`、`p11-kit-devel`、`gtk3-devel` 等。
- **子包**:`openssh`(公共)、`openssh-clients`(Requires `openssh = %{version}-%{release}`、`crypto-policies`)、`openssh-keysign`、`openssh-server`(Requires `pam >= 1.0.1-3`、`/sbin/nologin`、`Requires(pre): /usr/sbin/useradd`、`%{?systemd_requires}`)、`openssh-keycat`、`openssh-askpass`、`openssh-sk-dummy`。
- **`%configure` 要点**:`--sysconfdir=%{_sysconfdir}/ssh`、`--libexecdir=%{_libexecdir}/openssh`、`--with-privsep-path=%{_datadir}/empty.sshd`、`--with-pam`、`--with-selinux --with-audit=linux --with-sandbox=seccomp_filter`、`--with-kerberos5`、`--with-libedit`、`--with-security-key-builtin=yes`、`--disable-strip`、`--with-pie=no --without-hardening`(加固 flags 交给系统构建系统)。
- **服务与脚本**:SOURCES 附带 `sshd.service`、`sshd.socket`、`sshd@.service`、`sshd-keygen@.service`、`sshd-keygen.target`、`ssh-agent.service/socket`、`sshd.pam`、`sshd.sysconfig`、`openssh-server-systemd-sysusers.conf`;`%pre server` 创建 sshd 用户,`%post server` 安装 systemd unit。注意 Fedora 拆分包名是 `openssh-clients`/`openssh-server`,与 Debian 的 `openssh-client`/`openssh-server` 不同名。

### 4.3 完整流程(可照抄命令)

#### a. 安装工具

Fedora 官方 RPM Packaging Guide 的 Prerequisites 原文命令([来源](https://rpm-packaging-guide.github.io/),该指南已从 rpm-guide.readthedocs.io 永久迁移至此):

```bash
sudo dnf install gcc rpm-build rpm-devel rpmlint make python bash \
                 coreutils diffutils patch rpmdevtools
```

(`rpmdevtools` 提供 `rpmdev-setuptree` 与 `rpmdev-newspec`。)

#### b. 创建目录结构

```bash
rpmdev-setuptree
```

该脚本行为已从 rpmdevtools 包内的脚本本体核实:向 `~/.rpmmacros` 写入 `%_topdir %(echo $HOME)/rpmbuild`,然后 `mkdir -p` 五个目录——`%{_rpmdir}`、`%{_sourcedir}`、`%{_specdir}`、`%{_srcrpmdir}`、`%{_builddir}`,即 `~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}`。

#### c. 放入源码与 spec

```bash
cd ~/rpmbuild/SOURCES
curl -LO https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.5p1.tar.gz
curl -LO https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.5p1.tar.gz.asc

# 三种 spec 来源任选:
# 1) Fedora 官方 dist-git(src.fedoraproject.org,含 53 个补丁与其余 Source 文件,
#    严格来说应通过 fedpkg 或 SRPM 解包获取,见 4.4);
# 2) 上游 contrib/redhat/openssh.spec(自建起点);
# 3) 上游 contrib/suse/openssh.spec(参考价值为主)
cp /path/to/openssh.spec ~/rpmbuild/SPECS/
```

#### d. 安装构建依赖并构建

```bash
sudo dnf install 'dnf-command(builddep)'   # 若未装 builddep 插件
cd ~/rpmbuild/SPECS
sudo dnf builddep openssh.spec              # 也可对 .src.rpm 使用
rpmbuild -bb openssh.spec                   # 仅二进制包
rpmbuild -bs openssh.spec                   # 仅 SRPM(-s: "Build just the source package")
rpmbuild -ba openssh.spec                   # 两者都要
```

依据:`dnf4-builddep(8)`:"Install whatever is needed to build the given .src.rpm, .nosrc.rpm or .spec file"([dnf-plugins-core manpage](https://dnf.readthedocs.io/en/latest/command_ref.html));[rpmbuild(1)](https://rpm.org/documentation.html):`-b STAGE` "Build STAGE from a spec file",stage `s` = 仅源码包,示例原文 `rpmbuild -bb --nocheck --with openssl hello.spec`。

产物在 `~/rpmbuild/RPMS/x86_64/*.rpm` 与 `~/rpmbuild/SRPMS/*.src.rpm`。

#### e. 干净环境:mock

mock 官方文档([rpm-software-management.github.io/mock/](https://rpm-software-management.github.io/mock/)):"Mock creates chroots and builds packages in them… It is called by Koji and Copr to build chroots and packages" 且 "Mock is currently being used for all Fedora builds"。

```bash
sudo dnf install mock
sudo usermod -a -G mock "$USER"     # 官方文档要求加入 mock 组
newgrp mock

mock -r fedora-41-x86_64 --rebuild ~/rpmbuild/SRPMS/openssh-10.5p1-1.fc46.src.rpm
# 结果与日志: /var/lib/mock/fedora-41-x86_64/result/
```

(配置名即 `/etc/mock/*.cfg` 去掉扩展名。注意 mock 组成员等同授予 root 权限,官方原文警告勿加入不可信用户。)

#### f. 产物安装与升级

```bash
sudo dnf install ./openssh-10.5p1-1*.rpm ./openssh-clients-10.5p1-1*.rpm \
                 ./openssh-server-10.5p1-1*.rpm
# 或用底层工具:
sudo rpm -Uvh openssh-*.rpm      # 升级/安装
sudo rpm -ivh openssh-*.rpm      # 首次安装
```

rpm(8) 原文:`-U, --upgrade` "Install or upgrade package(s) to a newer version",且 "normally installations should be done with `--upgrade`";`-i, --install` 为普通安装。升级 `openssh-server` 前同样建议保留 `sshd_config` 备份并保持备用会话。

### 4.4 从 SRPM 重建

```bash
# 获取 SRPM(Fedora 官方仓库或镜像)
dnf download --source openssh          # dnf4-download(8): "Download binary or source packages"
# 或从官方镜像直接下载(如 kernel.org 的 releases/development 源树)

# 方式一:安装 SRPM 后重构建
rpm -ivh openssh-10.5p1-1.fc46.src.rpm   # 解到 ~/rpmbuild/{SOURCES,SPECS}
cd ~/rpmbuild/SPECS
rpmbuild -bb openssh.spec                # 修改 spec 后重建二进制包

# 方式二:一条命令重建(rpmbuild --rebuild 是 -ra 的兼容别名,
#          官方示例原文: rpmbuild --rebuild hello-1.0-1.src.rpm)
rpmbuild --rebuild openssh-10.5p1-1.fc46.src.rpm

# 方式三:干净 chroot 重建(官方推荐)
mock -r fedora-41-x86_64 --rebuild openssh-10.5p1-1.fc46.src.rpm
```

来源:[rpmbuild(1)](https://rpm.org/documentation.html)("--rebuild, --recompile: Compatibility aliases for `-ra`");`dnf download --source`([dnf-plugins-core](https://dnf.readthedocs.io/en/latest/command_ref.html))。

---

## 5. 两条打包路径的对比与建议

| 维度 | DEB(Debian 官方打包) | RPM(Fedora 官方 spec) |
|---|---|---|
| 上游自带打包文件 | 无 DEB 相关文件(contrib/ 仅 RPM/AIX 等,[README](https://github.com/openssh/openssh-portable/tree/master/contrib)) | contrib/redhat、contrib/suse 各带一份 spec,随上游版本更新但语法偏老 |
| 发行版补丁量 | debian/patches 中等规模 | 53 个补丁,深度定制(SELinux、crypto-policies、FIPS),换上游版本需处理冲突 |
| 子包模型 | client/server/sftp-server/common 分离 + 新增独立源码包 openssh-gssapi | clients/server/keysign/keycat/askpass/sk-dummy |
| conffile 管理 | dpkg conffile + ucf | RPM `%config(noreplace)` |
| 干净构建 | pbuilder / sbuild | mock(Fedora 全部官方构建即基于它) |

- **在 focal 上继续 DEB 路线**(本机已走通):以 focal 原生打包为基 + `dch -v 1:10.5p1-1~focal` 替换 tarball,是依赖摩擦最小的官方式做法;若要精确复刻 sid 新拆分,参考 [openssh-gssapi](https://sources.debian.org/src/openssh-gssapi/) 源码包。
- **RPM 侧**:生产级用 Fedora dist-git 的 spec(经 SRPM/fedpkg 获取);自建可用上游 `contrib/redhat/openssh.spec` 起步,但需自行补 systemd unit、SELinux、sysusers 等现代发行版要素。
- 上游 tarball 与签名统一来自 `https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/`(Debian watch 与 Fedora Source0 一致,已核实;[cdn.openbsd.org](https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/) 镜像可达)。

---

## 6. 主要一手资料索引

**上游官方**

- 官网首页(含当前版本号):<https://www.openssh.com/>(当前 301 重定向到 openssh.org,同一官方站点)
- Features 页:<https://www.openssh.com/features.html>
- Portable 说明/下载镜像/命名规则:<https://www.openssh.com/portable.html>
- 发布说明总页:<https://www.openssh.com/releasenotes.html>
- 各版本 notes 全文:<https://www.openssh.com/txt/release-10.0> … [release-10.5](https://www.openssh.com/txt/release-10.5)
- 官方源码目录(CDN):<https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/>
- GitHub 官方镜像仓库:<https://github.com/openssh/openssh-portable>(默认分支 master;release 分支如 `V_10_5`)
- 仓库内文件(raw):[README.md](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.md)、[INSTALL](https://raw.githubusercontent.com/openssh/openssh-portable/master/INSTALL)、[README.privsep](https://raw.githubusercontent.com/openssh/openssh-portable/master/README.privsep)、[configure.ac](https://raw.githubusercontent.com/openssh/openssh-portable/master/configure.ac)、[LICENCE](https://raw.githubusercontent.com/openssh/openssh-portable/master/LICENCE)、[SECURITY.md](https://raw.githubusercontent.com/openssh/openssh-portable/master/SECURITY.md)、[contrib/README](https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/README)、[contrib/redhat/openssh.spec](https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/redhat/openssh.spec)、[contrib/suse/openssh.spec](https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/suse/openssh.spec)、CI 依赖脚本 [.github/setup_ci.sh](https://raw.githubusercontent.com/openssh/openssh-portable/master/.github/setup_ci.sh)

**OpenSSL(2.7 节静态内嵌 libcrypto 用)**

- 官方源码发布页:<https://www.openssl.org/source/>(tarball 与 `.asc` 签名);GitHub 官方 releases:<https://github.com/openssl/openssl/releases>
- OpenSSL 官方构建说明 INSTALL.md(`no-shared` 选项、静态库产物位置、共享库说明):<https://github.com/openssl/openssl/blob/master/INSTALL.md>

**Debian/Ubuntu 打包**

- Debian 打包仓库与源码浏览:[salsa.debian.org/ssh-team/openssh](https://salsa.debian.org/ssh-team/openssh)、[sources.debian.org/src/openssh](https://sources.debian.org/src/openssh/)(control/rules/changelog/watch/format)、[openssh-gssapi](https://sources.debian.org/src/openssh-gssapi/)
- Ubuntu focal 打包:[git.launchpad.net/ubuntu/+source/openssh](https://git.launchpad.net/ubuntu/+source/openssh)、[archive.ubuntu.com focal Packages](http://archive.ubuntu.com/ubuntu/dists/focal/)
- 手册:[debuild(1)](https://manpages.debian.org/unstable/devscripts/debuild.1.en.html)、[dpkg-buildpackage(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/dpkg-buildpackage.1.html)、[dh(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/dh.1.html)、[debchange(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/dch.1.html)、[dpkg-source(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/dpkg-source.1.html)、[deb-version(5)](https://manpages.debian.org/unstable/dpkg/deb-version.5.en.html)、[dpkg(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/dpkg.1.html)、[sources.list(5)](https://manpages.ubuntu.com/manpages/focal/en/man5/sources.list.5.html)、[apt-get(8)](https://manpages.ubuntu.com/manpages/focal/en/man8/apt-get.8.html)、[pbuilder(8)](https://manpages.ubuntu.com/manpages/focal/en/man8/pbuilder.8.html)、[sbuild(1)](https://manpages.ubuntu.com/manpages/focal/en/man1/sbuild.1.html)

**Fedora/RPM 打包**

- Fedora 官方 dist-git:[src.fedoraproject.org/rpms/openssh](https://src.fedoraproject.org/rpms/openssh)(经 [kernel.org 镜像 SRPM](https://mirrors.kernel.org/fedora/development/rawhide/Everything/source/tree/Packages/o/) 核实 spec 内容)
- [RPM Packaging Guide](https://rpm-packaging-guide.github.io/)、[mock 官方文档](https://rpm-software-management.github.io/mock/)、[dnf 命令参考](https://dnf.readthedocs.io/en/latest/command_ref.html)、[rpm.org 文档](https://rpm.org/documentation.html)、[Fedora Packaging Guidelines](https://docs.fedoraproject.org/en-US/packaging-guidelines/)(该站与 src.fedoraproject.org 均有反爬防护,仅提供链接)
- 手册:rpmbuild(1)/rpm(8)/rpmdev-setuptree/dnf4-builddep(8)/dnf4-download(8)(自 Fedora 官方仓库 RPM 内 manpage 核实)

**非官方路径**

- [fpm 文档](https://fpm.readthedocs.io/en/latest/);checkinstall:未在一手资料中核实

**未能核实的点(明示)**

- checkinstall 的现状(无活跃官方文档);
- `openssh-server` 升级时 sshd 重启的精确行为描述(建议按运维常识保留备用会话);
- Fedora Packaging Guidelines 正文(站点反爬,仅提供链接)。
