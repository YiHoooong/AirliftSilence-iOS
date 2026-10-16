# AirliftSilence (iOS 版)

[English](README.md) | 中文

在手机上直接关掉 iPhone 通话录音提示音，不需要电脑。

一个极简 SwiftUI App，建立在与 [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) 相同的 AirTraffic 沙箱逃逸之上。它通过 `LocalDevVPN` 回环隧道与本机内部服务通信，替换 iOS 在录音开始/结束时播放的三个音频文件。

三个动作，界面上和快捷指令里都能用：

| 动作 | 作用 |
|---|---|
| **去除提示音** | 把内置的静音文件写进那三个提示音文件 |
| **检测** | 读回并报告 静音 / 原版 / 未知版本 |
| **恢复原版** | 把内置的原版写回去 |

界面默认英文，附带简体中文翻译 —— 见 [多语言](#多语言)。

## 为什么"检测"要改 Rust

AirCard-iOS 随附的 `AirliftFFI` 只会**写**。逃逸本身只能搬动对象，所以读一个文件意味着：

1. 把符号链接挪进 `Media`
2. 让 ATAirlock 把目标文件搬到一个 `Media` 路径（参考 PoC 用它验证 canary 的同一招）
3. 通过 AFC 读出来
4. 原样写回去

本仓库给 Rust core 加了 `al_exploit_read_file_hash()` 完成第 1–4 步，并返回**大小 + SHA-256** 而不是原始字节，这样 Swift 端不必在 C ABI 上处理二进制缓冲。写回复用已验证的写路径，所以一次读取绝不会让设备少一个文件。

原来的写路径刻意没有动。

## 前置条件

- iOS 18.0 – 27.2 beta 2。**Apple 在 iOS 27.2 beta 3 修掉了底层的 `airlift` 逃逸** —— 不要升过 beta 2，升了就失效。
- [LocalDevVPN](https://github.com/rooootdev/LocalDevVPN) 运行在回环模式（App 默认拨 `10.7.0.1`，连不上会依次试其他隧道网关）。**千万不要填 `127.0.0.1`** —— 在 iOS 上这会让 `remotepairingdeviced` 拒绝控制通道并进入丢弃状态，之后所有连接都会失败，只能靠关掉再打开开发者模式恢复。
- 一份配对记录。可以导入现成的（AirDrop / 文件 → 放进 App 的 Documents，命名 `airlift_pairing.plist`），也可以用内置的本机配对：**开始配对** → 记下 PIN → 设置 › 隐私与安全性 › 开发者模式 › **与 AirliftSilence 配对**。被问到时请允许通知：PIN 同时会以通知形式发出，因为 PIN 出现的那一刻你正在设置里输入，App 自己的界面看不到。如果设置里始终没有「与 App 配对」入口，说明广播没起来：检查 设置 › AirliftSilence › 本地网络。App 会如实报告，而不是假装在广播。
- 官方「图书」App 装过并至少打开一次 —— 否则 `com.apple.atc` 会拒绝同步，这是「ReadyForSync not observed」最常见的原因。

### 配对文件怎么搬

有了记录之后，**导出配对文件**会把它交给分享面板 —— AirDrop、存储到「文件」等等。值得做一次：重新签名的侧载版本会得到全新容器，记录不会在重装后留下来。

放回去有三条路，大致按可靠性排序：

1. **导入配对文件** —— App 内的文件选择器。`.plist`、`.mobiledevicepairing`、`.mobilepairing` 都认。
2. 把文件丢进 App 的 Documents 文件夹（文件共享是开着的），命名 `airlift_pairing.plist`。
3. 从分享面板用 *AirliftSilence* 打开 `.plist`（「在 AirliftSilence 中打开」）—— 这条走 app delegate，所以 App 没在运行时也能用。扩展名没有声明 UTI 的文件（`.mobiledevicepairing`、`.mobilepairing`）也会出现在分享面板里。

## 构建

Rust core 需要为 iOS 编译，所以构建需要 macOS。没有 Mac 的话，**让 GitHub 帮你构建** —— `.github/workflows/build-ios.yml` 跑在 macOS runner 上并上传未签名的 IPA（公开仓库的 macOS runner 免费）：

1. 把仓库推到 GitHub
2. Actions → *Build unsigned IPA* → Run workflow
3. 下载 `AirliftSilence-unsigned-ipa` 构件

在装了 Xcode 的 Mac 上：

```sh
brew install xcodegen
./build-ios.sh          # rust-core -> AirliftFFI.xcframework
./build-ipa.sh Release  # -> build/AirliftSilence.ipa（未签名）
```

IPA 是刻意**不签名**的 —— 用你平时用的工具签（AltStore、SideStore、Sideloadly、TrollStore……）。

> [!IMPORTANT]
> `SilenceApp.swift` 里有对 `ALGetGrappaToken` 的硬引用。Rust 那边是用 `dlsym` 找这个符号的，没有硬引用链接器可能把它丢掉，之后每次同步都会以 *"Grappa session could not be established"* 失败（iOS 27.0.1+）。这行别删。

## 它会动到什么

三个录音提示音都在同一个目录里，一次写入覆盖全部：

```
/var/mobile/Library/CallServices/Greetings/default/StartDisclosureWithTone.m4a
/var/mobile/Library/CallServices/Greetings/default/StopDisclosure.caf
/var/mobile/Library/CallServices/Greetings/default/StartDisclosure.caf
```

内置的 `silent-*` 是 `ffmpeg anullsrc` 生成的纯静音，时长和编码对齐当前版本（AAC 1.672 秒、Opus 1.940 秒、Opus 1.280 秒），所以播放时长不变。同目录里的 `Greeting.caf` 和 `GreetingWithTone.m4a` 刻意不碰 —— 那是语音信箱问候音，不是录音提示音。

`original-*` 是 Apple 当前的版本，供**恢复原版**写回去。这两个是 Apple 的音频，只为你自己这台设备打包 —— 在意的话别带着它们分发这个仓库。

两组文件放在同一个文件夹里、名字带 `silent-` / `original-` 前缀，是因为 XcodeGen 会把目录内容摊平到 bundle 根目录，而两边重名；写入设备前的暂存步骤会把每个文件改回真名。

## 快捷指令与 Siri

App 内置三个 `AppIntent`，所以在快捷指令里会作为它自己的动作出现：

| 快捷指令动作 | 说明 |
|---|---|
| *Call-recording announcement* | 一步，带 Action 菜单：Check / Silence / Restore |
| *Silence the call-recording announcements* | 无参数 —— 放桌面图标的那个 |
| *Restore the call-recording announcements* | 无参数 |

每个都会把结果作为文本返回（`Call-recording announcements: Silenced` 等），所以快捷指令可以据此分支或弹通知。运行在 App 内排队：屏幕上的检测还在跑时进来的运行会等它，因为设备一次只受得了一次会话。

这些 intent 运行时会把 App 切到前台。这是故意的 —— 一次运行是几十秒的设备端会话，后台 intent 几秒就被掐掉，会把隧道断在半路。Siri 短语中英都注册了，例如 *"AirliftSilence 去掉通话录音提示音"*。

App 还暴露了 URL 接口，给只能用「打开 URL」的场景（*Open URLs* 动作、启动器、书签）：

```
airliftsilence://check
airliftsilence://silence
airliftsilence://restore
```

### 让静音保持住，以及自动补回来

iOS 会在不通知你的情况下把它还原。这些提示音是**设备端用 Siri TTS 生成的**，只要它期望的配置变了，守护进程就会重新生成：Apple 推送了新的声音或音频版本（我们测试机上那次就是这样，机主什么都没动）、系统更新、或者你切换了系统语言。发生之后提示音就回来了，**检测**会显示*原版（会响）*。

想跟它对着干之前，有两件事值得知道：

- **没有任何办法阻止这次重写。** 所有显而易见的阻挡招数都在真机上试过，全部失败：文件位置上放空目录、文件设成只读、文件设成不可变、目录设成只读。文件 mode 能带到设备上，但目录 mode 和文件 flag 带不进去，所以守护进程总能把整个条目替换掉，而不是被逼着往里写。实测数据在 [`docs/static-analysis.md`](docs/static-analysis.md)（英文）。
- **挡住它会弄坏录音。** 生成不出披露音频时，守护进程会**拒绝录音** —— 哪怕路径上放着一份完全合法可播放的静音文件。挡住不等于赢，等于一台不能录音的手机。别试。

所以答案是"发现 + 重新套用"，要么点一下，要么完全不用管：

1. 快捷指令 → *自动化* → **+** → *充电器*（或*特定时间*，比如凌晨 4 点）→ *立即运行*，并把**运行前询问**关掉
2. 动作选 **AirliftSilence** › *Silence the call-recording announcements*
3. 完成 —— 之后被还原会在一两天内自动修好

一次运行要 30–60 秒并且会把 App 切到前台，所以"充电时"或凌晨触发是最舒服的选择。想自己掌控就不建自动化：**检测**每次启动都会跑，提示音回来了它会以红色显示*原版（会响）*。

## 多语言

英文是开发语言，简体中文以 `zh-Hans` 发布。字符串**不在** String Catalog 里 —— `.strings` 是手写的，键就是 Swift 源码里那些英文字符串本身：

```
ios-app/en.lproj/Localizable.strings        # 英文（开发语言）
ios-app/zh-Hans.lproj/Localizable.strings   # 简体中文
ios-app/{en,zh-Hans}.lproj/InfoPlist.strings # 局域网权限弹窗文案
```

要加一门语言：把 `en.lproj` 复制成 `<语言>.lproj`，翻译值（键和 `%@` 占位符顺序保持一致），在 `Info.plist` 的 `CFBundleLocalizations` 里加上这门语言，然后重跑 `xcodegen generate`。`en.lproj` 必须留着：只有找到开发语言目录，XcodeGen 才会生成本地化 variant group。

不允许悄悄跑偏：

```sh
python3 tools/check-strings.py   # CI 里也会跑
```

它检查每个键在源码里还存在（把 `\(..)` 归一化成 `%@` 之后）、中英两份键序一致且 `%@` 数量对得上、`InfoPlist.strings` 只覆盖 plist 里有的键，并列出看起来像界面文案但没有翻译的源码字符串。

## 已知限制

- **iOS 会把它还原，而且挡不住。** 提示音是设备端用 Siri TTS 生成的，守护进程在它期望的配置变化时会重新生成 —— Apple 的声音/音频更新（测试机上那次就是这样，机主没做任何操作）、iOS 更新、或切换语言。两次还原之间静音是稳的：十天、含通话和重启都正常，而且它不是开机检查，重启是安全的。修复办法见 [让静音保持住](#让静音保持住以及自动补回来)，实测证据见 [`docs/static-analysis.md`](docs/static-analysis.md) —— 包括四种在真机上试过并被否决的阻挡招数，以及为什么它们生效期间守护进程会拒绝录音。
- 长录音里那个周期性**「叮叮叮」**提醒，是密封系统卷上 `TelephonyUtilities.framework` 里的 `recurringDisclosureTwinkle.caf`。这个逃逸改不了密封卷上的文件，所以它留着。App 能静音的只有开始/结束提示音。
- 重启**不会**还原。重启前后逐字节比对验证过。
- 提示音会播给通话**双方**。在要求全体同意的地区（德国、美国若干州）去掉它可能违法。录任何人之前先取得同意 —— 无论你手机播不播提示音，法律都适用。

## 命名与图标

凡是可见的地方 App 都叫 **AirliftSilence**：主屏、导航标题、向设置广播的配对主机名、以及它留在 Documents 里的配对文件（`airlift_pairing.plist`）。没有任何面向用户的名称沿用上游 AirCard。

图标是 `tools/make-icon.py`（Pillow）画出来的，不是塞一个二进制素材进去，所以仓库里没有借来的美术资源，设计本身是可改的数字：

```sh
python3 tools/make-icon.py
```

它画一个被划掉的喇叭 —— 也就是"静音"符号，正是 App 做的事 —— 底色是海军蓝到蓝的渐变，并输出资源目录需要的五种尺寸。

## 致谢

- [airlift](https://github.com/0xjohnnydev/airlift) — Johnny Franks：原始 PoC 与 ATAirlock 分析
- [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) — Mak5er：回环隧道、Rust FFI core、配对主机，以及本项目建立其上的 Grappa token
- [idevice](https://github.com/jkcoxson/idevice) — RSD/AFC/streaming_zip_conduit 的管线

MIT，见 [LICENSE](LICENSE)。
