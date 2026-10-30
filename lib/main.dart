import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ja_JP', null);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const EchoClockApp());
}

class EchoClockApp extends StatelessWidget {
  const EchoClockApp({super.key});

  static const Locale _locale = Locale('ja', 'JP');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Echo Clock',
      debugShowCheckedModeBanner: false,
      locale: _locale,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [_locale],
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late Timer _clockTimer;
  DateTime _now = DateTime.now();

  // 天気
  String _temp = '--';
  String _weatherText = '取得中...';
  String _weatherIcon = '☁️';
  String _tomorrowTemp = '--';
  String _tomorrowText = '';
  String _tomorrowIcon = '☁️';
  String _tomorrowTempMin = '--';
  String _tempMax = '--';
  String _tempMin = '--';
  String _precipProb = '--';
  String _tomorrowPrecipProb = '--';
  bool _showTomorrow = false;
  String _cityName = '東京';
  double _lat = 35.6895;
  double _lon = 139.6917;
  Timer? _weatherTimer;

  // ポモドーロタイマー
  static const int _pomoLongBreakEvery = 4; // 集中4回ごとに長い休憩
  int _pomoFocusMinutes = 25;
  int _pomoBreakMinutes = 5;
  int _pomoLongBreakMinutes = 15;
  bool _pomoIsBreak = false;
  bool _pomoRunning = false;
  int _pomoTotalSeconds = 25 * 60;
  int _pomoRemainingSeconds = 25 * 60;
  int _pomoCompletedFocus = 0;
  String _pomoSound = 'all'; // ポモドーロ終了音（curette_*.wav、「システム」はピンポーン）

  bool get _pomoIsLongBreak =>
      _pomoIsBreak &&
      _pomoCompletedFocus > 0 &&
      _pomoCompletedFocus % _pomoLongBreakEvery == 0;

