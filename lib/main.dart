import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_preferences.dart';
import 'settings_page.dart';
import 'signal_audio.dart';
import 'signal_grid.dart';
import 'time_signal.dart';

/// 电波表授时应用入口。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Color(0xFF07111F),
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const TimeWaveApp());
}

/// 一次 NTP 校时结果。
class TimeSyncResult {
  const TimeSyncResult({
    required this.offset,
    required this.server,
    required this.roundTrip,
  });
  final Duration offset;
  final String server;
  final Duration roundTrip;
}

/// 多源 UDP NTP 校时服务，失败时保留设备时间。
class NtpTimeService {
  NtpTimeService({
    this.servers = const <String>[
      'ntp.aliyun.com',
      'ntp.tencent.com',
      'time.cloudflare.com',
      'pool.ntp.org',
    ],
  });

  final List<String> servers;
  final Stopwatch _steady = Stopwatch()..start();
  DateTime _anchorUtc = DateTime.now().toUtc();
  Duration _offset = Duration.zero;
  String? _server;

  /// 校准后以单调时钟递增，避免手机系统时间变更造成发波中途跳秒。
  DateTime nowUtc() => _anchorUtc.add(_steady.elapsed);
  DateTime now() => nowUtc().toLocal();
  Duration get offset => _offset;
  String? get server => _server;

  /// 依次尝试备用服务，避免单个 DNS 或网络节点导致界面卡住。
  Future<TimeSyncResult?> sync() async {
    for (final String host in servers) {
      try {
        final TimeSyncResult? result = await _query(host);
        if (result != null) {
          _offset = result.offset;
          _anchorUtc = DateTime.now().toUtc().add(result.offset);
          _steady.reset();
          _server = result.server;
          return result;
        }
      } on Object {
        // 继续尝试下一台服务器。
      }
    }
    _offset = Duration.zero;
    _server = null;
    _anchorUtc = DateTime.now().toUtc();
    _steady.reset();
    return null;
  }

  Future<TimeSyncResult?> _query(String host) async {
    final List<InternetAddress> addresses = await InternetAddress.lookup(
      host,
    ).timeout(const Duration(seconds: 3));
    if (addresses.isEmpty) return null;
    final InternetAddress address = addresses.firstWhere(
      (InternetAddress value) => value.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );
    final RawDatagramSocket socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
    ).timeout(const Duration(seconds: 3));
    final Completer<Datagram?> result = Completer<Datagram?>();
    StreamSubscription<RawSocketEvent>? subscription;
    Timer? timeout;
    try {
      final Uint8List request = Uint8List(48)..[0] = 0x23;
      final DateTime sentAt = DateTime.now().toUtc();
      final int micros = sentAt.microsecondsSinceEpoch;
      final ByteData requestData = ByteData.sublistView(request);
      requestData.setUint32(40, micros ~/ 1000000 + 2208988800, Endian.big);
      requestData.setUint32(
        44,
        (micros % 1000000) * 0x100000000 ~/ 1000000,
        Endian.big,
      );
      socket.send(request, address, 123);
      subscription = socket.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read && !result.isCompleted) {
            final Datagram? packet = socket.receive();
            if (packet != null &&
                packet.address.address == address.address &&
                packet.port == 123) {
              result.complete(packet);
            }
          }
        },
        onError: (Object error) {
          if (!result.isCompleted) result.complete(null);
        },
      );
      timeout = Timer(const Duration(seconds: 3), () {
        if (!result.isCompleted) result.complete(null);
      });
      final Datagram? packet = await result.future;
      final DateTime receivedAt = DateTime.now().toUtc();
      if (packet == null || packet.data.length < 48) return null;
      final Uint8List response = packet.data;
      if ((response[0] & 7) != 4 ||
          response[0] >> 6 == 3 ||
          response[1] < 1 ||
          response[1] > 15) {
        return null;
      }
      for (int i = 0; i < 8; i++) {
        if (response[24 + i] != request[40 + i]) return null;
      }
      final DateTime? t2 = _readNtpDate(packet.data, 32);
      final DateTime? t3 = _readNtpDate(packet.data, 40);
      if (t2 == null || t3 == null) return null;
      final int offsetMicros =
          ((t2.difference(sentAt).inMicroseconds +
                      t3.difference(receivedAt).inMicroseconds) /
                  2)
              .round();
      return TimeSyncResult(
        offset: Duration(microseconds: offsetMicros),
        server: host,
        roundTrip: receivedAt.difference(sentAt),
      );
    } finally {
      timeout?.cancel();
      await subscription?.cancel();
      socket.close();
    }
  }

  DateTime? _readNtpDate(Uint8List bytes, int offset) {
    if (bytes.length < offset + 8) return null;
    final ByteData data = ByteData.sublistView(bytes, offset, offset + 8);
    final int seconds = data.getUint32(0, Endian.big);
    if (seconds == 0) return null;
    final int fraction = data.getUint32(4, Endian.big);
    const int epoch = 2208988800;
    final int micros = (fraction * 1000000 / 0x100000000).round();
    return DateTime.fromMicrosecondsSinceEpoch(
      (seconds - epoch) * Duration.microsecondsPerSecond + micros,
      isUtc: true,
    );
  }
}

