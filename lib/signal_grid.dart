import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'time_signal.dart';

/// 显示当前实际发送帧。格子内容与音频编码共用数据，进度由原生播放时钟驱动。
///
/// BPC 一帧 20 格；JJY 一帧 60 格，分三行显示。空闲时只预览编码，
/// 不显示发送游标，避免把设备时钟的走动当作真实发波进度。
class SignalFrameProgress extends StatelessWidget {
  const SignalFrameProgress({
    super.key,
    required this.protocol,
    required this.previewUtc,
    required this.transmitting,
    this.playbackUtc,
    this.compact = false,
  });

  final SignalProtocol protocol;
  final DateTime previewUtc;
  final bool transmitting;
  final DateTime? playbackUtc;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final DateTime? playback = playbackUtc;
    final bool active = transmitting && playback != null;
    final DateTime utc = active ? playback : previewUtc;
    final int index = utc.second % protocol.frameSeconds;
    final List<int> symbols = protocol == SignalProtocol.bpc
        ? TimeCodeEncoder.bpcSymbols(utc)
        : TimeCodeEncoder.jjySymbols(utc);
    final double fraction =
        (utc.millisecond * 1000 + utc.microsecond) / 1000000;
    final int symbol = symbols[index];
    final bool morse =
        protocol == SignalProtocol.jjy &&
        (utc.minute == 15 || utc.minute == 45) &&
        index >= 40 &&
        index < 49;
    final String code = morse ? '呼号' : (symbol == -1 ? '标记' : '$symbol');
    final String progress = active
        ? '${index + 1}/${protocol.frameSeconds} 秒 · $code'
        : (transmitting ? '载波校准中' : '待发波');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('时间码进度', style: Theme.of(context).textTheme.labelLarge),
            const Spacer(),
            Text(
              progress,
              style: const TextStyle(color: Color(0xFF8CEDE2), fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Semantics(
          label: '${protocol.title}时间码进度',
          value: progress,
          child: RepaintBoundary(
            child: SizedBox(
              width: double.infinity,
              height:
                  (protocol == SignalProtocol.bpc ? 1 : 3) *
                  (compact ? 56.0 : 82.0),
              child: CustomPaint(
                painter: _FrameGridPainter(
                  rowHeight: compact ? 56 : 82,
                  symbols: symbols,
                  activeIndex: active ? index : -1,
                  fraction: active ? fraction : 0,
                  morse:
                      protocol == SignalProtocol.jjy &&
                      (utc.minute == 15 || utc.minute == 45),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Wrap(
          spacing: 14,
          runSpacing: 4,
          children: <Widget>[
            _GridLegend(color: Color(0xFF32B84B), label: '数据'),
            _GridLegend(color: Color(0xFFFFC247), label: '标记'),
            _GridLegend(color: Color(0xFF59B4FF), label: '当前码元'),
          ],
        ),
      ],
    );
  }
}

/// 格子颜色用于区分数据、帧标记与游标，数字是编码值，格子下方是帧内秒位置。
class _FrameGridPainter extends CustomPainter {
  const _FrameGridPainter({
    required this.rowHeight,
    required this.symbols,
    required this.activeIndex,
    required this.fraction,
    required this.morse,
  });

  final List<int> symbols;
  final double rowHeight;
  final int activeIndex;
  final double fraction;
  final bool morse;

  @override
  void paint(Canvas canvas, Size size) {
    const int columns = 20;
    final double step = size.width / columns;
    final double gap = math.min(3, step * .18);
    final double fontSize = math.min(11, step * .72);
    final Paint paint = Paint();
    for (int i = 0; i < symbols.length; i++) {
      final double x = (i % columns) * step;
      final double y = (i ~/ columns) * rowHeight;
      final double barHeight = rowHeight - 27;
      final Rect bar = Rect.fromLTWH(x + gap / 2, y + 4, step - gap, barHeight);
      final RRect rounded = RRect.fromRectAndRadius(
        bar,
        const Radius.circular(2),
      );
      final bool callSign = morse && i >= 40 && i < 49;
      final Color color = symbols[i] == -1 || callSign
          ? const Color(0xFFFFC247)
          : const Color(0xFF32B84B);
      paint
        ..style = PaintingStyle.fill
        ..color = color.withValues(
          alpha: activeIndex < 0 ? .4 : (i < activeIndex ? .95 : .52),
        );
      canvas.drawRRect(rounded, paint);
      if (i == activeIndex) {
        // 蓝色覆盖宽度跟随当前秒的真实播放进度，不额外启动动画计时器。
        paint.color = const Color(0xFF59B4FF).withValues(alpha: .3);
        canvas.drawRect(
          Rect.fromLTRB(bar.left - 1, y, bar.right + 1, y + barHeight + 9),
          paint,
        );
        canvas.save();
        canvas.clipRRect(rounded);
        paint.color = const Color(0xFF59B4FF).withValues(alpha: .75);
        canvas.drawRect(
          Rect.fromLTWH(
            bar.left,
            bar.top,
            bar.width * fraction.clamp(0.0, 1.0),
            bar.height,
          ),
          paint,
        );
        canvas.restore();
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF9AD5FF);
        canvas.drawRRect(rounded, paint);
        paint.style = PaintingStyle.fill;
      }
      void label(String value, double centerY, Color color, double font) {
        final TextPainter text = TextPainter(
          text: TextSpan(
            text: value,
            style: TextStyle(
              color: color,
              fontSize: font,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(
          canvas,
          Offset(x + step / 2 - text.width / 2, centerY - text.height / 2),
        );
      }

      label(
        callSign ? 'J' : (symbols[i] == -1 ? 'M' : '${symbols[i]}'),
        y + 4 + barHeight / 2,
        Colors.white,
        fontSize,
      );
      label(
        '$i'.padLeft(2, '0'),
        y + rowHeight - 11,
        i == activeIndex ? const Color(0xFF9AD5FF) : Colors.white54,
        math.min(9, step * .53),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FrameGridPainter oldDelegate) =>
      !listEquals(oldDelegate.symbols, symbols) ||
      oldDelegate.activeIndex != activeIndex ||
      oldDelegate.fraction != fraction ||
      oldDelegate.morse != morse ||
      oldDelegate.rowHeight != rowHeight;
}

class _GridLegend extends StatelessWidget {
  const _GridLegend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
    ],
  );
}
