# Snell Onekey

Snell v4/v5/v6 一键安装和管理脚本，面向 Surge 使用。

## systemd 多实例版

适合 Debian、Ubuntu 等 `systemd` 系统。支持多个 Snell 实例、流量统计、流量上限和菜单管理。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/m4802222/snell-onekey/main/install.sh)
```

安装后运行：

```bash
snell
```

菜单：

```text
1. 添加 Snell 实例
2. 查看实例和流量
3. 启停/日志/删除
4. 一键升级全部版本
0. 退出
```

添加实例后会输出两部分信息：

```text
安装完成，复制下面配置即可：
name = snell, SERVER_IP, PORT, psk=PSK, version=5

服务启动详情：
实例: name
systemd is-active: active
systemd status:
...
```

## Snell v4 Standalone

适合 Alpine/OpenRC，或只需要单个 Snell v4 节点的服务器。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/m4802222/snell-onekey/main/install-snell-v4-standalone.sh)
```

默认行为：

- Snell v4.1.1
- 随机未占用端口
- 随机 PSK
- 配置文件：`/etc/snell/snell-server.conf`
- 服务名：`snell-server`

指定参数示例：

```bash
SNELL_PORT=20151 bash <(curl -fsSL https://raw.githubusercontent.com/m4802222/snell-onekey/main/install-snell-v4-standalone.sh)
SNELL_PSK='your-fixed-psk' bash <(curl -fsSL https://raw.githubusercontent.com/m4802222/snell-onekey/main/install-snell-v4-standalone.sh)
SNELL_IPV6=true bash <(curl -fsSL https://raw.githubusercontent.com/m4802222/snell-onekey/main/install-snell-v4-standalone.sh)
```

## 版本

- Snell v4: `4.1.1`
- Snell v5: `5.0.1`
- Snell v6: `6.0.0b3`

## 路径

多实例版：

- 配置：`/etc/snell-multi`
- 二进制：`/opt/snell-multi/bin`
- 流量数据：`/var/lib/snell-multi`
- 服务：`snell@实例名`

Standalone：

- 配置：`/etc/snell/snell-server.conf`
- 二进制：`/usr/local/bin/snell-server`
- 服务：`snell-server`

## 注意

- 多实例版依赖 `systemd` 和 `IPAccounting=true`。
- Alpine/OpenRC 使用 Snell v4 Standalone。
- 脚本会尝试放行本机防火墙端口。
- 云厂商安全组仍需手动放行对应 TCP 端口。
