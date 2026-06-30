# Snell v4/v5/v6 一键管理脚本

同一台 VPS 上共存 Snell v4、v5、v6，可交互添加多个实例，并支持菜单里一键升级 v4/v5/v6。

本仓库同时提供一个 Snell v4 standalone 安装脚本，适合 Alpine/OpenRC 或只需要部署一个 Surge Snell v4 节点的场景。

## systemd 多实例管理安装

```bash
bash <(curl -fsSL https://github.com/m4802222/snell-onekey/raw/main/install.sh)
```

安装后运行：

```bash
snell
```

也可以直接运行主脚本：

```bash
bash <(curl -fsSL https://github.com/m4802222/snell-onekey/raw/main/snell-onekey.sh)
```

> 多实例管理脚本依赖 `systemd` 和 `IPAccounting=true` 统计流量。Alpine/OpenRC 请使用下面的 standalone 脚本。

## Snell v4 standalone 安装

适合：

- Alpine/OpenRC
- Debian/Ubuntu/systemd 但只需要单个 Snell v4 服务
- Surge 客户端使用 Snell v4

```bash
bash <(curl -fsSL https://github.com/m4802222/snell-onekey/raw/main/install-snell-v4-standalone.sh)
```

默认：

- Snell 版本：`v4.1.1`
- 监听端口：随机未占用端口
- 配置路径：`/etc/snell/snell-server.conf`
- 服务名：`snell-server`
- 自动生成随机 PSK
- 自动验证实际端口是否监听
- 输出 Surge 配置：

```text
snell, YOUR_SERVER_IP, RANDOM_PORT, psk=YOUR_GENERATED_PSK, version=4
```

可选参数：

```bash
SNELL_PORT=20151 bash <(curl -fsSL https://github.com/m4802222/snell-onekey/raw/main/install-snell-v4-standalone.sh)
SNELL_PSK='your-fixed-psk' bash <(curl -fsSL https://github.com/m4802222/snell-onekey/raw/main/install-snell-v4-standalone.sh)
SNELL_IPV6=true bash <(curl -fsSL https://github.com/m4802222/snell-onekey/raw/main/install-snell-v4-standalone.sh)
```

## 菜单功能

```text
1. 添加 Snell 实例
2. 查看实例和流量
3. 启停/日志/删除
4. 一键升级全部版本
0. 退出
```

添加实例时只需要选择版本，直接回车默认安装 v5：

- 实例名自动使用 VPS 主机名并按顺序编号，例如 `myvps-1`、`myvps-2`
- 端口可自定义，留空随机选择未占用端口
- PSK 自动生成
- obfs 默认关闭；v4/v5 不输出 `obfs=tls`
- 可设置每月流量上限，单位 GB，留空为不限
- 安装完成后只输出可直接复制的 Surge 节点配置
- 设置流量上限后，系统会每 1 分钟检查一次，超过上限自动停用对应实例
- 每个实例按安装时间作为月周期起点；下个月同一时间自动清零并重新启动
- 实例列表会显示距离下次自动重置的剩余天数
- 流量会累计保存到 `/var/lib/snell-multi`，服务重启后不会从 0 重新算
- 生成配置时会自动放行本机防火墙端口；流量用完自动停止实例并关闭本机端口
- 已超限实例不能手动启动、重启、检测连接或升级重启，等下个计费周期自动恢复
- 实例操作菜单支持“周期内流量重置”，可手动清零当前周期流量并重新启动
- 旧 v4/v5 实例如果误写了 `obfs=tls`，脚本会自动修复；菜单里也可选择“修复配置”和“复制配置”

## 支持版本

- Snell v4: `4.1.1`
- Snell v5: `5.0.1`
- Snell v6: `6.0.0b3`

## 说明

- 每个实例都是独立的 `snell@实例名` systemd 服务。
- 多实例脚本只支持 systemd；Alpine/OpenRC 使用 `install-snell-v4-standalone.sh`。
- 实例选择菜单会显示实例名、版本、端口、状态、已用流量和上限，方便直接选择。
- 实例操作支持启动、停止、重启、状态、日志、删除、复制配置、修复配置、检测连接和周期内流量重置。
- 配置目录：`/etc/snell-multi`
- 二进制目录：`/opt/snell-multi/bin`
- 累计流量目录：`/var/lib/snell-multi`
- 流量显示基于 systemd `IPAccounting=true` 并做本地累计保存，列表为中文并显示已用流量和流量上限。
- 自动停用和下月恢复依赖 `snell-limit-check.timer`，每 1 分钟检查一次。
- 脚本会尝试处理本机 `ufw`、`firewalld` 或 `iptables` 端口；云厂商安全组仍需你在控制台单独配置。
- Snell v4 是 Surge 使用的协议版本；添加节点时使用脚本输出的 `snell, ... version=4` 配置行。
