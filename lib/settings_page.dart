import 'package:flutter/material.dart';

import 'app_preferences.dart';
import 'time_signal.dart';

/// 把不常用选项集中到二级页，主屏保留时间、帧进度和发波入口。
class SignalSettingsPage extends StatelessWidget {
  const SignalSettingsPage({
    super.key,
    required this.preferences,
    required this.busy,
    required this.timeSource,
    required this.offsetText,
  });

  final AppPreferences preferences;
  final bool busy;
  final String timeSource;
  final String offsetText;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: preferences,
    builder: (BuildContext context, Widget? child) => Scaffold(
      appBar: AppBar(
        title: const Text('授时设置'),
        backgroundColor: const Color(0xFF0B1A2D),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: <Widget>[
              const _SectionTitle('发波方式'),
              SwitchListTile.adaptive(
                title: const Text('连续发波'),
                subtitle: const Text('默认开启；关闭后接收当前片段，再发完一整帧'),
                value: preferences.continuous,
                onChanged: busy
                    ? null
                    : (bool value) => preferences.update(continuous: value),
              ),
              const SizedBox(height: 14),
              const _SectionTitle('声音模式'),
              for (final CarrierMode mode in CarrierMode.values)
                ListTile(
                  leading: Icon(
                    preferences.carrier == mode
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: preferences.carrier == mode
                        ? const Color(0xFF65E4D2)
                        : Colors.white38,
                  ),
                  title: Text(mode.title),
                  subtitle: Text(mode.subtitle),
                  enabled: !busy,
                  onTap: busy ? null : () => preferences.update(carrier: mode),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '应用输出音量固定为最大，使用设备的系统音量键调节。低频模式只用于试听。',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 24),
              const _SectionTitle('字体大小'),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SegmentedButton<double>(
                  segments: const <ButtonSegment<double>>[
                    ButtonSegment<double>(value: .85, label: Text('小')),
                    ButtonSegment<double>(value: 1, label: Text('标准')),
                    ButtonSegment<double>(value: 1.15, label: Text('大')),
                  ],
                  selected: <double>{preferences.textScale},
                  onSelectionChanged: (Set<double> values) =>
                      preferences.update(textScale: values.first),
                ),
              ),
              const SizedBox(height: 14),
              const _SectionTitle('校时详情'),
              ListTile(
                title: const Text('时间来源'),
                trailing: Text(
                  timeSource,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              ListTile(
                title: const Text('网络与设备时间偏移'),
                trailing: Text(
                  offsetText,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 14),
              const _SectionTitle('使用帮助'),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '1. 将手表切换到手动收波模式。\n\n2. 选择手表支持的电台，把天线一侧贴近扬声器，沿用已成功的摆放方式。\n\n3. 点击开始后立即发波，保持前台静置数分钟，让接收器找到完整帧。\n\n4. 主页时区只调整显示；BPC 固定编码北京时间，JJY 固定编码日本标准时间。\n\n5. 启动时自动网络校时，失败则使用设备时间；此时设备时钟误差会传递给手表。',
                  style: TextStyle(color: Colors.white70, height: 1.6),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Text(
    title,
    style: const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: Color(0xFF65E4D2),
    ),
  );
}
