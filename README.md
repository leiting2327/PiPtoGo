# PiPtoGo · 苹果画中画（图片 / 视频）

一个把**图片**和**视频**变成苹果系统级**画中画（Picture-in-Picture）**的 iOS 应用。
工程完全可复现：macOS + Xcode + XcodeGen，并通过 **GitHub Actions 在云端自动编译出 IPA**。

## 功能

- **视频画中画**：从相册选一个视频，点「开始画中画」，视频立刻以系统级小窗悬浮播放，切后台也持续。
- **图片画中画**：选一张图片，App 自动把它编码成一段带静音音轨的循环视频，再进入画中画。静音音轨是为了让播放器在后台仍被视为「正在播放」，从而让画中画持续不中断。
- 支持 iPhone / iPad，最低 iOS 15。

## 工程结构

```
PiPtoGo/
├── project.yml                 # XcodeGen 工程定义（生成 .xcodeproj）
├── PiPtoGo/
│   ├── PiPtoGoApp.swift        # 入口
│   ├── ContentView.swift       # 界面 + 播放 + 画中画按钮
│   ├── PiPVideoView.swift      # AVPlayerLayer + AVPictureInPictureController 封装
│   ├── VideoEncoder.swift      # 图片 -> 带静音音轨的循环视频
│   ├── MediaPicker.swift       # 相册选择器（PHPicker）
│   ├── Info.plist
│   └── Resources/              # AppIcon 等资源
├── scripts/build_ipa.sh        # 构建脚本（签名/无签名两路）
└── .github/workflows/build-ipa.yml
```

## 在 GitHub Actions 上构建 IPA

每次推送到 `main`，或手动触发 `Actions → Build IPA → Run workflow`，云端 macOS 机器会自动编译并产出 IPA 产物（在 Actions 运行记录的 **Artifacts** 里下载）。

- **没有配签名密钥**：自动产出 `PiPtoGo-unsigned.ipa`（未签名，一般只能装到越狱机，用于验证工程）。
- **配了签名密钥**：自动产出签名后的 `PiPtoGo.ipa`，可直接安装到真机。

### 配置真机签名（关键步骤）

要装到自己的 iPhone 上，必须让 CI 用你的证书签名。在仓库 `Settings → Secrets and variables → Actions` 添加三个密钥：

| 密钥名 | 内容 |
| --- | --- |
| `CERTIFICATE_BASE64` | 你的 .p12 证书文件，`base64 -i cert.p12` 得到的字符串 |
| `P12_PASSWORD` | .p12 的导出密码 |
| `PROVISIONING_PROFILE_BASE64` | 描述文件 .mobileprovision，`base64 -i xxx.mobileprovision` 得到的字符串 |

> 描述文件必须**包含你 iPhone 的 UDID**（免费或付费开发者账号都可以生成，Xcode 里 `Register Device` 填入 UDID 即可）。否则签名成功也装不进你的设备。

生成密钥串命令（在你自己电脑上执行）：

```bash
base64 -i Certificates.p12          # 得到 CERTIFICATE_BASE64
base64 -i YourApp.mobileprovision   # 得到 PROVISIONING_PROFILE_BASE64
```

### 安装到 iPhone

1. 从 Actions 下载 `PiPtoGo.ipa`
2. 用 `Apple Configurator`、`爱思助手`、`Xcode` 或任意签名工具安装到设备
3. 首次打开需在「设置 → 通用 → VPN 与设备管理」信任开发者证书

## 本地构建（可选，需要 Mac）

```bash
brew install xcodegen
xcodegen generate
open PiPtoGo.xcodeproj   # Xcode 里选真机运行，或直接 Archive 导出
# 或命令行：
./scripts/build_ipa.sh
```

## 原理备注

苹果的画中画 API `AVPictureInPictureController` 只接受**视频**内容。图片并不是直接进画中画，而是先被 `AVAssetWriter` 实时编码成 H.264 循环视频，再交给 `AVPlayer` + `AVPlayerLooper` 无限循环，最后启动画中画。这也是市面上「照片变动态壁纸/画中画」类应用的通用做法。
