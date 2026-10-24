# 翻页器 pageturner.koplugin

Kindle 上 KOReader 的蓝牙翻页器插件，外加一个「想法选择器」：用翻页器直接选中并打开当前页的想法（他人段评和自己带笔记的划线），不用碰屏幕。

A Bluetooth page-turner plugin for KOReader on Kindle, plus a picker that lets the pager select and open the thoughts (others' reviews and your own notes) on the current page.

## 功能

- **接管翻页器**：自己找到翻页器的输入设备并接进 KOReader，热插拔、设备重建后自动重新接管，不需要 externalkeyboard。
- **自定义手势**：下一个 / 上一个 / 确认各录一个手势（某个键的单击、连按 2~3 下、长按），单键、双键、三键翻页器都能用。
- **想法选择器**：确认进入选择模式，当前页的段评和带笔记的划线依次高亮，再确认打开，弹窗里可滚动。
- **联动月读**：月读里开蓝牙就补位拉起守护进程、接管翻页器、自动连上；翻页器连着时不息屏。没装月读也能正常使用。
- **多语言**：简体中文、繁体中文、English，跟随 KOReader 语言。

## 前置条件

- Kindle + KOReader。
- 翻页器经 [kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough) 守护进程接入（装在 `/mnt/us/kindle_hid_passthrough`，它把蓝牙翻页器变成虚拟键盘 `/dev/input/eventX`）。插件会按需拉起 `main.bin --daemon`。
- 想法选择器里的段评来自[月读](https://github.com/AnkioTomas/moon)；没装月读时只有自己带笔记的划线可选。

## 安装

把整个 `pageturner.koplugin` 目录复制到 KOReader 的 `plugins/` 下（Kindle 上是 `/mnt/us/koreader/plugins/`），重启 KOReader。

## 使用

1. 菜单：齿轮 → 网络 → **翻页器** → **绑定翻页器按键**。
2. 按提示依次为「下一个」「上一个」「确认」在翻页器上做一个手势，做完稍等。同一个手势不能绑两次，走完三步才生效。
3. 例子：
   - 三键：三个键各单击。
   - 双键：两个键各单击，确认录成某个键连按两下。
   - 单键：单击=下一个，双击=上一个，三击=确认。

> 同一个键上绑了连按时，单击要多等约 0.4 秒才能确认不是连按。
> 长按只在翻页器按住期间真的不松开时才有；不少翻页器按下和松开是同时发的，录不到长按，请改用连按。

### 选择模式

| 动作 | 正常读书 | 选择模式 | 弹窗里 |
| --- | --- | --- | --- |
| 下一个 / 上一个 | 翻页 | 选下一条 / 上一条 | 滚动内容 |
| 确认 | 进入选择模式 | 打开选中项 | 关闭弹窗并回到读书 |

翻页或跳转会自动退出选择模式。

### 菜单

装了月读时，同样的入口也在月读设置 → 阅读 → 翻页器 页里。

- **翻页器状态**：绑定、守护进程、已接管设备、月读蓝牙与连接状态。
- **翻页器连着时不息屏 / 蓝牙开了自动连翻页器**：两个开关，默认开。
- 守护进程不用管：装了月读由月读的蓝牙开关拉起，没装月读则插件启动时自己拉（需要 KHP）。

## 排错

- 按键没反应：看「翻页器状态」里有没有已接管设备；设备每 10 秒自动重扫一次，重连后稍等即可。
- 日志在 `/mnt/us/koreader/crash.log`，搜 `[pageturner`。

## 文件

| 文件 | 作用 |
| --- | --- |
| `main.lua` | 手势识别与绑定、选择模式、菜单、生命周期 |
| `pageturner_input.lua` | 找到并打开翻页器的输入设备，交给 KOReader |
| `pageturner_moon.lua` | 联动月读的蓝牙开关，翻页器连着时不息屏 |
| `pageturner_thoughts.lua` | 收集当前页可选的想法（段评 / 带笔记的划线） |
| `pageturner_l10n.lua` | 界面翻译 |
| `moon_source.lua` | 在月读里登记扩展 id `ext.pageturner` |

模块名都带 `pageturner_` 前缀：`require("input")` 这类名字会撞上 KOReader 自带模块。
