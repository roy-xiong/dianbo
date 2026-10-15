import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'time_signal.dart';

/// 轻量配置；通过系统偏好存储持久化，不引入额外平台插件或 NDK 依赖。
class AppPreferences extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel(
    'com.xiongjian.dianbo/preferences',
  );
  SignalProtocol protocol = SignalProtocol.bpc;
  CarrierMode carrier = CarrierMode.harmonic;
  bool continuous = true;
  int displayOffsetMinutes = 480;
  double textScale = 1;
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();

  Future<void> load() async {
    try {
      final String? raw = await _channel.invokeMethod<String>('read');
      if (raw == null || _disposed) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      protocol = decoded['protocol'] == 'jjy'
          ? SignalProtocol.jjy
          : SignalProtocol.bpc;
      carrier = decoded['carrier'] == 'classic'
          ? CarrierMode.classic
          : CarrierMode.harmonic;
      continuous = decoded['continuous'] != false;
      final Object? offset = decoded['displayOffsetMinutes'];
      if (offset is num && offset.isFinite && offset >= -720 && offset <= 840) {
        displayOffsetMinutes = offset.toInt();
      }
      final Object? scale = decoded['textScale'];
      if (scale is num && <double>[.85, 1, 1.15].contains(scale.toDouble())) {
        textScale = scale.toDouble();
      }
      notifyListeners();
    } on Object {
      // 缺少原生端的 widget 测试或损坏配置使用默认值，不阻塞授时页面。
    }
  }

  /// 每次更新保存完整快照，串行写入，避免快速切换设置时旧值覆盖新值。
  void update({
    SignalProtocol? protocol,
    CarrierMode? carrier,
    bool? continuous,
    int? offsetMinutes,
    double? textScale,
  }) {
    if (_disposed) return;
    this.protocol = protocol ?? this.protocol;
    this.carrier = carrier ?? this.carrier;
    this.continuous = continuous ?? this.continuous;
    displayOffsetMinutes = offsetMinutes ?? displayOffsetMinutes;
    this.textScale = <double>[.85, 1, 1.15].contains(textScale)
        ? textScale!
        : this.textScale;
    notifyListeners();
    final String raw = jsonEncode(<String, Object>{
      'protocol': this.protocol.name,
      'carrier': this.carrier.name,
      'continuous': this.continuous,
      'displayOffsetMinutes': displayOffsetMinutes,
      'textScale': this.textScale,
    });
    _writes = _writes.then((_) async {
      try {
        await _channel.invokeMethod<void>('write', raw);
      } on Object {
        // 写入失败时本次会话的设置仍然有效。
      }
    });
    unawaited(_writes);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 只格式化显示时区，绝不改动编码器的电台时区或 UTC 基准。
String displayZoneLabel(int minutes) {
  final String sign = minutes >= 0 ? '+' : '−';
  final int absolute = minutes.abs();
  return 'UTC$sign${(absolute ~/ 60).toString().padLeft(2, '0')}:${(absolute % 60).toString().padLeft(2, '0')}';
}
