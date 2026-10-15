import 'dart:typed_data';

/// 授时电台。JJY 目前输出 40 kHz 对应的三次子谐波。
enum SignalProtocol { bpc, jjy }

extension SignalProtocolText on SignalProtocol {
  String get title => this == SignalProtocol.bpc ? '中国 BPC' : '日本 JJY40';
  String get subtitle =>
      this == SignalProtocol.bpc ? '68.5 kHz · 20 秒一帧' : '40 kHz · 60 秒一帧';
  int get frameSeconds => this == SignalProtocol.bpc ? 20 : 60;
  double get audioHz => this == SignalProtocol.bpc ? 13700 : 40000 / 3;
}

/// 保留试听选择；低频声仅用于检查扬声器，不能作为有效授时载波。
enum CarrierMode { classic, harmonic }

extension CarrierModeText on CarrierMode {
  String get title => this == CarrierMode.classic ? '低频试听' : '高频授时';
  String get subtitle => this == CarrierMode.classic ? '1 kHz · 测试声音' : '正弦子谐波';
}

/// 从 UTC 整分钟开始的连续包络。每个字节对应 10 ms。
///
/// 0 表示低幅、1 表示高幅、2 表示关闭载波（仅用于 JJY 呼号空隙）。
/// 电台码元跨帧直接连接，计划内没有播放器重启或文件切换。
class SignalPlan {
  const SignalPlan({required this.baseUtcMicros, required this.levels});

  static const int tickMicros = 10000;
  final int baseUtcMicros;
  final Uint8List levels;
  int get endUtcMicros => baseUtcMicros + levels.length * tickMicros;
}

/// 纯 Dart 时间码编码器。编码全部从 UTC 显式转换到电台民用时区，
/// 与手机当前时区无关；BPC 采用二进制四进制码，JJY 使用逐十进制位 BCD。
class TimeCodeEncoder {
  static int _parity(Iterable<int> values) {
    int parity = 0;
    for (int value in values) {
      while (value != 0) {
        parity ^= value & 1;
        value >>= 1;
      }
    }
    return parity;
  }

  /// 返回包含当前秒的 BPC 帧，-1 表示无降幅的帧起始标记。
  static List<int> bpcSymbols(DateTime utc) {
    final DateTime civil = utc.toUtc().add(const Duration(hours: 8));
    final int hour = civil.hour % 12;
    final int year = civil.year % 100;
    final List<int> s = List<int>.filled(20, 0);
    s[0] = -1;
    s[1] = civil.second ~/ 20;
    s[3] = hour >> 2;
    s[4] = hour & 3;
    s[5] = civil.minute >> 4;
    s[6] = (civil.minute >> 2) & 3;
    s[7] = civil.minute & 3;
    s[8] = civil.weekday >> 2;
    s[9] = civil.weekday & 3;
    s[10] = (civil.hour >= 12 ? 2 : 0) | _parity(s.sublist(1, 10));
    s[11] = civil.day >> 4;
    s[12] = (civil.day >> 2) & 3;
    s[13] = civil.day & 3;
    s[14] = civil.month >> 2;
    s[15] = civil.month & 3;
    s[16] = (year >> 4) & 3;
    s[17] = (year >> 2) & 3;
    s[18] = year & 3;
    s[19] = ((year >> 6) << 1) | _parity(s.sublist(11, 19));
    return s;
  }

