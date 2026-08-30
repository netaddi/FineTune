# 固定 Console 1 轨道

FineTune 可以为每个置顶 App 常驻一枚 Softube Console 1 Audio
Unit。这个实例归属于 App 的持久化标识，而不是临时的进程 ID、
audio tap 或输出设备，因此普通的 App 重启与路由切换不会分配新的
Console strip。

## 准备条件

- 在启动 FineTune 之前安装并激活 Console 1 AUv2 插件。
- 让目标 App 至少输出过一次音频，使它出现在 FineTune 中。
- Console 1 只支持 App 效果链。FineTune 会故意将它从输出设备效果链
  中排除，因为设备宿主可能是临时的。
- 每个 App 效果链最多只能包含一枚 Console 1。

## 配置 strip

1. 打开 FineTune 的编辑模式，置顶目标 App。
2. 展开该 App 的 EQ/效果面板。
3. 选择 **Add Effect**，搜索 **Console 1**，并加入 Softube 插件。
4. 对其他需要持久 strip 的 App 重复上述操作。
5. 为每个符合条件的 App 选择 **Console 1 startup order → Next
   launch #N**。把 App 移到已占用的位置时，两个位置会交换。
6. 退出并重新打开 FineTune。App 行上显示的是下次启动顺序；修改它不会
   销毁或重新编号已在运行的实例。

这个数字是确定性的 *FineTune 启动顺序*，不是绝对的 Softube 轨道号。
Console 1 会在 Mac 上所有宿主中选择最低的空闲轨道。如果 DAW 或其他
Audio Unit 宿主已占用更低的轨道，而你又需要精确的轨道号，请先关闭这些
宿主，再重启 FineTune。

## 持久化边界

对符合条件的置顶 App，FineTune 会在 App 不活跃时保留 Console 1 实例，
也会跨进程重启、tap 重建、输出切换和普通的插件/效果链旁路保留它。因此，
旁路不会释放启动位置。删除 Console 1、取消置顶或忽略该 App 会释放
位置，其余顺序随后会连续化。

因崩溃而被隔离的插件不会实例化，也不占位。请先解决插件问题，再删除
并重新加入它；这样可以避免反复的启动崩溃。

## 多声道信号路径

部分 USB 音频接口会提供超过两个声道的 stream-specific tap。FineTune 会
分别解析 tap 源设备与输出目标设备：先从源设备的首选 L/R 声道对提取信号，
以立体声顺序执行一次 App EQ 和 Audio Unit 效果链，再把结果写入目标设备的
首选 L/R 声道对。其余原生声道会使用相同的音量渐变与 limiter 保护并原样透传。

看到 Console 1 窗口或进程中已经加载其组件，只能证明实例创建成功，不能单独
证明音频已进入 render 回调。如果插件显示已加载但听感完全不变，请用效果非常
明显的插件或 preset 对比效果链旁路前后，并确认音频接口的首选输出声道对确实
连接到监听路径。更多步骤见[故障排查文档](troubleshooting.md#audio-unit-loads-but-sound-does-not-change)。

## 内置 EQ 相互独立

FineTune 的 10 段 EQ 与 Audio Unit 效果链相互独立。没有已保存 EQ 选择
的 App 默认使用平直曲线，并且 EQ 为关闭状态。FineTune 会保留已有的
显式开关选择。加入 Console 1 不会打开内置 EQ。

## 备份与恢复

FineTune 会把 App 置顶、效果链、Console 启动顺序、插件状态和 EQ 选择保存在：

```text
~/Library/Application Support/FineTune/settings.json
```

复制或恢复该文件前应先退出 FineTune；正在运行的实例可能覆盖手工修改。
序列化的 Audio Unit preset 数据是不透明的，也可能依赖已安装的插件版本，因此
应将整个文件与对应的 FineTune 和 Console 1 版本一起保留。

如果实际轨道不符合预期：

1. 确认每个目标 App 均已置顶，并且只包含一枚 Console 1。
2. 检查每个 App 行上的 **Next launch #N** 顺序。
3. 退出 FineTune 和其他所有 Console 1 宿主。
4. 先重新打开 FineTune，再打开其他宿主。
5. 如果插件行显示加载警告，请先解决该失败；被隔离的实例会被有意排除在
   启动顺序之外。
