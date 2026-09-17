# Handoff:OpenSSH 10.5p1 + OpenSSL 4.0.2 静态内嵌 deb 构建(已完成)

> 会话日期:2026-08-28 ~ 2026-08-31 · 工作区:`/usr/local/src/zhz/openssh-build`
> 状态:**全部任务完成并验证**。本文件补充"文档之外的环境事实与教训",避免重复;详细规格见下引文件。

## 任务回顾(三阶段,均已完成)

1. **构建 deb**:OpenSSH 10.5p1(当前最新)+ OpenSSL 4.0.2(当前最新,静态内嵌 libcrypto),
   产出 client/server/sftp-server 三个 deb(版本 `1:10.5p1-1local2`),不在本机安装。
2. **答疑**:兼容性(20.04/22.04/24.04/26.04 容器实测全过)、依赖(仅 Priority: required 基础库)、安装方法。
   答疑期间发现并修复:24.04 精简镜像无 adduser(preinst 加 useradd 回退)、ssh_config GSSAPI 告警。
3. **容器化构建**:`docker/` 下 Dockerfile + build.sh + seed,全流程实测通过,产物在 `out-docker/`。

## 必读文件(按优先级,内容不在此重复)

| 文件 | 内容 |
|---|---|
| `README-local-build.md` | 总纲:版本组合、静态/动态策略、三处链接顺序修正、兼容性实测矩阵、安装方法、docker 用法、产物 sha256 |
| `docker/Dockerfile` + `docker/build.sh` | 规范可复现构建(自包含,含全部打包资产 heredoc 与关键注释) |
| `build-deb.sh`(工作区根) | 宿主机直构参考路径,步骤与 docker/build.sh 一致 |
| `openssh-portable-research.md` | 原始调研(用户提供的输入,2.7 节是静态内嵌原理依据) |
| `out/` 与 `out-docker/` | 宿主机版 / 容器版产物(内容功能等价,差异仅注释文本与 build-id) |

## 本机环境关键事实(新 agent 必知,未写入文档)

- **系统 sshd 监听 22121 端口**(非 22)。会话早期曾 `pkill -x sshd` 误杀系统 sshd,
  已恢复(`systemctl restart ssh`)。**切勿全局 pkill sshd**;管理测试 sshd 只用其 pidfile。
- 本机已装 `1:10.5p1-1local1`(更早的本地构建,动态链接 OpenSSL 1.1.1f);
  我们的 1local2 是其升级版。用户明确要求**不在本机安装**新包。
- `/home/npatch/install_npatch/openssh_packages/` 是部署方的历史产物目录,**不要改动**。
- 网络:需走代理 `http://127.0.0.1:1090` 访问 github 等(直连常被重置);代理对部分站点也不稳。
  docker hub 被拒,用 `docker.m.daocloud.io/library/ubuntu:<tag>` 拉镜像;apt 用清华源正常。
  容器内下载直连不可靠 → 这是引入 `docker/seed/` 离线源的直接原因。
- docker build 在本机需 `--network=host`(容器复用宿主代理与可达性)。
- 机器上跑着 kingbase 容器(端口 54321)与 postgres,别动。
- 后台 Bash 任务不带前台 shell 的代理环境变量——需要时在同一命令内显式 `env http_proxy=... docker build`。

## 教训速查(踩过的坑)

1. **focal apt 2.0.11**:deb 文件名含 `:`(epoch)会让 `apt install ./x.deb` 静默不动作 → 用 `%3a` 编码命名。
2. **OpenSSL 自测在容器中非确定挂起**:`20-test_app_s_client_msg`、`90-test_sslapi` 的 DTLS/IPv6-loopback
   s_server 产生孤儿进程占住测试管道(宿主机原生全绿)。容器默认 `SKIP_OPENSSL_TEST=1`。
3. **树内二进制的编译期路径**:`sftp -s` 会派生 `_PATH_SSH_PROGRAM`(/usr/bin/ssh);sshd 找
   /usr/lib/openssh/{sshd-session,sshd-auth,sftp-server}。容器冒烟测试需先软链、测毕清理(已内置)。
4. **静态链接顺序**:LIBEDIT 后补 `-ltinfo`;CHANNELLIBS 后补 `-ldl -lpthread`;libfido2.pc
   Requires 补 `libudev libcbor`。三者缺一不可(详见 README)。
5. **curl 的 `--retry` 不覆盖 exit 52/56**(重置/空响应),需 bash 级重试循环 + `--speed-time/--speed-limit` 防停滞。
6. `dpkg-shlibdeps` 需要 `debian/control` 存在;用极简 stub 目录即可计算精确 Depends。
7. 升级覆盖 Ubuntu 官方包时 `sshd_config` 会弹 conffile 询问(官方用 ucf 管理);非交互加 `--force-confold`。

## 版本升级方法(若下次要更新)

1. 替换 `docker/seed/` 内 tarball(OpenSSH 含 .asc 签名),同步 `docker/build.sh` 顶部版本号与校验值
   (OpenSSH 用 PGP 指纹 `7168 B983 815A 5EEF 59A4 ADFD 2A3F 414E 7360 60BA`,其余 SHA256);
2. 确认新 OpenSSL 与 OpenSSH 兼容(查上游 CI 矩阵 `.github/workflows/c-cpp.yml`);
3. `docker build --network=host ...` → `docker run -v ...:/host-out` 取件;
4. 复验:out-docker 产物在 24.04 容器跑 `/tmp/debtest.sh`(若还在)或按 README 验证清单。

## 可选后续(无未完成事项)

- 新版发布后重打(方法如上);deb 签名;GSSAPI 子包(参考 Debian openssh-gssapi 拆分);
  arm64 交叉构建(需改 Dockerfile 加 cross 工具链);`docker build --output` 取件方式。

## Suggested skills

- `research`:调研 OpenSSH/OpenSSL 新版本、上游兼容性矩阵时使用。
- `learn-session`:若希望把本会话的教训(上述"教训速查")固化为仓库级规则可调用。
- `diagnosing-bugs`:后续构建/安装出问题时进入系统化排障流程。
