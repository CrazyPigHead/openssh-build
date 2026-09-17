# deb 构建模块

在 Ubuntu 20.04 容器内构建三个 deb(静态内嵌加密栈):

| 包 | 内容 | 运行时依赖(Depends) |
|---|---|---|
| `openssh-client` | ssh/scp/sftp/ssh-add/ssh-agent/ssh-keygen/ssh-keyscan/ssh-copy-id + ssh-keysign(setuid)/ssh-pkcs11-helper/ssh-sk-helper;conffile `/etc/ssh/ssh_config` | libc6, libselinux1, libudev1 |
| `openssh-server` | sshd + sshd-session/sshd-auth(9.8+ 拆分二进制)、`/etc/ssh/{sshd_config,moduli}`、`/etc/pam.d/sshd`、`/etc/default/ssh`、systemd 单元、SysV init 兼容脚本 | 严格同版本 client/sftp-server, libpam0g, libpam-modules, libcrypt1, libaudit1, libselinux1, libc6 |
| `openssh-sftp-server` | `/usr/lib/openssh/sftp-server` | libc6 |

由顶层 `build.sh deb` 编排(用法见项目 [README.md](../README.md)),本模块包含:

- `Dockerfile`:工具链镜像(ubuntu:20.04 + 构建依赖,不含源码与版本)。
  选 20.04 作基底是为了 glibc 2.31 向前兼容,产物可装 20.04 及之后所有
  Ubuntu;focal 自带 cmake 3.16 满足 libcbor(≥3.5)/libfido2(≥3.7)
- `build.sh`:容器内全流程,亦可直接在任何 Ubuntu 20.04 宿主机上运行
  (需自装 Dockerfile 中列出的依赖)
- `rehearsal.sh`:彩排脚本,由顶层在**全新原生基底容器**(ubuntu:20.04)
  中执行,演练从发行版原生包升级到本构建的完整路径

## 构建流程(build.sh)

1. **物料**:`versions/<版本>.env` 定义的组合,从 `downloads/` 复用或自动
   下载;OpenSSH PGP 验签 + 其余 SHA256
2. **静态依赖**:OpenSSL(`no-shared no-zlib -fPIC`)→ zlib → libcbor →
   libedit → libfido2,全部装进工作目录 prefix,不污染系统
3. **OpenSSH**:`--with-ssl-dir`/`--with-zlib` 指向自建前缀实现静态内嵌;
   三处静态链接顺序修正(见下)
4. **冒烟测试**:容器内回环 sshd + 公钥登录、`zlib@openssh.com` 压缩、
   sftp 上传下载比对。树内二进制按编译期路径查找 sshd-session/sshd-auth/
   sftp-server(`/usr/lib/openssh`)与 `_PATH_SSH_PROGRAM`(`/usr/bin/ssh`),
   测试前临时软链、测毕清理(打包走 DESTDIR 不受影响)
5. **打包**:client/server/sftp 三树分发,strip(保留动态符号表)、
   md5sums、`dpkg-deb -Zxz`
6. **终验**:解包后 `ldd` 断言无 libcrypto/libssl/libz/libfido2/libcbor/
   libedit/libtinfo 动态依赖;包内字节 `ssh -V` 版本核对
7. **彩排**(默认开启,`--no-rehearsal` 跳过):构建成功后在全新
   ubuntu:20.04 容器中安装发行版原生 openssh(留管理员自定义配置)→
   `apt` 本地事务升级三个包(`--force-confold` 保留 conffile)→
   断言布局/privsep 用户/主机密钥/服务拉起/配置保留 → UsePAM 公钥登录、
   zlib 压缩、外部 sftp、internal-sftp、scp、升级后系统 `sshd -t` →
   版本与依赖清单复核(apt 换源回退见 `common/ubuntu-mirrors.sh`)

## 静态/动态链接策略

**静态内嵌**:libcrypto、libz、libcbor、libfido2、libedit、libtinfo ——
安装后与系统 OpenSSL/zlib 版本完全无关。

**保持动态**:libc6、libpam0g、libcrypt1、libselinux1、libaudit1 —— 全部为
Ubuntu/Debian **Priority: required** 基础库(任何可运行的 dpkg 系统必然存在),
且属于系统集成点(审计/SELinux/PAM),静态化无收益;`ssh-sk-helper` 额外
动态依赖 libudev1(focal 无静态 libudev)。

**三处静态链接顺序修正(缺一不可)**:

1. `LIBEDIT` 追加 `-ltinfo`(静态 libedit 的 termcap 符号需在其后解析);
2. `CHANNELLIBS` 追加 `-ldl -lpthread`(静态 libcrypto 的 dso_dlfcn.o /
   threads_pthread.o 符号需在 -lcrypto 之后解析);
3. `libfido2.pc` 的 `Requires` 补 `libudev libcbor`(pkg-config 输出完整静态链)。

修正以 `grep` 断言生效,OpenSSH 上游 Makefile 结构变化时会立即失败而非产出坏包。

## 版本与文件名

- 完整版本 `${DEB_EPOCH}:${OPENSSH_VER}-${DEB_REVISION}`(默认
  `1:10.5p1-1local2`),epoch=1 与 Ubuntu 原生包对齐
- 文件名采用 `%3a` 编码 epoch 冒号:**focal 的 apt 2.0.11 对文件名含冒号的
  本地 deb 会静默不动作**
- 维护脚本:preinst 建 sshd 特权分离用户(adduser 缺失时回退 useradd)、
  postinst 生成主机密钥(`ssh-keygen -A`)并启停服务、prerm/postrm 处理
  systemd/SysV

## 跨版本兼容(2026-08 容器实测)

| Ubuntu | glibc | 全新安装 | 完整登录 | 发行版包原地升级 |
|---|---|---|---|---|
| 20.04(构建基底) | 2.31 | ✅ | ✅ | ✅ |
| 22.04 | 2.35 | ✅ | ✅ | — |
| 24.04 | 2.39 | ✅ | ✅ | ✅(dpkg --force-confold) |
| 26.04 | 2.43 | ✅ | ✅ | — |

注意:Ubuntu 官方 openssh-server 用 ucf(非 dpkg conffile)管理
`/etc/ssh/sshd_config`,从官方包升级到本包时 dpkg 会询问;非交互加
`--force-confold` 保留系统原配置(已验证 Include/UsePAM/Subsystem 均兼容)。
每次构建的自动彩排在 20.04(构建基底)上完整演练上述升级路径(含 conffile
保留断言);上表其余发行版为 2026-08 手工实测。
仅支持 amd64(arm64 需给 Dockerfile 加交叉工具链)。

## OpenSSL 自测

默认 `SKIP_OPENSSL_TEST=1`:OpenSSL 官方 `make test` 的 DTLS/IPv6-loopback
类用例(`20-test_app_s_client_msg`、`90-test_sslapi`)在受限容器网络中会
非确定性挂起(宿主机原生全绿,与代码无关),容器内以端到端冒烟测试作功能
门禁。需要时 `SKIP_OPENSSL_TEST=0 ./build.sh deb` 启用(已跳过两个已知
挂起用例并带 timeout 兜底)。

## 调试

```bash
./build.sh deb --shell     # 进入构建容器(挂载与正式构建一致)
./build.sh deb --cache     # work/deb 挂载为 /work,重复构建增量进行
```

历史构建纪要(2026-08 会话,含验证细节)见
[docs/deb-build-202608.md](../docs/deb-build-202608.md)。
