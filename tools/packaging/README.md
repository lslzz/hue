# Hue（20250903-140101 + packaging）可重定位双架构打包

在 Rocky Linux 8.10 容器中编译 **tag `20250903-140101` 基线**（Django 4.1，便于对接 **MySQL 5.7**），叠加本目录 packaging、Trino `options.verify`、`polars-lts-cpu`，产出面向 **Kylin V10 / CentOS 8+** 的解压即用 tar 包（`x86_64` / `aarch64`）。

说明：上游 `VERSION` 仍为 `4.11.0`，产物文件名带 `20250903-<日期>-<commit>`。

## 一键打包

```bash
# 当前机器架构（需在 master 分支上）
./tools/packaging/build-tarball.sh

# 指定架构 / 双架构
./tools/packaging/build-tarball.sh --arch amd64
./tools/packaging/build-tarball.sh --arch arm64
./tools/packaging/build-tarball.sh --arch all

# 已有构建镜像时跳过 docker build
./tools/packaging/build-tarball.sh --skip-image --arch amd64
```

产物目录：`dist/packaging/`

```
hue-4.11.0-20250903-YYYYMMDD-<sha>-linux-x86_64.tar.gz
```

## 包目录结构

```
hue/
  bin/      start.sh stop.sh status.sh hue
  conf/     hue.ini + z-10-defaults.ini + …
  etc/      build-info、环境变量示例
  lib/      hue/（安装树） native/（自带 .so） python-runtime/（嵌入式 3.11）
  LICENSE NOTICE
  logs/ run/ data/
  sbin/     migrate.sh
  shell/    hue-shell.sh
  util/     env.sh db-select.sh …
  www/      static → 静态资源
```

## 一键启停（统一入口）

```bash
tar -xzf hue-*-linux-x86_64.tar.gz
cd hue
./bin/huectl start      # 默认 SQLite：data/desktop.db
./bin/huectl status
./bin/huectl restart
./bin/huectl stop
# 仍保留 ./bin/start.sh|stop.sh|status.sh 兼容旧用法
```

浏览器访问：`http://<host>:8000`（见 `conf/z-10-defaults.ini`）

默认已关闭 Oozie/Job Designer（`app_blacklist=oozie,jobsub`，`oozie_url=`），避免连 `localhost:11000`。调度请用 DolphinScheduler 等外部系统；若确需 Oozie，再在更高优先级 ini 里改回。

### Hive + Trino + HBase

```bash
cp conf/z-20-cluster.ini.example conf/z-20-cluster.ini
# 按集群改 Hive/Trino/HBase；Trino 自签 HTTPS 用 verify:false
# HBase 填的是 Thrift Server（常见 9090），且需 buffered 传输
./bin/start.sh
```

### 使用外部 MySQL

```bash
cp conf/z-90-database.mysql.ini.example conf/z-90-database.ini
# 编辑 host/user/password/name
./bin/start.sh
```

规则：`conf/` 里若存在未注释的 `engine=mysql|postgresql|oracle`，则用外部库；否则自动写 `z-95-sqlite.ini` 使用内置 SQLite。

## 目标机依赖说明

已尽量打进 `lib/native`（sasl/xml/ssl/ldap/krb/mariadb client 等），并嵌入 **Python 3.11** 运行时。仍需要：

- 同架构（x86_64 或 aarch64）
- glibc ≥ 2.28（EL8 / Kylin V10 一代）
- 内核与基础用户态
- **cyrus-sasl-plain**（HiveServer2 等 Thrift SASL PLAIN 握手必需）。注意：`lib/native` 只带 libsasl2 核心库，PLAIN 等机制插件（`libplain.so`）是运行时 dlopen 加载的，**打包带不上**，必须由目标机系统提供
- 走 Kerberos（GSSAPI）时另需 `cyrus-sasl-gssapi`

安装与验证：

```bash
yum install -y cyrus-sasl-plain
# 离线机器：从 Kylin V10 SP3 同架构 ISO 的 Packages/ 中 rpm -Uvh cyrus-sasl-plain-*.rpm，
# 或从任一同架构节点拷 /usr/lib64/sasl2/libplain.so 过来即可
ls /usr/lib64/sasl2/ | grep -i plain   # 应出现 libplain.so
```

缺失时的典型症状：页面报 `Could not start SASL: SASL(-4): no mechanism available: No worthy mechs found`，左侧 Databases 列表显示 `Error loading databases`。

## 设计说明

- 构建基镜像：`rockylinux:8.10`
- Python：`PYTHON_VER=python3.11`（Hue master 默认）
- Trino：`trino==0.329.0`（master requirements）+ `options.verify` 补丁
- 流程：`make install` → relocatable → 目录重排 → embed-python → 打 tar
- 打包脚本在 `tools/packaging/`；`verify` 补丁在源码 `desktop/libs/notebook/.../trino.py`