/// 应用根组件；字体设置作用于主页和二级页，并使用系统偏好持久化。
class TimeWaveApp extends StatefulWidget {
  const TimeWaveApp({super.key, this.autoSync = true});
  final bool autoSync;
  @override
  State<TimeWaveApp> createState() => _TimeWaveAppState();
}

class _TimeWaveAppState extends State<TimeWaveApp> {
  final AppPreferences _preferences = AppPreferences();
  @override
  void initState() {
    super.initState();
    unawaited(_preferences.load());
  }

  @override
  void dispose() {
    _preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _preferences,
    builder: (BuildContext context, Widget? child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '电波表授时',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF35D5C8),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF07111F),
      ),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(
            MediaQuery.textScalerOf(context).scale(1) * _preferences.textScale,
          ),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
      home: TimeWaveHomePage(
        autoSync: widget.autoSync,
        preferences: _preferences,
      ),
    ),
  );
}

/// 紧凑授时主页。发波按钮位于可滚动内容之外，任何窗口高度下都保留入口。
class TimeWaveHomePage extends StatefulWidget {
  const TimeWaveHomePage({
    super.key,
    required this.preferences,
    this.autoSync = true,
  });
  final bool autoSync;
  final AppPreferences preferences;
  @override
  State<TimeWaveHomePage> createState() => _TimeWaveHomePageState();
}

class _TimeWaveHomePageState extends State<TimeWaveHomePage> {
  final NtpTimeService _time = NtpTimeService();
  late final SignalAudio _audio;
  Timer? _timer;
  StreamSubscription<Map<String, Object?>>? _events;
  DateTime _utcNow = DateTime.now().toUtc();
  DateTime? _playbackUtc;
  String _status = '正在读取设备时间';
  String? _server;
  Duration? _offset;
  bool _syncing = false;
  bool _broadcasting = false;
  bool _generating = false;
  int _frames = 0;
  int _token = 0;
  AppPreferences get _preferences => widget.preferences;
  bool get _busy => _broadcasting || _generating;
  DateTime get _displayTime =>
      _utcNow.add(Duration(minutes: _preferences.displayOffsetMinutes));

