# OpenSSH 10.5p1 RPM 本地构建说明(面向 Kylin V10 Lance,静态内嵌 OpenSSL 4.0.2)

构建日期:2026-08-31 · 构建方式:本机 Docker(Rocky Linux 8 容器)· 产物目录:`out-rpm/`

## 目标环境(实测采集)

Kylin Linux Advanced Server V10 (Lance):x86_64 / glibc 2.28 / systemd 243 / rpm 4.15.1,
现网已装原生 `openssh{,-clients,-server}-10.0p1-1.ky10` 与遗留 `openssh-help-8.2p1`(noarch)。

## 容器化构建(推荐)

```bash
cd <workspace-root>                     # 即本文件所在目录
docker build -f docker-rpm/Dockerfile -t openssh-rpm:10.5p1-1.ky10 .
mkdir -p out-rpm
docker run --rm -v "$PWD/out-rpm":/host-out openssh-rpm:10.5p1-1.ky10
# 三个 RPM 即出现在 out-rpm/(镜像内已通过 stage2 彩排验证才会产出)
```

- 构建上下文为工作区根目录(`.dockerignore` 只放行 `docker-rpm/` 与 `docker/seed/`)
- 多阶段:stage1(Rocky 8)完成源码校验→静态依赖编译→OpenSSH 编译→rpmbuild→字节级校验;
  stage2(全新 Rocky 8)安装发行版原生 openssh → `rpm -Uvh` 升级到本构建 → 端到端彩排
- 全程离线源码(`docker/seed/`),OpenSSH 走 PGP 验签(指纹
  `7168 B983 815A 5EEF 59A4 ADFD 2A3F 414E 7360 60BA`),其余 SHA256 固定
- dnf 源:USTC → 阿里云 → 官方逐级回退(单源 + 失败换源;多 baseurl 并列时 dnf 会
  选中低延迟但低速的源,不可用;rocky extras 仓库 USTC 缺失且不需要,已移除)
- 版本更新方法:替换 seed 内 tarball,同步 `docker-rpm/build.sh` 校验值与 spec 版本号

## 产物

| 文件(out-rpm/) | 大小 | 说明 |
|---|---|---|
| `openssh-10.5p1-1.ky10.x86_64.rpm` | 3.9M | ssh-keygen/add/agent/keyscan + libexec helpers + moduli |
| `openssh-clients-10.5p1-1.ky10.x86_64.rpm` | 2.0M | ssh/scp/sftp/ssh-copy-id + ssh_config |
| `openssh-server-10.5p1-1.ky10.x86_64.rpm` | 2.6M | sshd + sshd-session/sshd-auth + sftp-server + 配置/单元 |

版本 `10.5p1-1.ky10` 高于现网 `10.0p1-1.ky10`,直接原地升级。

## 版本组合

- OpenSSH **10.5p1**(官方 tarball,PGP 验签)
- OpenSSL **4.0.2**(2026-08-25 发布;`no-shared no-zlib -fPIC` 静态)
- zlib 1.3.2、libcbor 0.14.0、libfido2 1.17.0、libedit 20240808-3.1、
  **ncurses 6.5(新增,EL8 无任何静态 tinfo,必须自建)** —— 全部静态

## 静态/动态链接策略

**静态内嵌**(安装后不依赖系统加密/压缩库):libcrypto、libz、libcbor、libfido2、
libedit、libtinfo(ncurses)。

**保持动态**(全部为 Kylin 必装基础库,glibc 2.28 符号上限):libc/libdl/libpthread/
libresolv/libutil、libpam、libaudit、libselinux、libcrypt(XCRYPT_2.0)、
libudev(仅 ssh-sk-helper)。`ssh -V` → `OpenSSH_10.5p1, OpenSSL 4.0.2 25 Aug 2026`。

## 与 Kylin 原生包的兼容设计

- 文件布局与原生 10.0p1 完全对齐:`--libexecdir=/usr/libexec`、
  privsep `/var/empty/sshd`、包名拆分一致 → 干净原地升级
- **`/usr/libexec/openssh/sftp-server` 兼容软链**:现网 sshd_config 的 Subsystem 指向
  该路径(原系统上此文件缺失、sftp 子系统实际悬空),升级后即被修复
- `sshd_config`/`ssh_config`/`moduli`/`pam.d/sshd` 均为 `%config(noreplace)`:
  升级保留管理员配置,新配置存为 `.rpmnew`
