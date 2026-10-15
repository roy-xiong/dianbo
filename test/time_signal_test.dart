import 'package:dianbo/time_signal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BPC 三帧字段与固定接收码一致', () {
    final DateTime utc = DateTime.utc(2026, 10, 14, 12, 38);
    final List<int> expected = <int>[
      -1,
      0,
      0,
      2,
      0,
      2,
      1,
      2,
      0,
      3,
      2,
      0,
      3,
      2,
      2,
      2,
      1,
      2,
      2,
      0,
    ];
    for (int frame = 0; frame < 3; frame++) {
      final List<int> actual = TimeCodeEncoder.bpcSymbols(
        utc.add(Duration(seconds: frame * 20)),
      );
      final List<int> reference = List<int>.of(expected);
      reference[1] = frame;
      reference[10] = frame == 0 ? 2 : 3;
      expect(actual, reference, reason: 'frame=$frame');
    }
  });

  test('BPC 每帧都能独立恢复日期时间及通过校验', () {
    for (final DateTime utc in <DateTime>[
      DateTime.utc(2026, 10, 14, 12, 38),
      DateTime.utc(2026, 10, 31, 15, 59),
      DateTime.utc(2099, 12, 31, 15, 59),
      DateTime.utc(2100, 1, 1, 0, 0),
    ]) {
      for (int frame = 0; frame < 3; frame++) {
        final List<int> s = TimeCodeEncoder.bpcSymbols(
          utc.add(Duration(seconds: frame * 20)),
        );
        final DateTime civil = utc.add(const Duration(hours: 8));
        expect((s[3] << 2 | s[4]) + 12 * (s[10] >> 1), civil.hour);
        expect(s[5] << 4 | s[6] << 2 | s[7], civil.minute);
        expect(s[8] << 2 | s[9], civil.weekday);
        expect(s[11] << 4 | s[12] << 2 | s[13], civil.day);
        expect(s[14] << 2 | s[15], civil.month);
        expect(
          (s[19] >> 1) << 6 | s[16] << 4 | s[17] << 2 | s[18],
          civil.year % 100,
        );
        expect(_parity(s.sublist(1, 10)), s[10] & 1);
        expect(_parity(s.sublist(11, 19)), s[19] & 1);
      }
    }
  });

  test('JJY 按日本时区及标准 BCD 位置恢复分钟小时年积日', () {
    final List<int> s = TimeCodeEncoder.jjySymbols(
      DateTime.utc(2004, 4, 1, 8, 25),
    );
    int decode(List<int> indices, List<int> weights) {
      int value = 0;
      for (int i = 0; i < indices.length; i++) {
        value += s[indices[i]] * weights[i];
      }
      return value;
    }

    expect(
      decode(<int>[1, 2, 3, 5, 6, 7, 8], <int>[40, 20, 10, 8, 4, 2, 1]),
      25,
    );
    expect(
      decode(<int>[12, 13, 15, 16, 17, 18], <int>[20, 10, 8, 4, 2, 1]),
      17,
    );
    expect(
      decode(
        <int>[22, 23, 25, 26, 27, 28, 30, 31, 32, 33],
        <int>[200, 100, 80, 40, 20, 10, 8, 4, 2, 1],
      ),
      92,
    );
    expect(s[36], 0);
    expect(s[37], 1);
    expect(decode(<int>[50, 51, 52], <int>[4, 2, 1]), 4);
    expect(s[0], -1);
    expect(s[59], -1);
  });

  test('BPC 与 JJY 的包络方向正确，帧边界没有附加静音', () {
    final DateTime utc = DateTime.utc(2026, 10, 14, 12, 38);
    final SignalPlan bpc = TimeCodeEncoder.plan(
      utc,
      SignalProtocol.bpc,
      minutes: 2,
    );
    final SignalPlan jjy = TimeCodeEncoder.plan(
      utc,
      SignalProtocol.jjy,
      minutes: 2,
    );
    expect(bpc.levels.length, 12000);
    for (final int frame in <int>[0, 20, 40, 60, 80, 100]) {
      expect(
        bpc.levels.sublist(frame * 100, (frame + 1) * 100),
        everyElement(1),
      );
    }
    expect(bpc.levels.sublist(100, 110), everyElement(0));
    expect(bpc.levels.sublist(110, 200), everyElement(1));
    expect(jjy.levels.sublist(0, 20), everyElement(1));
    expect(jjy.levels.sublist(20, 100), everyElement(0));
  });

  test('时间计划跨 UTC 日期和电台本地日期仍逐分钟编码', () {
    final DateTime utc = DateTime.utc(2026, 12, 31, 15, 59, 45);
    final SignalPlan plan = TimeCodeEncoder.plan(
      utc,
      SignalProtocol.bpc,
      minutes: 2,
    );
    expect(
      plan.baseUtcMicros,
      DateTime.utc(2026, 12, 31, 15, 59).microsecondsSinceEpoch,
    );
    final List<int> next = TimeCodeEncoder.bpcSymbols(
      utc.add(const Duration(minutes: 1)),
    );
    expect(next[14] << 2 | next[15], 1);
    expect(next[11] << 4 | next[12] << 2 | next[13], 1);
    expect(plan.levels.sublist(6000, 6100), everyElement(1));
  });

  test('JJY 报呼号分钟包含 Morse 包络，正常分钟保留年月日字段', () {
    final SignalPlan plan = TimeCodeEncoder.plan(
      DateTime.utc(2026, 10, 14, 12, 15),
      SignalProtocol.jjy,
      minutes: 1,
    );
    expect(plan.levels.sublist(4000, 4055), everyElement(2));
    expect(plan.levels.sublist(4055, 4065), everyElement(1));
    expect(plan.levels[4900], 1);
    expect(plan.levels.any((int level) => level == 2), isTrue);
  });
}

int _parity(List<int> values) =>
    values.fold<int>(
      0,
      (int n, int v) => n + v.toRadixString(2).split('1').length - 1,
    ) &
    1;
