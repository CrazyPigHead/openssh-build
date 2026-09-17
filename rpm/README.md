# rpm 构建模块

在 Rocky Linux 8 容器内构建三个 RPM(静态内嵌加密栈),默认面向
**Kylin Linux Advanced Server V10 (Lance)**:x86_64 / glibc 2.28 /
systemd 243 / rpm 4.15.1,现网已装原生 `openssh{,-clients,-server}-10.0p1`
与遗留 `openssh-help-8.2p1`(noarch)。

| 包(10.5p1 示例) | 内容 |
|---|---|
| `openssh` | /usr/bin/{ssh-add,ssh-agent,ssh-keygen,ssh-keyscan}、/usr/libexec/{ssh-keysign(setuid),ssh-pkcs11-helper,ssh-sk-helper}、/etc/ssh/moduli |
| `openssh-clients` | /usr/bin/{ssh,scp,sftp,ssh-copy-id}、/etc/ssh/ssh_config |
| `openssh-server` | /usr/sbin/sshd、/usr/libexec/{sshd-session,sshd-auth,sftp-server}、/etc/ssh/sshd_config、/etc/pam.d/sshd、sshd.service、/var/empty/sshd |

由顶层 `build.sh rpm` 编排(用法见项目 [README.md](../README.md)),本模块包含:

- `Dockerfile`:工具链镜像(rockylinux:8 + 构建依赖,不含源码与版本)。
  Rocky 8 与 Kylin V10 同为 glibc 2.28,产物仅引用 ≤ GLIBC_2.28 符号
- `build.sh`:容器内构建(物料校验 → 生成 spec → rpmbuild → 字节级校验)
- `openssh.spec.in`:spec 模板,`@占位符@` 由构建时 versions 值替换;
  `sshd-session`/`sshd-auth` 按源码树探测置 0/1(9.8+/9.9+ 自适应)
- `rehearsal.sh`:彩排脚本,由顶层在**全新原生基底容器**中执行
- `SOURCES/`:sshd.service / sshd.pam / ssh_config / sshd_config

## 构建流程

1. **物料**:从 `downloads/` 复用或自动下载,PGP/SHA256 校验
2. **生成 spec**:版本替换 + 拆分二进制探测(`tar tzf` 查源码树)
3. **rpmbuild -bb**:spec 的 `%build` 内完成全部静态依赖编译
   (OpenSSL → zlib → libcbor → ncurses → libedit → libfido2 → OpenSSH)
4. **产物字节校验**:全 ELF `ldd` 无加密族动态依赖、GLIBC 符号 ≤ 上限
   (默认 2.28)、包内 `ssh -V`、RPM 自动依赖清单留档(`requires.txt`)
5. **彩排**(默认开启,`--no-rehearsal` 跳过):全新 Rocky 8 容器安装
   发行版原生 openssh → `rpm -Uvh` 升级到本构建 → 断言布局/软链/privsep
   用户/主机密钥 → UsePAM 公钥登录、zlib 压缩、外部 sftp(兼容路径)、
   internal-sftp、scp、升级后系统配置 `sshd -t` → 依赖清单复核

## 静态/动态链接策略

**静态内嵌**:libcrypto(OpenSSL)、libz、libcbor、libfido2、libedit、
libtinfo —— 其中 **ncurses 需自建**(EL8 无任何静态 tinfo),运行期
terminfo 数据用系统 `/usr/share/terminfo`,不重复安装数据库。

**保持动态**:libc/libdl/libpthread/libresolv/libutil、libpam、libaudit、
libselinux、libcrypt(XCRYPT_2.0)、libudev(仅 ssh-sk-helper)—— 全部为
目标系统必装基础库。

三处静态链接顺序修正与 deb 模块一致(LIBEDIT 补 `-ltinfo`、CHANNELLIBS
补 `-ldl -lpthread`、libfido2.pc Requires 补 `libudev libcbor`);EL8 的
pkgconf `--libs` 输出带尾随空格,sed 模式需 `[[:space:]]*$` 容差。

## 与目标机原生包的兼容设计(升级即原地替换)

