import 'dart:async';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import 'package:vibration/vibration.dart';

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '地図鬼ごっこ',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const LobbyScreen(),
    );
  }
}

// ロビー画面
class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  final _sessionCodeController = TextEditingController();
  final _playerNameController = TextEditingController();
  bool _isOni = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('地図鬼ごっこ - マルチプレイ')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, size: 64, color: Colors.deepPurple),
              const SizedBox(height: 20),
              const Text('プレイヤー名を入力', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              TextField(
                controller: _playerNameController,
                decoration: const InputDecoration(
                  hintText: 'プレイヤー名',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 30),
              const Text('ゲームロール選択', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isOni ? Colors.red : Colors.grey,
                      ),
                      onPressed: () => setState(() => _isOni = true),
                      child: const Text('鬼役になる'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: !_isOni ? Colors.blue : Colors.grey,
                      ),
                      onPressed: () => setState(() => _isOni = false),
                      child: const Text('逃げ役になる'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: () => _createSession(),
                icon: const Icon(Icons.add),
                label: const Text('新しいゲームを作成'),
              ),
              const SizedBox(height: 20),
              const Text('または', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              TextField(
                controller: _sessionCodeController,
                decoration: const InputDecoration(
                  hintText: 'セッションコードを入力',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () => _joinSession(),
                icon: const Icon(Icons.login),
                label: const Text('ゲームに参加'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _createSession() {
    if (_playerNameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('プレイヤー名を入力してください')),
      );
      return;
    }

    final sessionCode = Random().nextInt(9000).toString().padLeft(4, '0');
    final playerId = const Uuid().v4();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GameScreen(
          sessionCode: sessionCode,
          playerId: playerId,
          playerName: _playerNameController.text,
          isOni: _isOni,
        ),
      ),
    );
  }

  void _joinSession() {
    if (_sessionCodeController.text.isEmpty || _playerNameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('セッションコードとプレイヤー名を入力してください')),
      );
      return;
    }

    final playerId = const Uuid().v4();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GameScreen(
          sessionCode: _sessionCodeController.text,
          playerId: playerId,
          playerName: _playerNameController.text,
          isOni: _isOni,
        ),
      ),
    );
  }
}

// ゲーム画面
class GameScreen extends StatefulWidget {
  final String sessionCode;
  final String playerId;
  final String playerName;
  final bool isOni;

