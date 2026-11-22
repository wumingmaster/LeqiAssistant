# 乐奇助手

乐奇助手包含 iPhone App 和 Rokid 眼镜配套。手机通过 Rokid SDK 发送拍照、相册同步和录音指令，眼镜配套负责读取眼镜相册并在本地网络上传输原片。

- `LeqiAssistant/` 是 iPhone App 源码，要求 iOS 17 或更高版本。
- `GlassesCompanion/app/` 是眼镜配套源码，`GlassesCompanion/tools/` 包含 APK 构建脚本。

## 使用

- 首次点「连接 / 授权眼镜」，在 Hi Rokid 中确认授权。之后打开乐奇助手，会等待 SDK 恢复蓝牙连接，并在连接后打开眼镜端应用。
- 「原生拍照」只触发眼镜快门，由眼镜和 Hi Rokid 管理照片。
- 「拍照并传到相册」触发一次原生快门，再把眼镜原片通过本地 Wi-Fi 加密传到 iPhone。首次使用时需要允许添加照片和本地网络访问。
- 「同步眼镜相册」需安装眼镜配套 0.53 或更新版本。它读取眼镜 `DCIM/Camera`，首次处理最近 24 小时的照片，每次最多检查 10 张，保存成功后再推进同步位置。使用本 App 已保存的原片指纹避免重复导入。通过 Hi Rokid 或其他应用导入的照片无法使用本 App 的指纹判断。
- 「开始录音」请求眼镜麦克风传送 PCM，录音最多 5 分钟。停止、离开 App 或蓝牙断开时保存已收到的音频，可分享最近的 WAV 文件。
- 当前 SDK 的公开拍照接口只能返回静态图片，实况照片暂未实现。iPhone 相册的实况照片需要配对的静态照片和短视频，现有拍照通道没有这些资源。

## 快捷指令

在「快捷指令 → App」中选择「乐奇助手」。包含「眼镜原声拍照」和「眼镜原声拍照传回手机」。之前使用「眼镜家居」动作的自建快捷指令可选择新版对应动作。URL 入口是 `leqiassistant://capture`（原生拍照）和 `leqiassistant://photo`（拍照并传输）。

## 构建 iPhone App

安装 Xcode 和 CocoaPods。在仓库根目录执行以下命令，恢复锁定的 RGCxrClient 1.0.1、RGCoreKit 0.0.2 及其依赖。

```sh
pod install
xcodebuild -workspace LeqiAssistant.xcworkspace -scheme LeqiAssistant -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

要在真机运行，打开 `LeqiAssistant.xcworkspace`，选择 `LeqiAssistant` 和目标 iPhone，并在 Xcode 的 Signing & Capabilities 中使用你的开发团队和可用的 Bundle ID。

- [Rokid CXR-L SDK](https://developerdoc.rokid.com/sdk?lang=en)
- [Apple Photos Live Photo 配对资源](https://developer.apple.com/documentation/photos/phassetresourcetype/pairedvideo)

## 构建眼镜配套

准备 Python 3、JDK、Android SDK Platform 35 和 Build Tools 35.0.0。把从 Rokid 获取的 CXR 眼镜端 AAR 解压到 `GlassesCompanion/sdk/`，其中应包含 `classes.jar` 和 `jni/arm64-v8a/`。在仓库之外准备 APK 签名目录，包含 `key.p12` 和 `password` 文件。覆盖升级需使用与已安装版本一致的签名。

```sh
python3 GlassesCompanion/tools/build_dev_apk.py \
  --code 53 --version 0.53 \
  --sdk "$ANDROID_SDK_ROOT" \
  --signer-dir "$LEQI_APK_SIGNER_DIR" \
  --output /tmp/leqi-companion-0.53.apk
```

连接支持调试的 Rokid 眼镜后，可用 `adb install -r /tmp/leqi-companion-0.53.apk` 安装。仓库只保存源码和构建配置，SDK 文件、签名材料和生成的安装包在本地管理。

### 可选的家居和局域网更新

拍照、相册同步和录音可直接使用。启用家居直连、喂食器或开发用局域网更新时，在本地创建 `GlassesCompanion/local-config.json`，按需填写对应地址。文件已加入 Git 忽略列表。也可以用 `--config` 指向仓库之外的 JSON 文件。

```json
{
  "home_url": "https://home.example.org",
  "feeder_url": "https://feeder.example.org/api/status",
  "updater_url": "http://updates.example.org:18764"
}
```

家居和喂食器使用 HTTPS。开发用更新地址支持 HTTP 或 HTTPS，HTTP 仅对配置中的更新主机放行。地址中请勿包含凭据。
