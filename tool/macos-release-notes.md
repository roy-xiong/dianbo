电波表授时 macOS 测试包，由 GitHub Actions 使用 Flutter 3.44.4 构建。

- 支持 BPC、JJY40 连续音频时间码和真实格子进度。
- 主屏提供表盘、数字时间、协议和显示时区选择，发波按钮固定在底部。
- 双击 DMG，将“电波表授时.app”拖入 Applications。
- 测试包未使用 Developer ID 签名或 Apple 公证；Gatekeeper 可能要求在系统设置中手动允许打开。
- 仅完成编译、测试和包体校验；实体电波表接收效果仍需使用对应硬件验证。

DMG 的架构和 SHA-256 见 build-info.json 与 SHA256SUMS.txt。
