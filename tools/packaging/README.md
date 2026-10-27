# Hue（master）可重定位双架构打包

在 Rocky Linux 8.10 容器中编译 **当前仓库 master 线**（含 Trino 原生 connector），产出面向 **Kylin V10 / CentOS 8+** 的解压即用 tar 包（`x86_64` / `aarch64`）。

说明：上游 `VERSION` 仍可能显示 `4.11.0`，产物文件名会带 `master-<日期>-<commit>` 以免和旧 release 包混淆。

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
hue-4.11.0-master-YYYYMMDD-<sha>-linux-x86_64.tar.gz
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

## 一键启动

```bash
tar -xzf hue-*-linux-x86_64.tar.gz
cd hue
./bin/start.sh      # 默认 SQLite：data/desktop.db
./bin/status.sh
./bin/stop.sh
```

浏览器访问：`http://<host>:8888`（可用 `conf` 改为 8000）

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

## 设计说明

- 构建基镜像：`rockylinux:8.10`
- Python：`PYTHON_VER=python3.11`（Hue master 默认）
- Trino：`trino==0.329.0`（master requirements）+ `options.verify` 补丁
- 流程：`make install` → relocatable → 目录重排 → embed-python → 打 tar
- 打包脚本在 `tools/packaging/`；`verify` 补丁在源码 `desktop/libs/notebook/.../trino.py`
