# Snell v4/v5/v6 一键管理脚本

同一台 VPS 上共存 Snell v4、v5、v6，可交互添加多个实例，并支持菜单里一键升级 v4/v5/v6。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/m4802222/snell-onekey/main/install.sh)
```

也可以直接运行主脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/m4802222/snell-onekey/main/snell-onekey.sh)
```

## 菜单功能

```text
1. 添加 Snell 实例
2. 查看实例和流量
3. 启停/日志/删除
4. 一键升级全部版本
0. 退出
```

## 支持版本

- Snell v4: `4.1.1`
- Snell v5: `5.0.1`
- Snell v6: `6.0.0b3`

## 说明

- 每个实例都是独立的 `snell@实例名` systemd 服务。
- 配置目录：`/etc/snell-multi`
- 二进制目录：`/opt/snell-multi/bin`
- 流量显示优先使用 systemd `IPAccounting=true`。
- 记得在云厂商安全组或防火墙放行实例端口。