  @override
  void initState() {
    super.initState();
    _audio = SignalAudio(utcNow: _time.nowUtc);
    _events = _audio.events.listen(_onAudioStatus);
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() => _utcNow = _time.nowUtc());
    });
    if (widget.autoSync) unawaited(_syncTime());
  }

  @override
  void dispose() {
    ++_token;
    _timer?.cancel();
    unawaited(_events?.cancel());
    unawaited(_audio.dispose());
    super.dispose();
  }

  /// 只有音频端回传的播放位置才能推动发送游标。
  void _onAudioStatus(Map<String, Object?> event) {
    if (!mounted) return;
    final String? state = event['state'] as String?;
    setState(() {
      if (state == 'stopped' || state == 'error') {
        _playbackUtc = null;
        _broadcasting = false;
        _generating = false;
        _status = event['message'] as String? ?? '发波已结束';
      } else if (state == 'calibrating') {
        _playbackUtc = null;
        _broadcasting = true;
        _status = '已出声，正在校准音频时钟';
      } else if (state == 'running') {
        _broadcasting = true;
        final int? micros = (event['playUtcMicros'] as num?)?.toInt();
        _playbackUtc = micros == null
            ? null
            : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
        _frames = (event['frames'] as num?)?.toInt() ?? 0;
        _status = _preferences.carrier == CarrierMode.classic
            ? '低频试听中，此模式不用于手表授时'
            : '正在发波，请保持手表贴近扬声器';
      }
    });
  }

  Future<void> _syncTime() async {
    if (_syncing || _busy) return;
    setState(() {
      _syncing = true;
      _status = '正在自动网络校时';
    });
    final TimeSyncResult? result = await _time.sync();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _offset = result?.offset;
      _server = result?.server;
      _utcNow = _time.nowUtc();
      _status = result == null ? '网络校时失败，已使用设备时间' : '网络校时成功，可以开始发波';
    });
  }

  Future<void> _toggle() async {
    if (_generating || (!_broadcasting && _syncing)) return;
    final int token = ++_token;
    final bool stopping = _broadcasting;
    setState(() {
      _generating = true;
      _playbackUtc = null;
      _status = stopping ? '正在停止' : '正在准备发波';
    });
    try {
      if (stopping) {
        await _audio.stop();
      } else {
        // 不调整系统音量，应用增益固定为最大；用户使用设备音量键。
        await _audio.start(
          _preferences.protocol,
          _preferences.carrier,
          _preferences.continuous,
          1,
        );
      }
      if (!mounted || token != _token) {
        await _audio.stop();
        return;
      }
      setState(() {
        _generating = false;
        _broadcasting = !stopping;
        _frames = 0;
        _status = stopping ? '已停止发波' : '已开始发波';
      });
    } on Object catch (error) {
      if (mounted && token == _token) {
        setState(() {
          _generating = false;
          _broadcasting = false;
          _status = error is PlatformException
              ? (error.message ?? '音频输出失败')
              : '发波失败，请重试';
        });
      }
    }
  }

  String _two(int value) => value.toString().padLeft(2, '0');
  String _timeText(DateTime value) =>
      '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';
  String _dateText(DateTime value) =>
      '${value.year}.${_two(value.month)}.${_two(value.day)}';
  String get _offsetText => _offset == null
      ? '未校准'
      : '${_offset!.inMicroseconds >= 0 ? '+' : ''}${(_offset!.inMicroseconds / 1000).toStringAsFixed(1)} ms';

  void _settings() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SignalSettingsPage(
          preferences: _preferences,
          busy: _busy,
          timeSource: _server ?? '设备时钟',
          offsetText: _offsetText,
        ),
      ),
    );
  }

  /// 时区只影响显示。授时协议始终使用真实 UTC 与电台规定时区。
  Future<void> _selectZone() async {
    final List<int> offsets = <int>{
      480,
      540,
      0,
      for (int h = -12; h <= 14; h++) h * 60,
      210,
      270,
      330,
      345,
      390,
      570,
      630,
      765,
    }.toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheet) => SafeArea(
        child: SizedBox(
          height: math.min(MediaQuery.sizeOf(sheet).height * .7, 520),
          child: Column(
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  '显示时区',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18),
                child: Text(
                  '只改变表盘和数字时间，不改变电台授时码',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: offsets.length,
                  itemBuilder: (BuildContext context, int i) {
                    final int offset = offsets[i];
                    final String city = offset == 480
                        ? ' · 北京'
                        : (offset == 540 ? ' · 东京' : '');
                    return ListTile(
                      title: Text('${displayZoneLabel(offset)}$city'),
                      trailing: offset == _preferences.displayOffsetMinutes
                          ? const Icon(Icons.check, color: Color(0xFF65E4D2))
                          : null,
                      onTap: () {
                        _preferences.update(offsetMinutes: offset);
                        Navigator.of(sheet).pop();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _preferences,
    builder: (BuildContext context, Widget? child) => Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0xFF0B1A2D), Color(0xFF07111F)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(
                children: <Widget>[
                  _header(),
                  Expanded(
                    child: LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) {
                            final bool wide = constraints.maxWidth >= 680;
                            final double gridHeight =
                                _preferences.protocol == SignalProtocol.bpc
                                ? 122
                                : 234;
                            final double dial = wide
                                ? 220
                                : (constraints.maxHeight - gridHeight - 160)
                                      .clamp(82.0, 160.0);
                            final Widget detail = Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                _selectors(),
                                const SizedBox(height: 10),
                                _Surface(
                                  child: SignalFrameProgress(
                                    protocol: _preferences.protocol,
                                    previewUtc: _utcNow,
                                    transmitting: _broadcasting,
                                    playbackUtc: _playbackUtc,
                                    compact: true,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  child: Text(
                                    _status,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white60,
                                    ),
                                  ),
                                ),
                              ],
                            );
                            return SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                              child: wide
                                  ? Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Expanded(
                                          child: _clock(dial, vertical: true),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(child: detail),
                                      ],
                                    )
                                  : Column(
                                      children: <Widget>[
                                        _clock(dial),
                                        const SizedBox(height: 10),
                                        detail,
                                      ],
                                    ),
                            );
                          },
                    ),
                  ),
                  _action(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
    child: Row(
      children: <Widget>[
        CustomPaint(size: const Size(34, 34), painter: SignalTowerPainter()),
        const SizedBox(width: 9),
        const Expanded(
          child: Text(
            '电波表授时',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          tooltip: '重新校时',
          onPressed: _syncing || _busy ? null : _syncTime,
          icon: _syncing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync_rounded, size: 21),
        ),
        IconButton(
          tooltip: '设置',
          onPressed: _settings,
          icon: const Icon(Icons.tune_rounded, size: 21),
        ),
      ],
    ),
  );

  Widget _clock(double diameter, {bool vertical = false}) {
    final Widget dial = SizedBox(
      width: diameter,
      height: diameter,
      child: RepaintBoundary(
        child: CustomPaint(painter: ClockDialPainter(time: _displayTime)),
      ),
    );
    final Widget time = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: vertical
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: <Widget>[
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            _timeText(_displayTime),
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _dateText(_displayTime),
          style: const TextStyle(fontSize: 12, color: Colors.white60),
        ),
        const SizedBox(height: 8),
        Text(
          _offset == null ? '设备时钟' : 'NTP 已校准',
          style: const TextStyle(fontSize: 11, color: Color(0xFF8CEDE2)),
        ),
      ],
    );
    return _Surface(
      child: vertical
          ? Column(children: <Widget>[dial, const SizedBox(height: 14), time])
          : Row(
              children: <Widget>[
                dial,
                const SizedBox(width: 14),
                Expanded(child: time),
              ],
            ),
    );
  }

  Widget _selectors() => Row(
    children: <Widget>[
      Expanded(
        child: _Surface(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<SignalProtocol>(
              isDense: true,
              isExpanded: true,
              value: _preferences.protocol,
              items: SignalProtocol.values
                  .map(
                    (SignalProtocol p) => DropdownMenuItem<SignalProtocol>(
                      value: p,
                      child: Text(
                        p.title,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _busy
                  ? null
                  : (SignalProtocol? p) {
                      if (p != null) _preferences.update(protocol: p);
                    },
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: InkWell(
          key: const ValueKey<String>('display-zone'),
          borderRadius: BorderRadius.circular(16),
          onTap: _selectZone,
          child: _Surface(
            child: Row(
              children: <Widget>[
                const Icon(Icons.schedule, size: 16, color: Color(0xFF65E4D2)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    displayZoneLabel(_preferences.displayOffsetMinutes),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const Icon(Icons.expand_more, size: 17),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _action() => Padding(
    padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            key: const ValueKey<String>('broadcast-action'),
            onPressed: _generating || (!_broadcasting && _syncing)
                ? null
                : _toggle,
            icon: Icon(
              _broadcasting ? Icons.stop_rounded : Icons.cell_tower_rounded,
            ),
            label: Text(
              _syncing && !_broadcasting
                  ? '正在网络校时…'
                  : (_generating ? '正在准备…' : (_broadcasting ? '停止发波' : '开始发波')),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: _broadcasting
                  ? const Color(0xFFDC596A)
                  : const Color(0xFF35BFB4),
              foregroundColor: const Color(0xFF041018),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '${_preferences.continuous ? '连续' : '单帧'} · ${_preferences.carrier.title} · 已完成 $_frames 帧',
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
      ],
    ),
  );
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .05),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: .08)),
    ),
    child: child,
  );
}

/// 绘制实时指针表盘。
class ClockDialPainter extends CustomPainter {
  const ClockDialPainter({required this.time});

  final DateTime time;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) / 2 - 4;
    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF10243A));
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xFF35D5C8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
    for (int index = 0; index < 60; index++) {
      final double angle = -math.pi / 2 + index * math.pi * 2 / 60;
      // 整点位置直接显示数字，不再叠加粗刻度线。
      if (index % 5 == 0) continue;
      final double outer = radius - 5;
      final double inner = radius - 9;
      final Offset start =
          center + Offset(math.cos(angle) * inner, math.sin(angle) * inner);
      final Offset end =
          center + Offset(math.cos(angle) * outer, math.sin(angle) * outer);
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = const Color(0x6673DCD1)
          ..strokeWidth = 1,
      );
    }
    for (int hour = 1; hour <= 12; hour++) {
      final double angle = -math.pi / 2 + hour * math.pi * 2 / 12;
      final TextPainter label = TextPainter(
        text: TextSpan(
          text: '$hour',
          style: TextStyle(
            color: Colors.white70,
            fontSize: (radius * .18).clamp(8, 14),
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final Offset position =
          center +
          Offset(
            math.cos(angle) * (radius - 15) - label.width / 2,
            math.sin(angle) * (radius - 15) - label.height / 2,
          );
      label.paint(canvas, position);
    }
    void hand(double value, double length, double width, Color color) {
      final double angle = -math.pi / 2 + value * math.pi * 2;
      canvas.drawLine(
        center,
        center + Offset(math.cos(angle) * length, math.sin(angle) * length),
        Paint()
          ..color = color
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
    }

    final double hour = (time.hour % 12 + time.minute / 60) / 12;
    final double minute = (time.minute + time.second / 60) / 60;
    final double second = time.second / 60;
    hand(hour, radius * .48, 4.5, Colors.white);
    hand(minute, radius * .68, 3.2, const Color(0xFF8CEDE2));
    hand(second, radius * .77, 1.4, const Color(0xFFFFD166));
    canvas.drawCircle(center, 5, Paint()..color = const Color(0xFFFFD166));
    canvas.drawCircle(center, 2, Paint()..color = const Color(0xFF07111F));
  }

  @override
  bool shouldRepaint(covariant ClockDialPainter oldDelegate) =>
      oldDelegate.time.second != time.second ||
      oldDelegate.time.minute != time.minute ||
      oldDelegate.time.hour != time.hour;
}

/// 绘制信号塔图标。
class SignalTowerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = const Color(0xFF65E4D2)
      ..strokeWidth = 3.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final Offset center = Offset(size.width / 2, size.height * .52);
    canvas.drawCircle(
      center,
      size.width * .46,
      Paint()..color = const Color(0x2635D5C8),
    );
    canvas.drawLine(
      Offset(size.width * .5, size.height * .2),
      Offset(size.width * .5, size.height * .85),
      line,
    );
    canvas.drawLine(
      Offset(size.width * .34, size.height * .85),
      Offset(size.width * .66, size.height * .85),
      line,
    );
    canvas.drawLine(
      Offset(size.width * .42, size.height * .85),
      Offset(size.width * .5, size.height * .2),
      line,
    );
    canvas.drawLine(
      Offset(size.width * .58, size.height * .85),
      Offset(size.width * .5, size.height * .2),
      line,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: size.width * .29),
      math.pi * 1.14,
      math.pi * .72,
      false,
      line,
    );
    line.color = const Color(0xFF35BFB4);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: size.width * .42),
      math.pi * 1.15,
      math.pi * .7,
      false,
      line,
    );
    line.style = PaintingStyle.fill;
    canvas.drawCircle(Offset(size.width * .5, size.height * .2), 4, line);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
