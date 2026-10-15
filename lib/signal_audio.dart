import 'dart:async';

import 'package:flutter/services.dart';

import 'time_signal.dart';

/// Flutter 只提交控制命令与包络计划；PCM 始终由 Android 音频线程连续输出。
class SignalAudio {
  SignalAudio({required this.utcNow}) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'status' && !_events.isClosed) {
        final Object? arguments = call.arguments;
        if (arguments is Map) {
          if (arguments['state'] == 'stopped' ||
              arguments['state'] == 'error') {
            _running = false;
            _renewal?.cancel();
          }
          _events.add(Map<String, Object?>.from(arguments));
        }
      }
    });
  }

  static const MethodChannel _channel = MethodChannel(
    'com.xiongjian.dianbo/signal',
  );
  final DateTime Function() utcNow;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  Stream<Map<String, Object?>> get events => _events.stream;
  Timer? _renewal;
  bool _disposed = false;
  bool _running = false;
  bool _starting = false;
  SignalProtocol? _protocol;
  int _planEnds = 0;

  /// 用一次本地往返估算 UTC 与 Android 单调时钟的映射，避免设备时钟调整干扰发波。
  Future<void> start(
    SignalProtocol protocol,
    CarrierMode mode,
    bool continuous,
    double volume,
  ) async {
    _starting = true;
    try {
      final SignalPlan plan = TimeCodeEncoder.plan(utcNow(), protocol);
      final int before = utcNow().microsecondsSinceEpoch;
      final int? monoNanos = await _channel
          .invokeMethod<int>('clock')
          .timeout(const Duration(seconds: 5));
      final int after = utcNow().microsecondsSinceEpoch;
      if (_disposed || monoNanos == null) {
        throw StateError('音频时钟不可用');
      }
      try {
        await _channel
            .invokeMethod<void>('start', <String, Object>{
              'protocol': protocol.name,
              'frequency': mode == CarrierMode.classic
                  ? 1000.0
                  : protocol.audioHz,
              'continuous': continuous,
              'volume': volume,
              'clockUtcMicros': before + (after - before) ~/ 2,
              'clockMonoNanos': monoNanos,
              'planBaseUtcMicros': plan.baseUtcMicros,
              'levels': plan.levels,
            })
            .timeout(const Duration(seconds: 5));
      } on Object {
        await stop();
        rethrow;
      }
      if (_disposed) {
        await stop();
        return;
      }
      _running = true;
      _protocol = protocol;
      _planEnds = plan.endUtcMicros;
      _renewal?.cancel();
      _renewal = Timer.periodic(
        const Duration(minutes: 1),
        (_) => unawaited(_renew()),
      );
    } finally {
      _starting = false;
    }
  }

  /// 在当前计划耗尽之前续订；更新数据不关闭 AudioTrack。
  Future<void> _renew() async {
    final SignalProtocol? protocol = _protocol;
    if (_disposed ||
        !_running ||
        protocol == null ||
        _planEnds - utcNow().microsecondsSinceEpoch >
            const Duration(minutes: 3).inMicroseconds) {
      return;
    }
    try {
      final SignalPlan plan = TimeCodeEncoder.plan(utcNow(), protocol);
      await _channel.invokeMethod<void>('updatePlan', <String, Object>{
        'planBaseUtcMicros': plan.baseUtcMicros,
        'levels': plan.levels,
      });
      _planEnds = plan.endUtcMicros;
    } on Object {
      await stop();
      if (!_events.isClosed) {
        _events.add(<String, Object?>{
          'state': 'error',
          'message': '时间码续订失败，请重新开始',
        });
      }
    }
  }

  Future<void> setVolume(double value) =>
      _channel.invokeMethod<void>('volume', value);

  Future<void> stop() async {
    final bool needsNativeStop = _running || _starting;
    _running = false;
    _renewal?.cancel();
    if (!needsNativeStop) return;
    try {
      await _channel
          .invokeMethod<void>('stop')
          .timeout(const Duration(seconds: 3));
    } on MissingPluginException {
      // Widget 测试没有原生音频端；不遗留未处理异步异常。
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    try {
      await stop();
    } on Object {
      // 原生 Activity 已销毁时仍要清理 Dart 订阅。
    } finally {
      await _events.close();
    }
  }
}