- **`sshd.service` 以普通文件覆盖**(非 config):现网单元是 `Type=notify`
  (麒麟为其打过 sd_notify 补丁的 sshd),上游 sshd 无此支持,必须换成 `Type=simple`,
  否则升级后 sshd 启动会等待 notify 超时失败
- `Obsoletes: openssh-help < 10.5p1`:自动移除遗留 8.2 帮助包(其 man page 与本包冲突)
- scriptlets:%pre 建 sshd 特权用户(现网已有则空操作)、%post `ssh-keygen -A` 补主机
  密钥 + systemd daemon-reload/try-restart(既有会话不受影响)、卸载时 disable --now
- PAM 栈内容与 Kylin 现网 /etc/pam.d/sshd 完全一致(password-auth/postlogin 体系)

## 已验证(stage2 彩排 + Kylin 实机干跑)

- Rocky 8 容器:原生 8.0p1 → 本构建升级、管理员改过的 sshd_config 保留(.rpmnew)、
  UsePAM 公钥登录、zlib@openssh.com 压缩、外部 sftp(兼容路径)、internal-sftp、
  scp、升级后系统配置 `sshd -t`、依赖清单无加密族
- 字节级:所有 ELF 无 libcrypto/libssl/libz/libfido2/libcbor/libedit/libtinfo 动态依赖;
  GLIBC 符号全部 ≤ 2.28(rocky8 与 Kylin 同为 glibc 2.28)
- Kylin 实机(未安装):三个包 sha256 传输核对一致;`rpm -Uvh --test` 通过;
  全部 soname 依赖在 /usr/lib64 可解析

## 安装(目标机 Kylin)

```bash
rpm -Uvh openssh-10.5p1-1.ky10.x86_64.rpm \
          openssh-clients-10.5p1-1.ky10.x86_64.rpm \
          openssh-server-10.5p1-1.ky10.x86_64.rpm
# 或三包放同目录:rpm -Uvh *.rpm(必须同事务,分包互相 Requires 锁版本)
```

升级后建议 `systemctl status sshd` 确认服务以新单元(Type=simple)运行;
既有 SSH 会话不断,新连接由新 sshd 接管。如需采纳新默认配置,对比 `.rpmnew` 后手工合并。

注意:本构建为上游 OpenSSH,不含麒麟的国密(SM2/SM3/SM4)扩展;与麒麟打补丁的
ssh 客户端/服务器互连时回落到双方共同支持的标准算法。现网 /etc/ssh 下的
`ssh_host_sm2_key` 不会被上游 sshd 加载,无影响。

## 构建过程中的关键坑(EL8 与 Ubuntu 构建的差异)

1. **EL8 无任何静态 ncurses/tinfo**(ncurses-devel 只有 .so)→ 自建 ncurses 6.5
   (`--with-termlib` + widec 产物带 w 后缀,补 `libtinfo.a`→`libtinfow.a` 软链)
2. **EL8 包名**:`audit-libs-devel`(非 libaudit-devel)、`libxcrypt-devel`(非 libcrypt-devel)
3. **EL8 的 cmake 不依赖 pkg-config,需显式装 `pkgconfig`**:否则 openssh configure
   走非 pkg-config 分支,`LIBEDIT="-ledit -lcurses"`,静态链接修正 sed 失配
4. **pkgconf 1.4.2 的 `--libs` 输出带尾随空格**:Makefile 中 `LIBEDIT=...-ledit $`,
   sed 模式需 `[[:space:]]*$` 容差(Ubuntu pkg-config 0.29 无尾随空格,deb 经验不适用)
5. **spec 注释里绝不能出现宏的字面 `%` 写法**:RPM 对注释行同样做宏展开,
   注释中的 `%configure` 会吞掉真正的调用参数(configure 以无参形态运行,极难排查)
6. **RPM SourceN 的 URL basename 必须与本地文件名一致**:GitHub tags 链接
   (`v0.14.0.tar.gz`)与 `libcbor-0.14.0.tar.gz` 不一致时按 URL 名查找失败
7. `%configure` 是多命令序列:`LIBS=... %configure` 的行首环境前缀传不进去,须 `export`
8. libcbor 的 CMake 探测需要 C++ 编译器(装 gcc-c++)
9. 宿主根分区曾 100%(清理 journal/缓存解决);rocky 镜像源偶发 403/限流/慢速,
   需逐级换源重试

## 与 deb 构建的关系

同一套源码与静态内嵌策略,复用 `docker/seed/`(seed 新增 ncurses-6.5.tar.gz,deb 构建
不受影响)。deb 版文档见 `README-local-build.md`,本文件只覆盖 RPM/Kylin 特有内容。
