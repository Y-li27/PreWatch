import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:image_picker/image_picker.dart';
import 'package:audioplayers/audioplayers.dart';
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
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
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
  bool _showTomorrow = false;
  String _cityName = '東京';
  double _lat = 35.6895;
  double _lon = 139.6917;
  Timer? _weatherTimer;

  // スライドショー
  List<File> _images = [];
  int _currentIndex = 0;
  Timer? _slideshowTimer;
  final ImagePicker _picker = ImagePicker();

  // アラーム
  TimeOfDay? _alarmTime;
  bool _alarmTriggered = false;
  String _selectedSound = 'system'; // 新しい変数
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _startClock();
    _fetchWeather();
    _weatherTimer = Timer.periodic(const Duration(minutes: 30), (_) => _fetchWeather());
  }

  void _startClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      setState(() {
        _now = now;
      });

      if (_alarmTime != null && !_alarmTriggered) {
        if (now.hour == _alarmTime!.hour &&
            now.minute == _alarmTime!.minute &&
            now.second == 0) {
          _alarmTriggered = true;
          _triggerAlarm();
        }
      }
    });
  }

  Future<void> _triggerAlarm() async {
    try {
      switch (_selectedSound) {
        case 'system':
          SystemSound.play(SystemSoundType.alert);
          break;
        case 'miracle':
          await _audioPlayer.play(AssetSource('miracle.wav'));
          break;
        case 'eclaire':
          await _audioPlayer.play(AssetSource('ecl.wav'));
          break;
      }
    } catch (_) {
      SystemSound.play(SystemSoundType.alert);
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFFC9A0FF),
        title: const Text('アラーム', style: TextStyle(color: Colors.black87, fontSize: 20)),
        content: const Text('プリキュア！ウェイクアップタイム！', style: TextStyle(color: Colors.black87, fontSize: 20)),
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
            },
            child: const Text('閉じる', style: TextStyle(color: Colors.black87, fontSize: 20)),
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
        '&daily=weather_code,temperature_2m_max'
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

        setState(() {
          _temp = '${temp.round()}°';
          _weatherText = _weatherCodeToText(code);
          _weatherIcon = _weatherCodeToIcon(code);
          _tomorrowTemp = '${tomorrowMax.round()}°';
          _tomorrowText = _weatherCodeToText(tomorrowCode);
          _tomorrowIcon = _weatherCodeToIcon(tomorrowCode);
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

  Future<void> _pickImages() async {
    try {
      final List<XFile> files = await _picker.pickMultiImage();
      if (files.isEmpty) return;

      final List<File> newImages = files.map((f) => File(f.path)).toList();
      _slideshowTimer?.cancel();

      setState(() {
        _images = newImages;
        _currentIndex = 0;
      });

      _slideshowTimer = Timer.periodic(const Duration(seconds: 8), (_) {
        if (_images.isEmpty) return;
        setState(() {
          _currentIndex = (_currentIndex + 1) % _images.length;
        });
      });
    // ignore: empty_catches
    } catch (e) {}
  }

  void _clearImages() {
    _slideshowTimer?.cancel();
    setState(() {
      _images = [];
      _currentIndex = 0;
    });
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
                      style: const TextStyle(fontSize: 24, color: Colors.black87),
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
                          onChanged: (value) {
                            setState(() {
                              _selectedSound = value!;
                            });
                            setDialogState(() {});
                          },
                          items: const [
                            DropdownMenuItem(value: 'system', child: Text('システム')),
                            DropdownMenuItem(value: 'miracle', child: Text('アンサー/ミスティック')),
                            DropdownMenuItem(value: 'eclaire', child: Text('エクレール')),
                          ],
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
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: _alarmTime ?? TimeOfDay.now(),
                          );
                          if (picked != null) {
                            setState(() {
                              _alarmTime = picked;
                              _alarmTriggered = false;
                            });
                            if (context.mounted) Navigator.pop(context);
                          }
                        },
                        child: const Text('時間を選択', style: TextStyle(fontSize: 15)),
                      ),
                    ),
                    if (_alarmTime != null)
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _alarmTime = null;
                          });
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
          title: const Text('地域を選択', style: TextStyle(color: Colors.black87, fontSize: 18)),
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
    _clockTimer.cancel();
    _weatherTimer?.cancel();
    _slideshowTimer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat('HH:mm:ss').format(_now);
    final dateStr = DateFormat('yyyy年M月d日', 'ja_JP').format(_now);
    final weekdayStr = DateFormat('EEEE', 'ja_JP').format(_now);

    const mainTextStyle = TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w500,
      color: Colors.black87,
    );
    const subTextStyle = TextStyle(
      fontSize: 18,
      color: Colors.black54,
    );
    const smallTextStyle = TextStyle(
      fontSize: 16,
      color: Colors.black45,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
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
                                  style: const TextStyle(
                                    fontSize: 48,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.black87,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                                if (_alarmTime != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6),
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
                              title: const Text('今年の残り', style: TextStyle(color: Colors.black87, fontSize: 18)),
                              content: Text(
                                'あと ${_daysLeftInYear()} 日',
                                style: const TextStyle(fontSize: 22, color: Colors.black87),
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
                              title: const Text('今週の残り', style: TextStyle(color: Colors.black87, fontSize: 18)),
                              content: Text(
                                'あと ${_daysLeftInWeek()} 日',
                                style: const TextStyle(fontSize: 22, color: Colors.black87),
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
                                Text(_weatherIcon, style: const TextStyle(fontSize: 28)),
                                const SizedBox(height: 2),
                                Text(_temp, style: mainTextStyle),
                                Text(_weatherText, style: subTextStyle),
                                const SizedBox(height: 4),
                                Text(_cityName, style: smallTextStyle),
                              ] else ...[
                                Text(_tomorrowIcon, style: const TextStyle(fontSize: 28)),
                                const SizedBox(height: 2),
                                Text(_tomorrowTemp, style: mainTextStyle),
                                Text('明日・$_tomorrowText', style: subTextStyle),
                                const SizedBox(height: 4),
                                Text(_cityName, style: smallTextStyle),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 画像
                    Expanded(
                      child: GestureDetector(
                        onTap: _pickImages,
                        onLongPress: _clearImages,
                        child: _buildPanel(
                          color: const Color(0xFFB0B0B0),
                          child: _images.isNotEmpty
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.file(
                                    _images[_currentIndex],
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                    height: double.infinity,
                                    errorBuilder: (context, error, stackTrace) {
                                      return const Center(
                                        child: Text(
                                          '画像を読み込めません',
                                          style: TextStyle(color: Colors.black54, fontSize: 14),
                                        ),
                                      );
                                    },
                                  ),
                                )
                              : const Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.photo_library, size: 32, color: Colors.black54),
                                      SizedBox(height: 8),
                                      Text(
                                        'タップして画像を選択\n（複数可）\n長押しで解除',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: Colors.black54,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
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
    );
  }

  Widget _buildPanel({required Color color, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
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