# CodexQuotaBar

原生 macOS 菜单栏插件，用于查看 Codex 的 5 小时与 7 天额度。

## 功能

- 菜单栏两行显示 5 小时与 7 天剩余额度。
- 详情页显示剩余进度条、额度重置时间，以及当前 5 小时窗口内的用量变化。
- Token 区域显示账号累计值和最近可用日期的日汇总；日汇总可能延迟，不代表实时任务用量，也不能换算成额度百分比。
- 深色模式使用绿色与青柠色额度提示，并采用 macOS 原生毛玻璃面板。

## 数据来源

通过本机 Codex CLI 的 `app-server` 读取 `account/rateLimits/read` 和 `account/usage/read`。额度百分比来自服务端读数。插件不读取或保存登录令牌。

7 天卡片中的 `7天 −X%` 按每次 5 小时额度重置重新建立基线。如果插件在本轮 5 小时开始后才启动，会等到下一次重置后再显示完整一轮的变化。

## 构建与运行

需要 macOS、Swift 编译器，以及已安装并登录的 Codex 桌面应用或 CLI。

```sh
swiftc -O -framework AppKit -framework SwiftUI CodexQuotaBar.swift -o CodexQuotaBar
./CodexQuotaBar
```

刷新间隔为 60 秒；详情页右上角可手动刷新。