  String get _pomoTimeText {
    final m = (_pomoRemainingSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_pomoRemainingSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  double get _pomoProgress => _pomoTotalSeconds == 0
      ? 0
      : 1 - _pomoRemainingSeconds / _pomoTotalSeconds;

  // アラーム
  TimeOfDay? _alarmTime;
  bool _alarmTriggered = false;
  String _selectedSound = 'system'; // 新しい変数
  double _uiScale = 1.0; // 画面サイズに応じた中身の拡大率（build で更新）
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static const int _alarmNotificationId = 0;

  // 選んだ音ごとのメッセージ（アプリ内表示とシステム通知で共用）
  String get _alarmMessage {
    switch (_selectedSound) {
      case 'miracle':
        return 'アンサー/ミスティックのウェイクアップタイム！';
      case 'eclair':
        return 'エクレールのウェイクアップタイム！';
      case 'alcana':
        return 'アルカナのウェイクアップタイム！';
      case 'all':
        return 'みんなでウェイクアップタイム！';
      default:
        return '時間です';
    }
  }

  // システム通知の初期化（許可リクエスト含む）
  Future<void> _initNotifications() async {
    try {
      tz_data.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _notifications.initialize(
        const InitializationSettings(android: androidInit),
      );
      final android = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.requestNotificationsPermission();
      await android?.requestExactAlarmsPermission();
    } catch (_) {
      // 通知が使えなくてもアプリ内アラームは動き続ける
    }
  }

  // アラームのシステム通知を現在の設定に合わせて登録し直す
  Future<void> _syncAlarmNotification() async {
    try {
      await _notifications.cancel(_alarmNotificationId);
      if (_alarmTime == null) return;

      final now = DateTime.now();
      var when = DateTime(
        now.year,
        now.month,
        now.day,
        _alarmTime!.hour,
        _alarmTime!.minute,
      );
      if (!when.isAfter(now)) {
        when = when.add(const Duration(days: 1));
      }
      final scheduled = tz.TZDateTime.from(when, tz.local);

      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'prewatch_alarm',
          'アラーム',
          channelDescription: '設定した時刻に知らせるアラーム通知',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.alarm,
        ),
      );

      try {
        await _notifications.zonedSchedule(
          _alarmNotificationId,
          'アラーム',
          _alarmMessage,
          scheduled,
          details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      } catch (_) {
        // 正確なアラームが許可されていない端末では、おおよその時刻で登録する
        await _notifications.zonedSchedule(
          _alarmNotificationId,
          'アラーム',
          _alarmMessage,
          scheduled,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    } catch (_) {
      // 登録できなくてもアプリは止めない
    }
  }

  @override
  void initState() {
    super.initState();
    _startClock();
    _boot();
    _weatherTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _fetchWeather(),
    );
  }

  // 通知の初期化が終わってから設定を読む（通知の予約状態を確認するため）
  Future<void> _boot() async {
    await _initNotifications();
    await _loadSettings();
  }

  String get _todayKey {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  // 設定の読み込み（保存が無ければ初期値のまま）。読み終わってから天気を取る
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _selectedSound = prefs.getString('sound') ?? _selectedSound;
        _cityName = prefs.getString('city') ?? _cityName;
        _lat = prefs.getDouble('lat') ?? _lat;
        _lon = prefs.getDouble('lon') ?? _lon;

        final ah = prefs.getInt('alarm_hour');
        final am = prefs.getInt('alarm_minute');
        if (ah != null && am != null) {
          _alarmTime = TimeOfDay(hour: ah, minute: am);
        }

        _pomoSound = prefs.getString('pomo_sound') ?? _pomoSound;
        _pomoFocusMinutes = prefs.getInt('pomo_focus') ?? _pomoFocusMinutes;
        _pomoBreakMinutes = prefs.getInt('pomo_break') ?? _pomoBreakMinutes;
        _pomoLongBreakMinutes =
            prefs.getInt('pomo_long_break') ?? _pomoLongBreakMinutes;

        // 完了セット数は当日の分だけ引き継ぐ
        if (prefs.getString('pomo_date') == _todayKey) {
          _pomoCompletedFocus = prefs.getInt('pomo_completed') ?? 0;
          _pomoIsBreak = prefs.getBool('pomo_is_break') ?? false;
          _pomoTotalSeconds =
              prefs.getInt('pomo_total') ?? _pomoFocusMinutes * 60;
          _pomoRemainingSeconds =
              prefs.getInt('pomo_remaining') ?? _pomoTotalSeconds;
          _pomoRunning = false; // 再起動後は一時停止状態で復帰する

          // 動作中に閉じられていた場合は、終了時刻から残りを計算する
          final wasRunning = prefs.getBool('pomo_was_running') ?? false;
          final endEpoch = prefs.getInt('pomo_end_epoch');
          if (wasRunning && endEpoch != null) {
            final left =
                (endEpoch - DateTime.now().millisecondsSinceEpoch) ~/ 1000;
            if (left > 0) {
              _pomoRemainingSeconds = left;
            } else {
              // 閉じている間に終わっていたら、次のフェーズの頭で止める
              if (!_pomoIsBreak) {
                _pomoCompletedFocus++;
                _pomoIsBreak = true;
                final minutes = _pomoCompletedFocus % _pomoLongBreakEvery == 0
                    ? _pomoLongBreakMinutes
                    : _pomoBreakMinutes;
                _pomoTotalSeconds = minutes * 60;
              } else {
                _pomoIsBreak = false;
                _pomoTotalSeconds = _pomoFocusMinutes * 60;
              }
              _pomoRemainingSeconds = _pomoTotalSeconds;
            }
          }
        } else {
          _pomoTotalSeconds = _pomoFocusMinutes * 60;
          _pomoRemainingSeconds = _pomoTotalSeconds;
        }
      });
    } catch (_) {
      // 保存が読めなくても初期値で動き続ける
    }

    // 閉じている間にシステム通知で鳴り終わったアラームは、
    // 一回限りの仕様に合わせて解除する（翌日に再登録しない）
    if (_alarmTime != null) {
      try {
        final pending = await _notifications.pendingNotificationRequests();
        final hasPending = pending.any((p) => p.id == _alarmNotificationId);
        final now = DateTime.now();
        final todayAt = DateTime(
          now.year,
          now.month,
          now.day,
          _alarmTime!.hour,
          _alarmTime!.minute,
        );
        if (!hasPending && !todayAt.isAfter(now)) {
          setState(() {
            _alarmTime = null;
          });
          _saveSettings();
        }
      } catch (_) {
        // 予約状態が確認できないときはアラームを消さない
      }
    }

