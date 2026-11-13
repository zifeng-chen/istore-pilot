# v1.1.0 图标重设计说明

本次重设计 7 个图标：

| 图标 | 设计语义 |
|---|---|
| network-settings | 中心网络节点与四向连接，表达网络拓扑配置 |
| broadband | WAN 无线链路与终端设备，表达宽带接入 |
| rules-refresh | 规则列表与循环箭头，表达规则同步/刷新 |
| ipv4 | 独立地址卡片与 IPv4 数字结构 |
| ipv6 | 独立地址卡片与 IPv6 数字结构 |
| system-update | 系统设备与向上更新箭头 |
| restart-router | 路由器设备轮廓与环形重启箭头 |

统一规范：24×24 viewBox、2px stroke、round cap/join、currentColor。

## v1.1.1：IPv4 / IPv6 可读性修正

- 移除 24px 画布内过度拥挤的手绘字母路径。
- 改为统一地址标签外框，内部使用清晰的矢量文本 `IPv4` / `IPv6`。
- 两个图标仅以版本数字区分，缩放时保持清晰，继承 `currentColor`。
