return {
    fullname = "翻页器 / Page turner",
    version = "0.0.0-dev", -- 发布时由 CI 按 tag 注入
    description = [[蓝牙翻页器 + 想法选择器。
Bluetooth page turner + a thoughts picker.

· 接管 —— 自己找到翻页器的输入设备并接进 KOReader。按键由你在菜单里点「下一个 / 上一个 / 确认」各录一个手势（单击、连按 2~3 下、长按），单键、双键、三键都能用。
  Attach: finds the pager's input device itself. In the menu, record one gesture each for Next / Previous / Confirm (click, 2-3 quick clicks or long press); works with 1, 2 or 3 keys.
· 选择器 —— 确认进入选择模式，下一个 / 上一个选条目，再确认打开；弹窗里滚动内容，确认关闭。支持他人段评和自己带笔记的划线。
  Picker: Confirm enters select mode, Next / Previous move, Confirm opens; in a popup they scroll, Confirm closes. Works with others' reviews and your own notes.
· 跟着月读走 —— 月读里开蓝牙就补位拉起守护进程、接管翻页器；使用翻页器时不息屏。
  Follows Moon: turning Bluetooth on in Moon starts the daemon and attaches the pager; the screen stays awake while using the page turner.]],
}