  const GameScreen({
    super.key,
    required this.sessionCode,
    required this.playerId,
    required this.playerName,
    required this.isOni,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  StreamSubscription<Position>? _positionStreamSubscription;
  final Distance _distance = Distance();
  LatLng? _myLocation;
  LatLng? _centerPoint;
  Map<String, PlayerData> _players = {};
  bool _permissionGranted = false;
  bool _isInRange = true;
  String _message = '位置情報の許可を確認中...';
  static const double RANGE_KM = 3.0;
  late DatabaseReference _sessionRef;
  late DatabaseReference _playerRef;

  @override
  void initState() {
    super.initState();
    _initFirebase();
    _initLocation();
  }

  void _initFirebase() {
    _sessionRef = FirebaseDatabase.instance.ref('sessions/${widget.sessionCode}');
    _playerRef = _sessionRef.child('players/${widget.playerId}');

    // プレイヤー情報を登録
    _playerRef.set({
      'name': widget.playerName,
      'isOni': widget.isOni,
      'latitude': 0,
      'longitude': 0,
      'timestamp': ServerValue.timestamp,
    });

    // 他のプレイヤーの位置情報を監視
    _sessionRef.child('players').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data != null) {
        _players.clear();
        data.forEach((key, value) {
          if (value is Map) {
            _players[key] = PlayerData(
              playerId: key,
              name: value['name'] ?? '',
              isOni: value['isOni'] ?? false,
              latitude: (value['latitude'] ?? 0).toDouble(),
              longitude: (value['longitude'] ?? 0).toDouble(),
            );
          }
        });
        setState(() {});
      }
    });
  }

  Future<void> _initLocation() async {
    try {
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          setState(() {
            _message = '位置情報サービスが有効になっていません。';
          });
          return;
        }

        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }

        if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
          setState(() {
            _message = '位置情報の許可が必要です。';
          });
          return;
        }
      }

      setState(() {
        _permissionGranted = true;
        _message = '位置情報を取得中...';
      });

      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      _updateLocation(position);

      const settings = LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5);
      _positionStreamSubscription = Geolocator.getPositionStream(locationSettings: settings).listen(_updateLocation);
    } catch (e) {
      setState(() {
        _message = '位置情報を取得できませんでした: $e';
      });
    }
  }

  void _updateLocation(Position position) {
    final current = LatLng(position.latitude, position.longitude);

    if (_centerPoint == null) {
      _centerPoint = current;
    }

    // Firebaseに位置情報をアップロード
    _playerRef.update({
      'latitude': current.latitude,
      'longitude': current.longitude,
      'timestamp': ServerValue.timestamp,
    });

    final distanceFromCenter = _distance(current, _centerPoint!);
    final wasInRange = _isInRange;
    _isInRange = distanceFromCenter <= RANGE_KM * 1000;

    if (wasInRange && !_isInRange) {
      _triggerRangeAlarm();
    }

    setState(() {
      _myLocation = current;
      _message = _isInRange
          ? '位置情報を取得しました！'
          : '警告: 範囲外です！${(distanceFromCenter / 1000).toStringAsFixed(1)}km離れています';
    });
  }

  void _triggerRangeAlarm() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 1000);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('範囲外に出ました！3km以内に戻ってください'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 5),
      ),
    );
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    _playerRef.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('セッション: ${widget.sessionCode}'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'プレイヤー: ${_players.length}',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
      body: _permissionGranted
          ? _myLocation == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('位置情報を取得しています...'),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    FlutterMap(
                      options: MapOptions(
                        initialCenter: _myLocation!,
                        initialZoom: 16,
                        maxZoom: 18,
                        minZoom: 12,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.flutter_application_1',
                        ),
                        if (_centerPoint != null)
                          CircleLayer(
                            circles: [
                              CircleMarker(
                                point: _centerPoint!,
                                radius: RANGE_KM * 1000,
                                color: _isInRange ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                                borderColor: _isInRange ? Colors.green : Colors.red,
                                borderStrokeWidth: 2,
                              ),
                            ],
                          ),
                        MarkerLayer(
                          markers: [
                            if (_centerPoint != null)
                              Marker(
                                point: _centerPoint!,
                                child: const Icon(Icons.home, color: Colors.purple, size: 40),
                              ),
                            Marker(
                              point: _myLocation!,
                              child: const Icon(Icons.person_pin_circle, color: Colors.blue, size: 48),
                            ),
                            ..._players.entries.map((entry) {
                              final player = entry.value;
                              if (player.latitude == 0 && player.longitude == 0) return null;
                              final playerLocation = LatLng(player.latitude, player.longitude);
                              return Marker(
                                point: playerLocation,
                                child: Column(
                                  children: [
                                    Icon(
                                      player.isOni ? Icons.whatshot : Icons.directions_run,
                                      color: player.isOni ? Colors.red : Colors.green,
                                      size: 40,
                                    ),
                                    Container(
                                      color: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: Text(
                                        player.name,
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).whereType<Marker>(),
                          ],
                        ),
                      ],
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        color: Colors.white.withOpacity(0.9),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _message,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _isInRange ? Colors.black : Colors.red,
                              ),
                            ),
                            const SizedBox(height: 4),
                            if (_centerPoint != null && _myLocation != null)
                              Text(
                                '中心からの距離: ${(_distance(_myLocation!, _centerPoint!) / 1000).toStringAsFixed(2)} km',
                                style: TextStyle(color: _isInRange ? Colors.green : Colors.red),
                              ),
                            const SizedBox(height: 8),
                            const Text('接続中のプレイヤー:', style: TextStyle(fontWeight: FontWeight.bold)),
                            ..._players.entries.map((entry) {
                              final player = entry.value;
                              return Text(
                                '${player.name} - ${player.isOni ? '鬼役' : '逃げ役'}',
                                style: TextStyle(color: player.isOni ? Colors.red : Colors.blue),
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
          : Center(child: Text(_message)),
    );
  }
}

class PlayerData {
  final String playerId;
  final String name;
  final bool isOni;
  final double latitude;
  final double longitude;

  PlayerData({
    required this.playerId,
    required this.name,
    required this.isOni,
    required this.latitude,
    required this.longitude,
  });
}