- 文件布局与 Kylin 原生 10.0p1 完全对齐:`--libexecdir=/usr/libexec`、
  privsep `/var/empty/sshd`、包名拆分一致;版本高于现网即直接升级
- **`/usr/libexec/openssh/sftp-server` 兼容软链**:现网 sshd_config 的
  Subsystem 指向该路径(原系统此文件缺失、sftp 子系统实际悬空),升级后修复
- `sshd_config`/`ssh_config`/`moduli`/`pam.d/sshd` 均 `%config(noreplace)`:
  升级保留管理员配置,新配置存为 `.rpmnew`
- **`sshd.service` 以普通文件覆盖**(非 config):现网单元是 `Type=notify`
  (麒麟为其打过 sd_notify 补丁的 sshd),上游 sshd 无此支持,必须换成
  `Type=simple`,否则升级后 sshd 启动等待 notify 超时失败
- `Obsoletes: openssh-help`:升级事务自动移除遗留 8.2 帮助包(其 man page
  与本包冲突)
- scriptlets:%pre 建 sshd 特权用户(现网已有则空操作)、%post `ssh-keygen -A`
  补主机密钥 + systemd daemon-reload/try-restart(既有会话不受影响)、
  卸载时 disable --now
- PAM 栈内容与 Kylin 现网 `/etc/pam.d/sshd` 一致(password-auth/postlogin 体系)

## 安装(目标机)

```bash
rpm -Uvh openssh-<v>.x86_64.rpm openssh-clients-<v>.x86_64.rpm \
          openssh-server-<v>.x86_64.rpm
# 三包必须同事务安装(分包互相 Requires 锁版本)
```

升级后建议 `systemctl status sshd` 确认服务以新单元(Type=simple)运行。
注意:本构建为上游 OpenSSH,**不含麒麟的国密(SM2/SM3/SM4)扩展**;与麒麟
打过补丁的 ssh 互连时回落到双方共同支持的标准算法;现网 `ssh_host_sm2_key`
不会被上游 sshd 加载,无影响。

## 更换目标发行版

默认参数面向 Kylin V10。面向其他 RHEL8 族系统(如 Rocky/Alma/Anolis 8):

```bash
./build.sh rpm --release 1.el8
# GLIBC_MAX 默认 2.28 与 Rocky 8 基底一致,无需调整;
# 更高版本基底(如 el9)需相应调整 GLIBC_MAX 并自行验证布局兼容
```

## 关键坑(EL8 与 Ubuntu 构建差异,实测记录)

1. **EL8 无任何静态 ncurses/tinfo**(ncurses-devel 只有 .so)→ 自建
   ncurses(`--with-termlib` + widec 产物带 w 后缀,补 `libtinfo.a` 软链)
2. **EL8 包名**:`audit-libs-devel`(非 libaudit-devel)、`libxcrypt-devel`
   (非 libcrypt-devel)
3. **cmake 不依赖 pkg-config,必须显式装 `pkgconfig`**:否则 openssh
   configure 走非 pkg-config 分支,静态链接修正 sed 失配
4. **pkgconf 1.4.2 的 `--libs` 输出带尾随空格**:sed 模式需空白容差
5. **spec 注释里绝不能出现宏的字面写法**:RPM 对注释行同样做宏展开
6. **SourceN 的 URL basename 必须与本地文件名一致**:GitHub tags 链接
   (`v0.14.0.tar.gz`)与 `libcbor-0.14.0.tar.gz` 不一致时按 URL 名查找失败
7. **`%configure` 是多命令序列**:`LIBS=... %configure` 的行首环境前缀
   传不进去,须 `export`
8. libcbor 的 CMake 探测需要 C++ 编译器(装 gcc-c++)
9. rocky 镜像源偶发 403/限流/慢速 → `common/rocky-mirrors.sh` 单源 +
   逐级换源重试;extras 仓库部分镜像缺失且不需要,已移除

历史构建纪要(2026-08 会话,含 Kylin 实机干跑记录)见
[docs/rpm-build-202608.md](../docs/rpm-build-202608.md)。
