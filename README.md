# Xray-Reality

Xray VLESS + Reality 一键安装配置脚本，交互式引导完成端口、伪装域名、密钥生成，并可选启用 WARP WireGuard 出站分流。

## 特性

- 自动检测并安装 Xray-core（官方安装脚本）
- 自定义监听端口，15 秒内不输入自动生成随机端口
- 自定义伪装域名，默认 `www.tesla.com`
- 自动生成 x25519 密钥对、UUID、Short ID
- 可选启用 WARP 分流（参考 [Xray 官方文档](https://xtls.github.io/document/level-2/warp.html) 方法一，通过 `wgcf` 注册生成 WireGuard 出站）
  - 自定义分流规则：直接填服务名（如 `openai,netflix`）自动转换为 `geosite:openai,geosite:netflix`，也支持完整域名或 `geosite:xxx` / `geoip:xxx` 显式写法
  - 单独询问是否将回国流量（`geosite:cn` + `geoip:cn`）也分流至 WARP
- 生成配置前自动执行 `xray run -test` 校验，通过后再重启服务
- 安装完成输出连接信息及 `vless://` 分享链接

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/lanjiangqaq/Xray-Reality/main/Realityinstall.sh)
```

## 使用说明

脚本需以 root 权限运行，按提示依次输入：

1. 监听端口（回车或超时使用随机端口）
2. 伪装域名（回车默认 `www.tesla.com`）
3. 是否启用 WARP 分流（`y`/`n`）
   - 若启用，继续输入自定义分流规则和是否分流回国流量

安装完成后配置文件位于 `/usr/local/etc/xray/config.json`，可通过以下命令管理服务：

```bash
systemctl restart xray   # 重启
systemctl status xray    # 查看状态
journalctl -u xray -f    # 查看日志
```

## 免责声明

本脚本仅供学习交流网络技术使用，请遵守当地法律法规。
