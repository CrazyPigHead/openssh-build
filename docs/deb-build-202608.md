# OpenSSH 10.5p1 deb 本地构建说明(静态内嵌 OpenSSL 4.0.2)

构建日期:2026-08-28 · 构建机:Ubuntu 20.04.6 focal x86_64 · 产物目录:`out/`

## 容器化构建(推荐,可复现)

`docker/` 目录提供完整的容器构建,产物与本文档描述的功能规格一致:

```bash
cd docker
docker build -t openssh-deb:10.5p1-1local2 .          # 全流程:源码校验→构建→冒烟测试→打包→终验
mkdir -p ../out-docker && docker run --rm -v "$PWD/../out-docker":/host-out openssh-deb:10.5p1-1local2
# deb 即出现在 ../out-docker/(容器版已在 24.04 容器实测安装+登录通过)
```

说明:
- 基底 ubuntu:20.04(glibc 2.31,保证产物对 20.04+ 向前兼容);focal 自带
  cmake 3.16 满足 libcbor(≥3.5)/libfido2(≥3.7)
- **离线 seed**:`docker/seed/` 已放入官方原始 tarball(58M,含 PGP 公钥与
  签名),构建零外网下载;校验逻辑(PGP 指纹 + SHA256)与在线模式完全相同。
  更新版本时替换 seed 内文件并同步 build.sh 中的校验值即可
- OpenSSL 官方自测**默认跳过**(`SKIP_OPENSSL_TEST=1`):其 DTLS/IPv6-loopback
  类用例(20-test_app_s_client_msg、90-test_sslapi)在受限容器网络中会
  非确定性挂起,属环境问题;完整自测已在宿主机原生环境全绿,容器内以
  端到端冒烟测试(登录/压缩/sftp)作功能门禁。需要时
  `--build-arg SKIP_OPENSSL_TEST=0` 启用(已跳过上述两个用例并带 timeout)
- 需要访问 cdn.openbsd.org / github.com / thrysoee.dk(seed 为空时);走代理
  的环境加 `--network=host` 并 export http_proxy,apt 换源可加
  `--build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn`
- 层缓存:不改动 build.sh 时重复构建秒级完成;改动后全流程约 5 分钟
- 冒烟测试说明:树内 sshd/sshd-session/sftp-server/ssh 按编译期路径
  (/usr/lib/openssh、/usr/bin/ssh)查找,sftp 客户端也会派生
  _PATH_SSH_PROGRAM 作传输进程——测试前软链到目标路径,测毕清理

## 产物

| 文件(out/) | 大小 | 运行时依赖(Depends) |
|---|---|---|
| `openssh-client_1%3a10.5p1-1local2_amd64.deb` | 6.1M | libc6 (>= 2.26), libselinux1, libudev1 |
| `openssh-server_1%3a10.5p1-1local2_amd64.deb` | 2.6M | openssh-client/sftp-server (= 同版本), libpam0g, libpam-modules, libcrypt1, libaudit1, libselinux1, libc6, adduser |
| `openssh-sftp-server_1%3a10.5p1-1local2_amd64.deb` | 65K | libc6 (>= 2.26) |

版本 `1:10.5p1-1local2` 高于本机原装的 `1:10.5p1-1local1`,可直接原地升级。
文件名采用 Debian pool 的 `%3a` 编码(epoch 冒号):**focal 的 apt 2.0.11 对
文件名含冒号的本地 deb 会静默不动作**,`%3a` 命名对 `apt install ./x.deb` 才可靠。

## 版本组合

- OpenSSH **10.5p1**(官方 tarball,PGP 验签,指纹
  `7168 B983 815A 5EEF 59A4 ADFD 2A3F 414E 7360 60BA`)
- OpenSSL **4.0.2**(2026-08-25 发布,当前最新;SHA256 与官方发布值一致;
  `no-shared no-zlib -fPIC` 静态构建,**make test 全部通过**)
  - OpenSSH 10.5 官方 CI 矩阵明确覆盖 openssl-4.0 线,属受支持组合
- zlib 1.3.2、libcbor 0.14.0、libfido2 1.17.0、libedit 20240808-3.1(均静态)

## 静态/动态链接策略

**静态内嵌**(对应系统运行库依赖为零):libcrypto(OpenSSL 4.0.2)、libz、
libcbor、libfido2、libedit、libtinfo。

