import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dianbo/main.dart';
import 'package:dianbo/time_signal.dart';

void main() {
  testWidgets('主页核心入口和二级设置', (WidgetTester tester) async {
    await tester.pumpWidget(const TimeWaveApp(autoSync: false));
    await tester.pump();
    expect(find.text('电波表授时'), findsOneWidget);
    expect(find.text('中国 BPC'), findsOneWidget);
    expect(find.text('开始发波'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('授时设置'), findsOneWidget);
    expect(find.text('连续发波'), findsOneWidget);
    expect(find.text('低频试听'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
  });

  testWidgets('未联网时使用设备时间并允许发波', (WidgetTester tester) async {
    await tester.pumpWidget(const TimeWaveApp(autoSync: false));
    await tester.pump();
    expect(find.text('设备时钟'), findsOneWidget);
    final FilledButton action = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('broadcast-action')),
    );
    expect(action.onPressed, isNotNull);
  });

  for (final Size size in <Size>[
    const Size(320, 568),
    const Size(360, 640),
    const Size(387, 837),
    const Size(1000, 700),
  ]) {
    testWidgets('窗口 $size 发波按钮始终可见且布局无溢出', (WidgetTester tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const TimeWaveApp(autoSync: false));
      await tester.pump();
      final TimeWaveHomePage home = tester.widget<TimeWaveHomePage>(
        find.byType(TimeWaveHomePage),
      );
      for (final SignalProtocol protocol in SignalProtocol.values) {
        home.preferences.update(protocol: protocol);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final Rect button = tester.getRect(
          find.byKey(const ValueKey<String>('broadcast-action')),
        );
        expect(button.top, greaterThanOrEqualTo(0));
        expect(button.bottom, lessThanOrEqualTo(size.height));
        if (size.height >= 640) {
          final ScrollableState scroll = tester.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          expect(
            scroll.position.maxScrollExtent,
            lessThanOrEqualTo(1),
            reason: '$size $protocol 主屏应一屏显示',
          );
        }
      }
    });
  }

  testWidgets('主页点按切换显示时区', (WidgetTester tester) async {
    await tester.pumpWidget(const TimeWaveApp(autoSync: false));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('display-zone')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('显示时区'), findsOneWidget);
    await tester.tap(find.text('UTC+00:00'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('UTC+00:00'), findsOneWidget);
    expect(
      tester
          .widget<TimeWaveHomePage>(find.byType(TimeWaveHomePage))
          .preferences
          .displayOffsetMinutes,
      0,
    );
  });

  test('全部网络校时失败时回退设备时间', () async {
    final NtpTimeService service = NtpTimeService(servers: const <String>[]);
    expect(await service.sync(), isNull);
    expect(service.offset, Duration.zero);
    expect(service.server, isNull);
    expect(
      service.nowUtc().difference(DateTime.now().toUtc()).inMilliseconds.abs(),
      lessThan(100),
    );
  });
}
