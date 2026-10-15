# 电波表授时

Flutter Android / macOS 应用，支持 BPC、JJY40 时间码、NTP 校时和连续音频输出。

- 紧凑主屏：数字时间、数字刻度指针表盘、协议、显示时区和真实码元进度。
- 发波按钮固定在底部；声音、连续模式、字号和帮助位于设置页。
- 启动自动网络校时，失败时使用设备时间；时区选择只改变显示，不改变电台时间码。
- 输出增益固定为最大，使用设备系统音量控制；默认连续发波。
- Android 使用 AudioTrack，macOS 使用 AVAudioEngine / AVAudioSourceNode，跨帧不重启播放器。

## 开发环境

Flutter **3.44.4**、Dart **3.12.2**。Android 复用 NDK **27.2.12479018**、Java 17、AGP 9.0.1。

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter run -d <设备编号>
```

macOS 本地开发需要完整 Xcode。仓库的 **macOS DMG** Actions 会在云端执行分析、测试、Release 构建和 DMG 包体校验，产物发布到 `macos-test` 测试版本。

## 授时说明

选择手表支持的电台，切换手表到手动收波模式，让天线靠近设备扬声器。BPC 音频使用 13.7 kHz 正弦子谐波，JJY40 使用约 13.333 kHz；低频模式仅供试听。实际近场接收效果取决于音频硬件和手表，不能用听感响度判断接收强度。

macOS 测试包未使用 Developer ID 签名或 Apple 公证。实体手表是否接收成功需要实测，不能以软件测试和打包成功替代。

## 代码

- `lib/time_signal.dart`：UTC、电台时区、BPC/JJY 编码和连续包络。
- `lib/signal_grid.dart`：由原生播放时间驱动的格子进度。
- `lib/app_preferences.dart`：显示时区、字号和模式偏好。
- `android/app/src/main/kotlin/com/xiongjian/dianbo/SignalAudioEngine.kt`：Android PCM 与音频时钟。
- `macos/Runner/MacSignalAudioEngine.swift`：macOS 实时渲染与生命周期。
- `.github/workflows/macos-dmg.yml`：云端构建、打包与测试版发布。