    _syncAlarmNotification();
    _fetchWeather();
  }

  // 設定の保存（変更のたびに呼ぶ）
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sound', _selectedSound);
      await prefs.setString('city', _cityName);
      await prefs.setDouble('lat', _lat);
      await prefs.setDouble('lon', _lon);
      if (_alarmTime != null) {
        await prefs.setInt('alarm_hour', _alarmTime!.hour);
        await prefs.setInt('alarm_minute', _alarmTime!.minute);
      } else {
        await prefs.remove('alarm_hour');
        await prefs.remove('alarm_minute');
      }
      await prefs.setString('pomo_sound', _pomoSound);
      await prefs.setInt('pomo_focus', _pomoFocusMinutes);
      await prefs.setInt('pomo_break', _pomoBreakMinutes);
      await prefs.setInt('pomo_long_break', _pomoLongBreakMinutes);
      await prefs.setInt('pomo_completed', _pomoCompletedFocus);
      await prefs.setString('pomo_date', _todayKey);
      await prefs.setBool('pomo_is_break', _pomoIsBreak);
      await prefs.setInt('pomo_total', _pomoTotalSeconds);
      await prefs.setInt('pomo_remaining', _pomoRemainingSeconds);
      await prefs.setBool('pomo_was_running', _pomoRunning);
      if (_pomoRunning) {
        // 終了時刻を覚えておく（途中で閉じても経過時間が消えないように）
        await prefs.setInt(
          'pomo_end_epoch',
          DateTime.now().millisecondsSinceEpoch + _pomoRemainingSeconds * 1000,
        );
      } else {
        await prefs.remove('pomo_end_epoch');
      }
    } catch (_) {
      // 保存に失敗してもアプリは止めない
    }
  }

  void _startClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      setState(() {
        _now = now;
        if (_pomoRunning && _pomoRemainingSeconds > 0) {
          _pomoRemainingSeconds--;
        }
      });

      if (_pomoRunning && _pomoRemainingSeconds == 0) {
        _onPomoPhaseFinished();
      }

      if (_alarmTime != null && !_alarmTriggered) {
        // 設定した分の間なら何秒でも鳴らす（0秒ちょうどのチェックだと、
        // タイマーのずれや設定がその分に入ってから完了した場合に逃すため）
        if (now.hour == _alarmTime!.hour && now.minute == _alarmTime!.minute) {
          _alarmTriggered = true;
          _triggerAlarm();
        }
      }
    });
  }

  // 再生に失敗したら理由を画面に出す（「試す」ボタン用）。
  // 無反応で握りつぶさず、原因を目に見える形にする。
  void _showPlayError(String file, Object error) {
    debugPrint('再生に失敗: $file / $error');
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFFC9A0FF),
        title: const Text(
          '再生できませんでした',
          style: TextStyle(color: Colors.black87, fontSize: 18),
        ),
        content: Text(
          '$file\n$error',
          style: const TextStyle(color: Colors.black87, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる', style: TextStyle(color: Colors.black87)),
          ),
        ],
      ),
    );
  }

  // アラームのサウンド再生（wakeup_*.wav のウェイクアップタイム用）。
  // ファイル名は選択キーから1か所で組み立てる。
  Future<void> _playSelectedSound({bool reportError = false}) async {
    // 「システム」はピンポーン（system_chime.wav）
    final file = _selectedSound == 'system'
        ? 'system_chime.wav'
        : 'wakeup_$_selectedSound.wav';
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource(file));
    } catch (e) {
      if (reportError) {
        _showPlayError(file, e);
      } else {
        SystemSound.play(SystemSoundType.alert);
      }
    }
  }

  // ポモドーロ終了音（『キュアット解決！』の curette_*.wav セット、またはシステム音から選ぶ）
  Future<void> _playPomoSound({bool reportError = false}) async {
    // 「システム」はピンポーン（system_chime.wav）
    final file = _pomoSound == 'system'
        ? 'system_chime.wav'
        : 'curette_$_pomoSound.wav';
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource(file));
    } catch (e) {
      if (reportError) {
        _showPlayError(file, e);
      } else {
        SystemSound.play(SystemSoundType.alert);
      }
    }
  }

  Future<void> _triggerAlarm() async {
    // アプリが開いているときはアプリ側が鳴らすので、システム通知は取り消す
    await _notifications.cancel(_alarmNotificationId);
    await _playSelectedSound();

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFFC9A0FF),
        title: const Text(
          'アラーム',
          style: TextStyle(color: Colors.black87, fontSize: 20),
        ),
        content: Text(
          _alarmMessage,
          style: const TextStyle(color: Colors.black87, fontSize: 20),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await _audioPlayer.stop();
              // ignore: use_build_context_synchronously
              Navigator.pop(context);
              setState(() {
                _alarmTriggered = false;
                _alarmTime = null;
              });
              _saveSettings();
            },
            child: const Text(
              '閉じる',
              style: TextStyle(color: Colors.black87, fontSize: 20),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchWeather() async {
    try {
      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$_lat&longitude=$_lon'
        '&current=temperature_2m,weather_code'
        '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max'
        '&timezone=Asia%2FTokyo'
        '&forecast_days=2',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final current = data['current'];
        final temp = current['temperature_2m'];
        final code = current['weather_code'] as int;

        final daily = data['daily'];
        final tomorrowCode = daily['weather_code'][1] as int;
        final tomorrowMax = daily['temperature_2m_max'][1];

        String fmtTemp(dynamic v) =>
            v == null ? '--' : '${(v as num).round()}℃';
        String fmtProb(dynamic v) =>
            v == null ? '--' : '${(v as num).round()}%';
        final probs = daily['precipitation_probability_max'] as List?;

        setState(() {
          _temp = '${temp.round()}℃';
          _weatherText = _weatherCodeToText(code);
          _weatherIcon = _weatherCodeToIcon(code);
          _tempMax = fmtTemp(daily['temperature_2m_max'][0]);
          _tempMin = fmtTemp(daily['temperature_2m_min'][0]);
          _precipProb = fmtProb(
            probs != null && probs.isNotEmpty ? probs[0] : null,
          );
          _tomorrowTemp = '${tomorrowMax.round()}℃';
          _tomorrowTempMin = fmtTemp(daily['temperature_2m_min'][1]);
          _tomorrowText = _weatherCodeToText(tomorrowCode);
          _tomorrowIcon = _weatherCodeToIcon(tomorrowCode);
          _tomorrowPrecipProb = fmtProb(
            probs != null && probs.length > 1 ? probs[1] : null,
          );
        });
      }
    } catch (e) {
      setState(() {
        _weatherText = '取得失敗';
        _weatherIcon = '⚠️';
      });
    }
  }

  String _weatherCodeToText(int code) {
    if (code == 0) return '快晴';
    if (code <= 3) return '晴れ';
    if (code <= 48) return '霧';
    if (code <= 67) return '雨';
    if (code <= 77) return '雪';
    if (code <= 82) return 'にわか雨';
    if (code <= 86) return '雪';
    if (code <= 99) return '雷雨';
    return '不明';
  }

  String _weatherCodeToIcon(int code) {
    if (code == 0) return '☀️';
    if (code <= 3) return '🌤️';
    if (code <= 48) return '🌫️';
    if (code <= 67) return '🌧️';
    if (code <= 77) return '❄️';
    if (code <= 82) return '🌦️';
    if (code <= 86) return '🌨️';
    if (code <= 99) return '⛈️';
    return '☁️';
  }

  int _daysLeftInYear() {
    final end = DateTime(_now.year, 12, 31);
    return end.difference(DateTime(_now.year, _now.month, _now.day)).inDays;
  }

  int _daysLeftInWeek() {
    final weekday = _now.weekday % 7;
    return 6 - weekday;
  }

  // ポモドーロ：タップで開始／一時停止
  void _togglePomo() {
    setState(() {
      _pomoRunning = !_pomoRunning;
    });
    _saveSettings();
  }

  void _resetPomo() {
    setState(() {
      _pomoIsBreak = false;
      _pomoRunning = false;
      _pomoCompletedFocus = 0;
      _pomoTotalSeconds = _pomoFocusMinutes * 60;
      _pomoRemainingSeconds = _pomoTotalSeconds;
    });
    _saveSettings();
  }

  // フェーズ終了時：音を鳴らして次のフェーズへ
  // 集中→休憩は自動スタート、休憩→集中はタップ待ちにする（夜通し回り続けないため）
  void _onPomoPhaseFinished() {
    _playPomoSound();
    setState(() {
      if (!_pomoIsBreak) {
        _pomoCompletedFocus++;
        _pomoIsBreak = true;
        final minutes = _pomoCompletedFocus % _pomoLongBreakEvery == 0
            ? _pomoLongBreakMinutes
            : _pomoBreakMinutes;
        _pomoTotalSeconds = minutes * 60;
        _pomoRemainingSeconds = _pomoTotalSeconds;
        _pomoRunning = true;
      } else {
        _pomoIsBreak = false;
        _pomoTotalSeconds = _pomoFocusMinutes * 60;
        _pomoRemainingSeconds = _pomoTotalSeconds;
        _pomoRunning = false;
      }
    });
    _saveSettings();
  }

  void _openPomoSettings() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Widget durationRow(
              String label,
              int value,
              List<int> options,
              void Function(int) onChanged,
            ) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: const TextStyle(color: Colors.black87, fontSize: 14),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: value,
                    // ダークテーマの白文字が薄い背景で読めなくなるので、色を明示する
                    style: const TextStyle(color: Colors.black87, fontSize: 16),
                    dropdownColor: Colors.white,
                    iconEnabledColor: Colors.black54,
                    underline: Container(height: 1, color: Colors.black38),
                    onChanged: (v) {
                      if (v == null) return;
                      onChanged(v);
                      _resetPomo();
                      setDialogState(() {});
                    },
                    items: options
                        .map(
                          (m) => DropdownMenuItem(value: m, child: Text('$m分')),
                        )
                        .toList(),
                  ),
                ],
              );
            }

            return AlertDialog(
              backgroundColor: const Color(0xFFF9E778),
              title: const Text(
                'ポモドーロ設定',
                style: TextStyle(color: Colors.black87, fontSize: 18),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    durationRow('集中', _pomoFocusMinutes, const [
                      15,
                      25,
                      30,
                      50,
                    ], (v) => _pomoFocusMinutes = v),
                    durationRow('休憩', _pomoBreakMinutes, const [
                      5,
                      10,
                      15,
                    ], (v) => _pomoBreakMinutes = v),
                    durationRow('長い休憩', _pomoLongBreakMinutes, const [
                      15,
                      20,
                      30,
                    ], (v) => _pomoLongBreakMinutes = v),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          '終了音',
                          style: TextStyle(color: Colors.black87, fontSize: 14),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: _pomoSound,
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 16,
                          ),
                          dropdownColor: Colors.white,
                          iconEnabledColor: Colors.black54,
                          underline: Container(
                            height: 1,
                            color: Colors.black38,
                          ),
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              _pomoSound = v;
                            });
                            _saveSettings();
                            setDialogState(() {});
                          },
                          items: const [
                            DropdownMenuItem(
                              value: 'system',
                              child: Text('システム'),
                            ),
                            DropdownMenuItem(
                              value: 'answer',
                              child: Text('アンサー'),
                            ),
                            DropdownMenuItem(
                              value: 'mystic',
                              child: Text('ミスティック'),
                            ),
                            DropdownMenuItem(
                              value: 'miracle',
                              child: Text('アンサー/ミスティック'),
                            ),
                            DropdownMenuItem(
                              value: 'eclair',
                              child: Text('エクレール'),
                            ),
                            DropdownMenuItem(
                              value: 'alcana',
                              child: Text('アルカナ'),
                            ),
                            DropdownMenuItem(value: 'all', child: Text('全員')),
                          ],
                        ),
                        TextButton(
                          onPressed: () => _playPomoSound(reportError: true),
                          child: const Text(
                            '試す',
                            style: TextStyle(
                              color: Colors.black54,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '長い休憩は集中$_pomoLongBreakEvery回ごと',
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black87,
                        ),
                        onPressed: () {
                          _resetPomo();
                          Navigator.pop(context);
                        },
                        child: const Text(
                          'タイマーをリセット',
                          style: TextStyle(fontSize: 15),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // 時刻指定はアナログ時計（ダイヤル）方式に固定する。
  // キーボード入力はこの環境では表示崩れや無応答の原因になるため使わない。
  Future<TimeOfDay?> _inputAlarmTime() {
    return showTimePicker(
      context: context,
      initialTime: _alarmTime ?? TimeOfDay.now(),
      initialEntryMode: TimePickerEntryMode.dialOnly,
    );
  }

  void _openAlarmSettings() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFFC9A0FF),
              title: const Text(
                'アラーム設定',
                style: TextStyle(color: Colors.black87, fontSize: 18),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _alarmTime?.format(context) ?? '未設定',
                      style: const TextStyle(
                        fontSize: 24,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'サウンド',
                          style: TextStyle(color: Colors.black87, fontSize: 14),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: _selectedSound,
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 14,
                          ),
                          dropdownColor: Colors.white,
                          iconEnabledColor: Colors.black54,
                          underline: Container(
                            height: 1,
                            color: Colors.black38,
                          ),
                          onChanged: (value) {
                            setState(() {
                              _selectedSound = value!;
                            });
                            _saveSettings();
                            _syncAlarmNotification();
                            setDialogState(() {});
                          },
                          items: const [
                            DropdownMenuItem(
                              value: 'system',
                              child: Text('システム'),
                            ),
                            DropdownMenuItem(
                              value: 'miracle',
                              child: Text('アンサー/ミスティック'),
                            ),
                            DropdownMenuItem(
                              value: 'eclair',
                              child: Text('エクレール'),
                            ),
                            DropdownMenuItem(
                              value: 'alcana',
                              child: Text('アルカナ'),
                            ),
                            DropdownMenuItem(value: 'all', child: Text('全員')),
                          ],
                        ),
                        TextButton(
                          onPressed: () =>
                              _playSelectedSound(reportError: true),
                          child: const Text(
                            '試す',
                            style: TextStyle(
                              color: Colors.black54,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black87,
                        ),
                        onPressed: () async {
                          final picked = await _inputAlarmTime();
                          if (picked != null) {
                            setState(() {
                              _alarmTime = picked;
                              _alarmTriggered = false;
                            });
                            _saveSettings();
                            _syncAlarmNotification();
                            if (context.mounted) Navigator.pop(context);
                          }
                        },
                        child: const Text(
                          '時間を選択',
                          style: TextStyle(fontSize: 15),
                        ),
                      ),
                    ),
                    if (_alarmTime != null)
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _alarmTime = null;
                          });
                          _saveSettings();
                          _syncAlarmNotification();
                          Navigator.pop(context);
                        },
                        child: const Text(
                          'アラーム解除',
                          style: TextStyle(color: Colors.black54, fontSize: 14),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openRegionSettings() {
    final regions = [
      {'name': '東京', 'lat': 35.6895, 'lon': 139.6917},
      {'name': 'まことみらい', 'lat': 35.4437, 'lon': 139.6380},
      {'name': '大阪', 'lat': 34.6937, 'lon': 135.5023},
      {'name': '名古屋', 'lat': 35.1815, 'lon': 136.9066},
      {'name': '福岡', 'lat': 33.5904, 'lon': 130.4017},
      {'name': '札幌', 'lat': 43.0618, 'lon': 141.3545},
    ];

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFFA0E8FF),
          title: const Text(
            '地域を選択',
            style: TextStyle(color: Colors.black87, fontSize: 18),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: regions.map((r) {
                return ListTile(
                  dense: true,
                  title: Text(
                    r['name'] as String,
                    style: const TextStyle(color: Colors.black87, fontSize: 16),
                  ),
                  onTap: () {
                    setState(() {
                      _cityName = r['name'] as String;
                      _lat = r['lat'] as double;
                      _lon = r['lon'] as double;
                    });
                    _saveSettings();
                    _fetchWeather();
                    Navigator.pop(context);
                  },
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _saveSettings();
    _clockTimer.cancel();
    _weatherTimer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat('HH:mm:ss').format(_now);
    final dateStr = DateFormat('yyyy年M月d日', 'ja_JP').format(_now);
    final weekdayStr = DateFormat('EEEE', 'ja_JP').format(_now);

    // 大きな画面では中身も自動で拡大する。基準は Echo Show 想定の画面
    // （高さ480・幅620）で、拡大率は両方の比率の小さい方に合わせる
    final Size screenSize = MediaQuery.sizeOf(context);
    double uiScale = screenSize.height / 480;
    final double widthScale = screenSize.width / 620;
    if (widthScale < uiScale) uiScale = widthScale;
    uiScale = uiScale.clamp(1.0, 2.6).toDouble();
    _uiScale = uiScale;

    final mainTextStyle = TextStyle(
      fontSize: 32 * uiScale,
      fontWeight: FontWeight.w500,
      color: Colors.black87,
    );
    final subTextStyle = TextStyle(
      fontSize: 18 * uiScale,
      color: Colors.black54,
    );
    final smallTextStyle = TextStyle(
      fontSize: 16 * uiScale,
      color: Colors.black45,
    );

    // ポモドーロの色：集中中はキャラカラーの黄色 #F9E778、通常時は #5C526A
    // 通常時（待機・一時停止・休憩）は暗い背景になるので文字は白系にする
    final bool pomoFocusActive = !_pomoIsBreak && _pomoRunning;
    final Color pomoPanelColor = pomoFocusActive
        ? const Color(0xFFF9E778)
        : const Color(0xFF5C526A);
    final Color pomoTextColor = pomoFocusActive ? Colors.black87 : Colors.white;
    final Color pomoSubTextColor = pomoFocusActive
        ? Colors.black54
        : Colors.white70;
    final Color pomoProgressColor = pomoFocusActive
        ? Colors.black54
        : Colors.white;
    final Color pomoProgressBgColor = pomoFocusActive
        ? Colors.black12
        : Colors.white24;

    // 夜間（23時〜6時）は自動で減光する
    final bool isNight = _now.hour >= 23 || _now.hour < 6;
    // 焼け対策：表示全体を20秒ごとに最大±10pxずらす（残像・焼きつき対策）
    const burnInOffsets = [
      Offset(0, 0),
      Offset(6, 2),
      Offset(-8, 5),
      Offset(3, -7),
      Offset(-4, -9),
      Offset(10, -3),
      Offset(-10, -6),
      Offset(8, 9),
      Offset(-6, 10),
      Offset(1, -10),
      Offset(-1, 7),
      Offset(9, -9),
    ];
    final int burnInStep = (_now.minute * 60 + _now.second) ~/ 20;
    final Offset burnInOffset =
        burnInOffsets[burnInStep % burnInOffsets.length];

    return Scaffold(
      // キーボード表示時にダッシュボードを押し潰さない（潰れると各パネルが
      // overflow エラーを出し続け、固まったように見えるため）。
      // キーボードは画面の上に重なって出るようになる。
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            child: Transform.translate(
              offset: burnInOffset,
              child: Padding(
                padding: EdgeInsets.all(8.0 * uiScale),
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          // 時計
                          Expanded(
                            child: GestureDetector(
                              onTap: _openAlarmSettings,
                              child: _buildPanel(
                                color: const Color(0xFFC9A0FF),
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        timeStr,
                                        style: TextStyle(
                                          fontSize: 48 * uiScale,
                                          fontWeight: FontWeight.w400,
                                          color: Colors.black87,
                                          letterSpacing: 1.5,
                                        ),
                                      ),
                                      if (_alarmTime != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 6,
                                          ),
                                          child: Text(
                                            '⏰ ${_alarmTime!.format(context)}',
                                            style: smallTextStyle,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 日付
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    backgroundColor: const Color(0xFFFF9A9A),
                                    title: const Text(
                                      '今年の残り',
                                      style: TextStyle(
                                        color: Colors.black87,
                                        fontSize: 18,
                                      ),
                                    ),
                                    content: Text(
                                      'あと ${_daysLeftInYear()} 日',
                                      style: const TextStyle(
                                        fontSize: 22,
                                        color: Colors.black87,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                );
                              },
                              onLongPress: () {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    backgroundColor: const Color(0xFFFF9A9A),
                                    title: const Text(
                                      '今週の残り',
                                      style: TextStyle(
                                        color: Colors.black87,
                                        fontSize: 18,
                                      ),
                                    ),
                                    content: Text(
                                      'あと ${_daysLeftInWeek()} 日',
                                      style: const TextStyle(
                                        fontSize: 22,
                                        color: Colors.black87,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                );
                              },
                              child: _buildPanel(
                                color: const Color(0xFFFF9A9A),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(dateStr, style: mainTextStyle),
                                    const SizedBox(height: 6),
                                    Text(weekdayStr, style: subTextStyle),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Row(
                        children: [
                          // 天気
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _showTomorrow = !_showTomorrow;
                                });
                              },
                              onLongPress: _openRegionSettings,
                              child: _buildPanel(
                                color: const Color(0xFFA0E8FF),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (!_showTomorrow) ...[
                                      Text(
                                        _weatherIcon,
                                        style: TextStyle(
                                          fontSize: 28 * uiScale,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(_temp, style: mainTextStyle),
                                      Text(_weatherText, style: subTextStyle),
                                      Text(
                                        '最高$_tempMax 最低$_tempMin ・ ☂️$_precipProb',
                                        style: smallTextStyle,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(_cityName, style: smallTextStyle),
                                    ] else ...[
                                      Text(
                                        _tomorrowIcon,
                                        style: TextStyle(
                                          fontSize: 28 * uiScale,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(_tomorrowTemp, style: mainTextStyle),
                                      Text(
                                        '明日・$_tomorrowText',
                                        style: subTextStyle,
                                      ),
                                      Text(
                                        '最低$_tomorrowTempMin ・ ☂️$_tomorrowPrecipProb',
                                        style: smallTextStyle,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(_cityName, style: smallTextStyle),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // ポモドーロ
                          Expanded(
                            child: GestureDetector(
                              onTap: _togglePomo,
                              onLongPress: _openPomoSettings,
                              child: _buildPanel(
                                // 集中中=黄色 #F9E778／通常時= #5C526A
                                color: pomoPanelColor,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      _pomoIsBreak
                                          ? (_pomoIsLongBreak
                                                ? '☕ 長い休憩'
                                                : '☕ 休憩')
                                          : '集中',
                                      style: TextStyle(
                                        fontSize: 18 * uiScale,
                                        color: pomoSubTextColor,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _pomoTimeText,
                                      style: TextStyle(
                                        fontSize: 44 * uiScale,
                                        fontWeight: FontWeight.w400,
                                        color: pomoTextColor,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 28,
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(3),
                                        child: LinearProgressIndicator(
                                          value: _pomoProgress,
                                          minHeight: 6 * uiScale,
                                          backgroundColor: pomoProgressBgColor,
                                          color: pomoProgressColor,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _pomoRunning ? 'タップで一時停止' : 'タップでスタート',
                                      style: TextStyle(
                                        fontSize: 16 * uiScale,
                                        color: pomoSubTextColor,
                                      ),
                                    ),
                                    Text(
                                      '完了 $_pomoCompletedFocus セット ・ 長押しで設定',
                                      style: TextStyle(
                                        fontSize: 16 * uiScale,
                                        color: pomoSubTextColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isNight)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(color: Colors.black.withValues(alpha: 0.45)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPanel({required Color color, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16 * _uiScale),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}
