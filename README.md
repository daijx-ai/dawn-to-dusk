# Dawn to Dusk

**Dawn to Dusk**（中文名「朝夕」）是一款面向 macOS 的原生日程与待办应用。它把有日期的安排放在「日程」，把尚未安排日期的事项放在「清单」，并用桌面浮窗、时间提醒和本地数据保存帮助用户查看当天安排。

`Dawn to Dusk` 是公开仓库的英文项目名；这份候选构建的应用包仍显示为「朝夕」。

## 功能

- 日程与跨天保留的待办清单
- 每天或工作日重复安排，按日期分别记录完成状态
- 「稍后提醒」与「推迟这次安排」分开处理
- 系统本地通知、菜单栏入口、小窗、置顶和多种外观
- 本地 JSON 存储、备份导出与恢复
- 本机捕获和只读查询命令行接口
- 可选飞书主日历只读同步；不会向飞书写入

## 系统要求

- macOS 15 或更新版本
- Apple Silicon
- Xcode Command Line Tools

## 构建和运行

```sh
./scripts/build.sh
open build/朝夕.app
```

运行检查脚本：

```sh
./scripts/test.sh
```

应用数据保存在 `~/Library/Application Support/Chaoxi/agenda.json`。日程核心功能使用本机数据；飞书同步需要另行安装并登录 `lark-cli`，当前查找路径为 `~/bin/lark-cli`。飞书数据只读主日历，并按应用设置定期刷新。

Hermes 捕获辅助脚本位于 `Integrations/Hermes/chaoxi-capture/scripts/capture.py`，通过标准输入接收 JSON，并调用 `~/Applications/朝夕.app` 的本机命令行入口。Clawd 桌面宠物桥接仍是本地定制内容，不包含在这个公开仓库中。

## 版本

当前应用包版本为 **1.1.2 (build 5)**。这是候选源码快照，尚未作为稳定版发布；候选版本标识为 `v1.1.2-preview.5`，稳定标签 `v1.1.2` 只在完成验收后发布。

## 许可

本项目尚未指定整体代码许可。`Resources/Maccy-LICENSE.txt` 只适用于从 Maccy 参考并改编的原生材质代码，不代表朝夕其余部分采用相同许可。