  /// 返回 JJY 普通分钟的字段，-1 表示标记。
  ///
  /// 每小时 15/45 分钟的呼号区由 plan() 替换为 Morse 包络。
  /// 无夏令时与闰秒公告；默认不虚构任何未来闰秒。
  static List<int> jjySymbols(DateTime utc) {
    final DateTime civil = utc.toUtc().add(const Duration(hours: 9));
    final int day = civil.difference(DateTime.utc(civil.year)).inDays + 1;
    final List<int> s = List<int>.filled(60, 0);
    for (final int marker in <int>[0, 9, 19, 29, 39, 49, 59]) {
      s[marker] = -1;
    }
    void digit(int value, List<int> positions, List<int> weights) {
      for (int i = 0; i < positions.length; i++) {
        s[positions[i]] = value & weights[i] == 0 ? 0 : 1;
      }
    }

    digit(civil.minute ~/ 10, <int>[1, 2, 3], <int>[4, 2, 1]);
    digit(civil.minute % 10, <int>[5, 6, 7, 8], <int>[8, 4, 2, 1]);
    digit(civil.hour ~/ 10, <int>[12, 13], <int>[2, 1]);
    digit(civil.hour % 10, <int>[15, 16, 17, 18], <int>[8, 4, 2, 1]);
    digit(day ~/ 100, <int>[22, 23], <int>[2, 1]);
    digit((day ~/ 10) % 10, <int>[25, 26, 27, 28], <int>[8, 4, 2, 1]);
    digit(day % 10, <int>[30, 31, 32, 33], <int>[8, 4, 2, 1]);
    s[36] = _parity(s.sublist(12, 19).where((int b) => b >= 0));
    s[37] = _parity(s.sublist(1, 9));
    digit((civil.year % 100) ~/ 10, <int>[41, 42, 43, 44], <int>[8, 4, 2, 1]);
    digit(civil.year % 10, <int>[45, 46, 47, 48], <int>[8, 4, 2, 1]);
    digit(civil.weekday % 7, <int>[50, 51, 52], <int>[4, 2, 1]);
    return s;
  }

  /// 预编码连续多分钟数据，后续续订时可重叠覆盖，音频线程无需停播。
  static SignalPlan plan(
    DateTime instant,
    SignalProtocol protocol, {
    int minutes = 30,
  }) {
    if (minutes < 1 || minutes > 60) {
      throw ArgumentError.value(minutes, 'minutes', '必须在 1 到 60 之间');
    }
    final int minuteMicros = Duration.microsecondsPerMinute;
    final int base =
        instant.toUtc().microsecondsSinceEpoch ~/ minuteMicros * minuteMicros;
    final Uint8List levels = Uint8List(minutes * 6000);
    for (int m = 0; m < minutes; m++) {
      final DateTime minute = DateTime.fromMicrosecondsSinceEpoch(
        base + m * minuteMicros,
        isUtc: true,
      );
      final List<int>? jjy = protocol == SignalProtocol.jjy
          ? jjySymbols(minute)
          : null;
      for (int sec = 0; sec < 60; sec++) {
        final int begin = m * 6000 + sec * 100;
        if (protocol == SignalProtocol.bpc) {
          final int symbol = bpcSymbols(
            minute.add(Duration(seconds: sec)),
          )[sec % 20];
          final int lowTicks = symbol == -1 ? 0 : (symbol + 1) * 10;
          levels.fillRange(begin + lowTicks, begin + 100, 1);
        } else {
          final int symbol = jjy?[sec] ?? 0;
          final int highTicks = symbol == -1 ? 20 : (symbol == 1 ? 50 : 80);
          levels.fillRange(begin, begin + highTicks, 1);
        }
      }
      if (protocol == SignalProtocol.jjy &&
          (minute.minute == 15 || minute.minute == 45)) {
        _morse(levels, m * 6000);
      }
    }
    return SignalPlan(baseUtcMicros: base, levels: levels);
  }

  /// JJY 呼号 JJY JJY；保持 40.55 秒起始及 49 秒位置标记。
  static void _morse(Uint8List levels, int minuteBase) {
    levels.fillRange(minuteBase + 4000, minuteBase + 4900, 2);
    int tick = minuteBase + 4055;
    for (int repetition = 0; repetition < 2; repetition++) {
      for (final String letter in <String>['.---', '.---', '-.--']) {
        for (int i = 0; i < letter.length; i++) {
          final int duration = letter[i] == '.' ? 10 : 25;
          levels.fillRange(tick, tick + duration, 1);
          tick += duration + (i + 1 < letter.length ? 5 : 0);
        }
        tick += letter == '-.--' ? 50 : 30;
      }
    }
  }
}