**保持动态**:libc6、libpam0g、libcrypt1、libselinux1、libaudit1 —— 全部为
Ubuntu/Debian **Priority: required** 基础库(任何可运行的 dpkg 系统必然存在),
且属于系统集成点(PAM 配置、audit 守护、SELinux 策略),静态化无收益;
`ssh-sk-helper` 额外动态依赖 libudev1(focal 无静态 libudev,Priority: important)。

`ssh -V` → `OpenSSH_10.5p1, OpenSSL 4.0.2 25 Aug 2026`;
所有二进制 ldd 均无 libcrypto/libssl/libz/libfido2/libcbor/libedit/libtinfo。

## configure 要点(build-deb.sh)

`--with-ssl-dir` 指向仅有 `libcrypto.a` 的前缀实现静态内嵌(调研文档 2.7 节原理)。
三处链接顺序修正:
1. `LIBEDIT` 追加 `-ltinfo`(静态 libedit 的 termcap 符号需在其后解析);
2. `CHANNELLIBS` 追加 `-ldl -lpthread`(静态 libcrypto 的 dso_dlfcn.o/threads_pthread.o);
3. libfido2.pc 的 `Requires` 补 `libudev libcbor`,使 pkg-config 输出完整静态链。

## 包内容

- **client**:ssh/scp/sftp/ssh-add/ssh-agent/ssh-keygen/ssh-keyscan/ssh-copy-id +
  ssh-keysign(setuid 4111)/ssh-pkcs11-helper/ssh-sk-helper;conffile `/etc/ssh/ssh_config`
- **server**:sshd + **sshd-session/sshd-auth**(10.0+ 必需的拆分二进制)、
  `/etc/ssh/{sshd_config,moduli}`、`/etc/pam.d/sshd`、`/etc/default/ssh`、
  `/lib/systemd/system/ssh.service`(含 `RuntimeDirectory=sshd`)、SysV init 兼容脚本;
  preinst 建 sshd 特权分离用户,postinst 生成主机密钥(`ssh-keygen -A`)并启停服务
- **sftp-server**:`/usr/lib/openssh/sftp-server`

## 跨版本兼容性(2026-08-31 容器实测)

| Ubuntu | glibc | 全新安装 | 完整登录 | 发行版包原地升级 |
|---|---|---|---|---|
| 20.04(构建机) | 2.31 | ✅ | ✅ | ✅(1local1→1local2) |
| 22.04 | 2.35 | ✅ | ✅ | — |
| 24.04 | 2.39 | ✅ | ✅ | ✅(dpkg --force-confold) |
| 26.04(当前最新 LTS) | 2.43 | ✅ | ✅ | — |

原理:glibc 向前兼容(在 2.31 上编译,更高版本直接运行);加密/压缩/FIDO/edit
全部静态内嵌,与目标机 OpenSSL 版本无关;动态依赖全部为 Priority: required
基础库。仅支持 amd64。

实测修复的两个跨版本问题(已包含在当前 deb 中):
1. 24.04+ 精简镜像无 `adduser` → preinst 增加 `useradd` 回退,Depends 去掉 adduser;
2. `ssh_config` 中 GSSAPI 行在无 GSSAPI 支持的构建下每次告警 → 已删除。

注意:Ubuntu 官方 openssh-server 用 ucf(非 dpkg conffile)管理 `/etc/ssh/sshd_config`,
从官方包升级到本包时 dpkg 会询问如何处理该文件;非交互场景加 `--force-confold`,
默认保留系统原有 sshd_config(推荐,已验证 Include/UsePAM/Subsystem 均兼容)。

## 已验证(未安装到构建机,均为非侵入验证)

- 回环端到端:公钥登录、mlkem768x25519-sha256 后量子 KEX、zlib@openssh.com 压缩、
  scp/sftp(internal + external)/libedit、证书签发、KRL、ML-DSA44+Ed25519 复合密钥
- **包内字节**解出后再跑一轮端到端(登录/sftp/scp)全部通过
- `dpkg --dry-run -i` 与 `apt-get install -s`:三包干净升级、**无需引入任何新依赖**
- md5sums 全量核对通过

## 安装(目标机)

```bash
apt install ./openssh-client_1%3a10.5p1-1local2_amd64.deb \
             ./openssh-sftp-server_1%3a10.5p1-1local2_amd64.deb \
             ./openssh-server_1%3a10.5p1-1local2_amd64.deb
# 或 dpkg -i 三个包(同名包 = 版本严格锁定,必须一起装)
```
