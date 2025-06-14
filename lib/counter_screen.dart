import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'home_page_screen.dart';

void main() {
  // Inisialisasi logger
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Meter Monitoring',
      debugShowCheckedModeBanner: false, // Hilangkan debug banner
      theme: ThemeData(primarySwatch: Colors.blue),
      home:
          const HomePageScreen(), // Langsung set HomePage sebagai halaman awal
    );
  }
}

class DeviceStatus {
  final bool fan;
  final bool lamp;
  final bool ac;
  final bool dispenser;
  final bool systemActive;
  final int maxOccupancy;

  DeviceStatus({
    required this.fan,
    required this.lamp,
    required this.ac,
    required this.dispenser,
    required this.systemActive,
    this.maxOccupancy = 10,
  });

  factory DeviceStatus.fromJson(Map<String, dynamic> json) {
    bool convertToBool(dynamic value) {
      if (value is bool) return value;
      if (value is int) return value != 0;
      if (value is String) {
        return value.toLowerCase() == 'true' || value == '1';
      }
      return false;
    }

    final systemActive = convertToBool(json['system_active']);
    // convertToBool(json['system_active']);
    return DeviceStatus(
      fan: systemActive ? convertToBool(json['fan_status']) : false,
      lamp: systemActive ? convertToBool(json['lamp_status']) : false,
      ac: systemActive ? convertToBool(json['ac_status']) : false,
      dispenser: systemActive ? convertToBool(json['dispenser_status']) : false,
      systemActive: systemActive,
      maxOccupancy: json['max_occupancy'] is int ? json['max_occupancy'] : 10,
    );
  }
}

final String accessKey = 'b1e8024f40e20d77:9f09d4019f441404';
final String projectName = 'TA-YAZ';
final String deviceName = 'COUNTER';

class AntaresMqttService {
  late MqttServerClient client;
  final Function(Map<String, dynamic>) onDataReceived;
  final Function(bool) onConnectionStatusChanged;
  final logger = Logger('AntaresMqttService');

  AntaresMqttService({
    required this.onDataReceived,
    required this.onConnectionStatusChanged,
  });

  Future<void> connect() async {
    try {
      client = MqttServerClient(
        'mqtt.antares.id',
        'dart_client_${DateTime.now().millisecondsSinceEpoch}',
      );
      client.port = 1883;
      client.keepAlivePeriod = 60;
      client.onConnected = _onConnected;
      client.onDisconnected = _onDisconnected;
      client.onSubscribed = _onSubscribed;

      final connMessage = MqttConnectMessage()
          .withClientIdentifier(
            'dart_client_${DateTime.now().millisecondsSinceEpoch}',
          )
          .startClean()
          .withWillQos(MqttQos.atLeastOnce);

      client.connectionMessage = connMessage;

      await client.connect();
    } catch (e) {
      logger.severe('Connection exception: $e');
      await _reconnect();
    }
  }

  Future<void> _reconnect() async {
    logger.info('Attempting reconnect...');
    await Future.delayed(const Duration(seconds: 5));
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      await connect();
    }
  }

  void _onSubscribed(String topic) {
    logger.info('Subscribed to $topic');
    client.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage message = c[0].payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(
        message.payload.message,
      );
      _processMqttData(payload);
    });
  }

  void _onConnected() {
    logger.info('Connected to Antares');
    onConnectionStatusChanged(true);

    final topic =
        '/oneM2M/resp/antares-cse/b1e8024f40e20d77:9f09d4019f441404/json';

    client.subscribe(topic, MqttQos.atLeastOnce);
  }

  void _onDisconnected() {
    logger.warning('Disconnected from Antares');
    onConnectionStatusChanged(false);
    Future.delayed(const Duration(seconds: 5), () {
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        connect();
      }
    });
  }

  void _processMqttData(String payload) {
    debugPrint('Data MQTT Received: $payload');
    try {
      final data = jsonDecode(payload);
      Map<String, dynamic>? contentData;

      // Coba ekstrak data dari format Antares
      if (data['m2m:rsp'] != null &&
          data['m2m:rsp']['m2m:cin'] != null &&
          data['m2m:rsp']['m2m:cin']['con'] != null) {
        // Pastikan con adalah string sebelum decode JSON lagi
        final conData = data['m2m:rsp']['m2m:cin']['con'];
        if (conData is String) {
          contentData = jsonDecode(conData);
        } else {
          contentData = conData;
        }
      }
      // Jika datanya langsung
      else if (data['con'] != null) {
        final conData = data['con'];
        if (conData is String) {
          contentData = jsonDecode(conData);
        } else {
          contentData = conData;
        }
      }
      // Jika data ESP32 langsung dikirim sebagai JSON root
      else if (data['Jumlah Orang Masuk'] != null) {
        contentData = data;
      }

      if (contentData != null) {
        onDataReceived(contentData);
      }
    } catch (e) {
      logger.severe('Error processing MQTT data: $e\nPayload: $payload');
    }
  }

  void disconnect() {
    client.disconnect();
  }
}

class CounterScreen extends StatefulWidget {
  const CounterScreen({super.key});

  @override
  State<CounterScreen> createState() => _CounterScreenState();
}

class _CounterScreenState extends State<CounterScreen> {
  DateTime now = DateTime.now();
  bool isWorkingHours = false;
  bool _isConnectedToAntares = false;
  bool _isDisposed = false;
  int peopleIn = 0;
  int peopleOut = 0;
  Timer? _timer;
  Timer? _httpPollingTimer;
  bool isLoading = false;
  final logger = Logger('CounterScreenState');
  late AntaresMqttService _antaresService;
  bool _hasInitialDataOnHoliday = false; // Flag untuk data awal pada hari libur
  DeviceStatus _deviceStatus = DeviceStatus(
    fan: false,
    lamp: false,
    ac: false,
    dispenser: false,
    systemActive: false,
  );

  static const List<Map<String, int>> holidays = [
    {'month': 1, 'day': 1},
    {'month': 2, 'day': 14},
    {'month': 3, 'day': 3},
    {'month': 3, 'day': 29},
    {'month': 3, 'day': 30},
    {'month': 3, 'day': 31},
    {'month': 4, 'day': 1},
    {'month': 4, 'day': 2},
    {'month': 4, 'day': 3},
    {'month': 4, 'day': 4},
    {'month': 4, 'day': 5},
    {'month': 4, 'day': 6},
    {'month': 4, 'day': 7},
    {'month': 4, 'day': 18},
    {'month': 5, 'day': 1},
    {'month': 5, 'day': 13},
    {'month': 5, 'day': 29},
    {'month': 6, 'day': 1},
    {'month': 8, 'day': 17},
    {'month': 9, 'day': 8},
    {'month': 12, 'day': 25},
    {'month': 12, 'day': 31},
  ];

  @override
  void initState() {
    super.initState();

    final currentHour = DateTime.now().hour;
    final bool isWeekendDay = isWeekend(DateTime.now());
    final bool isHolidayDay = isHoliday(DateTime.now());
    isWorkingHours =
        !isWeekendDay && !isHolidayDay && currentHour >= 9 && currentHour < 16;

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          now = DateTime.now();
        });
        checkWorkingHours();
      }
    });
    _initMqttService();
    fetchDataFromAntares();
    _setupHttpPollingTimer();
  }

  void _setupHttpPollingTimer() {
    // Cancel timer yang sudah ada (jika ada)
    _httpPollingTimer?.cancel();

    // Tentukan apakah hari ini adalah hari libur atau weekend
    final bool isWeekendDay = isWeekend(now);
    final bool isHolidayDay = isHoliday(now);
    final bool isNonWorkingDay = isWeekendDay || isHolidayDay;

    if (isNonWorkingDay) {
      // Pada hari libur/weekend, ambil data sekali saja jika belum diambil
      if (!_hasInitialDataOnHoliday) {
        fetchDataFromAntares();
        _hasInitialDataOnHoliday = true;
      }
      // Tidak perlu membuat timer polling
      logger.info('Hari libur/weekend: data hanya diambil sekali');
    } else {
      // Pada hari kerja, lakukan polling setiap 5 detik
      _httpPollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
        if (mounted) {
          fetchDataFromAntares();
        }
      });
      logger.info('Hari kerja: polling data setiap 5 detik');
    }
  }

  void _initMqttService() {
    _antaresService = AntaresMqttService(
      onDataReceived: (data) {
        if (!mounted) return;
        updateDataFromMqtt(data);
      },
      onConnectionStatusChanged: (isConnected) {
        if (!mounted) return;
        setState(() {
          _isConnectedToAntares = isConnected;
        });
      },
    );
    connectToMqtt();
  }

  Future<void> connectToMqtt() async {
    try {
      await _antaresService.connect();
    } catch (_) {
      if (!_isDisposed) {
        await Future.delayed(const Duration(seconds: 10));
        connectToMqtt();
      }
    }
  }

  void updateDataFromMqtt(Map<String, dynamic> data) {
    if (!mounted) return;
    setState(() {
      peopleIn = data['Jumlah Orang Masuk'] ?? peopleIn;
      peopleOut = data['Jumlah Orang Keluar'] ?? peopleOut;
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _timer?.cancel();
    _httpPollingTimer?.cancel();
    _antaresService.disconnect();
    super.dispose();
  }

  Future<void> fetchDataFromAntares() async {
    logger.info('Fetching data from HTTP at ${DateTime.now()}');
    if (isLoading || !mounted) return;

    setState(() => isLoading = true);
    try {
      final response = await http
          .get(
            Uri.parse(
              'https://platform.antares.id:8443/~/antares-cse/antares-id/$projectName/$deviceName/la',
            ),
            headers: {'X-M2M-Origin': accessKey, 'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['m2m:cin']?['con'] != null) {
          final deviceData = jsonDecode(data['m2m:cin']['con']);
          if (deviceData is Map<String, dynamic>) {
            setState(() {
              peopleIn = deviceData['Jumlah Orang Masuk'] ?? 0;
              peopleOut = deviceData['Jumlah Orang Keluar'] ?? 0;
              _deviceStatus = DeviceStatus.fromJson(deviceData);

              // Tandai bahwa data sudah diambil untuk hari libur
              final bool isWeekendDay = isWeekend(now);
              final bool isHolidayDay = isHoliday(now);
              if (isWeekendDay || isHolidayDay) {
                _hasInitialDataOnHoliday = true;
              }
            });
          }
        }
      } else {
        logger.severe('Failed to fetch data: ${response.statusCode}');
        // Coba lagi jika hari kerja, tapi jangan coba lagi otomatis jika hari libur
        if (!isWeekend(now) && !isHoliday(now)) {
          await Future.delayed(const Duration(seconds: 5));
          fetchDataFromAntares();
        }
      }
    } catch (e) {
      logger.severe('Fetch error: $e');
      // Coba lagi jika hari kerja, tapi jangan coba lagi otomatis jika hari libur
      if (!isWeekend(now) && !isHoliday(now)) {
        await Future.delayed(const Duration(seconds: 5));
        fetchDataFromAntares();
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void checkWorkingHours() {
    final currentHour = now.hour;
    final bool isWeekendDay = isWeekend(now);
    final bool isHolidayDay = isHoliday(now);

    final bool isCurrentlyWorkingHours =
        !isWeekendDay &&
        !isHolidayDay &&
        currentHour >= 9 &&
        currentHour < 16; // Sesuai dengan yang ditampilkan di UI (09:00-16:00)

    // Jika status hari kerja berubah, setup ulang timer polling
    if (isWorkingHours != isCurrentlyWorkingHours) {
      setState(() {
        isWorkingHours = isCurrentlyWorkingHours;
      });

      // Reset flag data awal hari libur jika berpindah dari hari kerja ke hari libur
      if (!isCurrentlyWorkingHours && isWorkingHours) {
        _hasInitialDataOnHoliday = false;
      }

      // Setup ulang timer polling sesuai dengan hari kerja/libur yang baru
      _setupHttpPollingTimer();
    }
  }

  String getIndonesianMonth(int month) {
    const months = [
      'Januari',
      'Februari',
      'Maret',
      'April',
      'Mei',
      'Juni',
      'Juli',
      'Agustus',
      'September',
      'Oktober',
      'November',
      'Desember',
    ];
    return months[month - 1];
  }

  String getIndonesianDay(int weekday) {
    const days = [
      'Senin',
      'Selasa',
      'Rabu',
      'Kamis',
      'Jumat',
      'Sabtu',
      'Minggu',
    ];
    return days[weekday - 1]; // Corrected indexing (weekday is 1-7)
  }

  bool isHoliday(DateTime date) {
    return holidays.any(
      (h) => h['month'] == date.month && h['day'] == date.day,
    );
  }

  bool isWeekend(DateTime date) {
    return date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
  }

  String getHolidayOrWeekendInfo() {
    if (isHoliday(now)) return 'Hari Libur Nasional';
    if (isWeekend(now)) return 'Weekend';
    return '';
  }

  Widget buildStatusRow(String name, bool isOn) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(name, style: const TextStyle(fontSize: 16)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: isOn ? Colors.green[50] : Colors.red[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isOn ? Colors.green : Colors.red,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isOn ? Icons.power : Icons.power_off,
                  color: isOn ? Colors.green : Colors.red,
                  size: 16,
                ),
                const SizedBox(width: 4),
                Text(
                  isOn ? 'Menyala' : 'Mati',
                  style: TextStyle(
                    color: isOn ? Colors.green : Colors.red,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildDeviceStatus() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Status Perangkat:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Column(
              children: [
                buildStatusRow(
                  'Kipas',
                  _deviceStatus.systemActive && _deviceStatus.fan,
                ),
                const Divider(),
                buildStatusRow(
                  'Lampu',
                  _deviceStatus.systemActive && _deviceStatus.lamp,
                ),
                const Divider(),
                buildStatusRow(
                  'AC',
                  _deviceStatus.systemActive && _deviceStatus.ac,
                ),
                const Divider(),
                buildStatusRow(
                  'Dispenser',
                  _deviceStatus.systemActive && _deviceStatus.dispenser,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildPeopleCounter() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Jumlah Orang Masuk:',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  '$peopleIn/${_deviceStatus.maxOccupancy}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: peopleIn / _deviceStatus.maxOccupancy,
              backgroundColor: Colors.grey[200],
              color:
                  peopleIn >= _deviceStatus.maxOccupancy
                      ? Colors.red
                      : Colors.blue,
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Jumlah Orang Keluar:',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  '$peopleOut',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildSystemStatusCard() {
    final bool isWeekendDay = isWeekend(now);
    final bool isHolidayDay = isHoliday(now);
    final bool isSystemReallyActive =
        !isWeekendDay &&
        !isHolidayDay &&
        _deviceStatus.systemActive &&
        isWorkingHours;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Status Sistem: ${isSystemReallyActive ? 'AKTIF' : 'NON-AKTIF'}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isSystemReallyActive ? Colors.green : Colors.red,
              ),
            ),
            if (isHolidayDay) const Text('Hari Libur Nasional'),
            if (isWeekendDay) const Text('Weekend'),
            const SizedBox(height: 2),
            Text(
              isWeekendDay || isHolidayDay
                  ? 'Libur Kerja'
                  : 'Jam Kerja: 09:00 - 16:00',
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildManualControlButton() {
    return SizedBox(
      height: 70,
      child: ElevatedButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const ManualControlScreen(),
            ),
          );
        },
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: const Text('Kontrol Manual', style: TextStyle(fontSize: 14)),
      ),
    );
  }

  Widget buildConnectionStatusIndicator() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _isConnectedToAntares ? Icons.cloud_done : Icons.cloud_off,
          color: _isConnectedToAntares ? Colors.green : Colors.red,
        ),
        const SizedBox(width: 4),
        Text(
          _isConnectedToAntares ? 'Terhubung ke Antares' : 'Tidak terhubung',
          style: TextStyle(
            color: _isConnectedToAntares ? Colors.green : Colors.red,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kontrol Otomatis'),
        actions: [
          const SizedBox(width: 8),
          IconButton(
            icon:
                isLoading
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.refresh),
            onPressed: isLoading ? null : fetchDataFromAntares,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${getIndonesianDay(now.weekday)}, ${now.day} ${getIndonesianMonth(now.month)} ${now.year}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        DateFormat('HH:mm:ss').format(now),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  buildConnectionStatusIndicator(),
                ],
              ),
              const SizedBox(height: 20),
              buildPeopleCounter(),
              const SizedBox(height: 20),
              buildDeviceStatus(),
              const SizedBox(height: 20),
              // Baris baru untuk menempatkan status sistem dan tombol kontrol manual berdampingan
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 2, child: buildSystemStatusCard()),
                    const SizedBox(width: 70),
                    Expanded(flex: 1, child: buildManualControlButton()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: isLoading ? null : fetchDataFromAntares,
        tooltip: 'Refresh',
        child:
            isLoading
                ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.refresh),
      ),
    );
  }
}

class ManualControlScreen extends StatefulWidget {
  final bool initialFanStatus;
  final bool initialLampStatus;
  final bool initialAcStatus;
  final bool initialDispenserStatus;
  final bool systemActive;

  const ManualControlScreen({
    super.key,
    this.initialFanStatus = false,
    this.initialLampStatus = false,
    this.initialAcStatus = false,
    this.initialDispenserStatus = false,
    this.systemActive = false,
  });

  @override
  State<ManualControlScreen> createState() => _ManualControlScreenState();
}

class _ManualControlScreenState extends State<ManualControlScreen> {
  late bool fanStatus;
  late bool lampStatus;
  late bool acStatus;
  late bool dispenserStatus;
  late bool isSystemActive;
  bool isSending = false; // Flag for request in progress
  bool _isMqttConnected = false;
  bool _waitingForConfirmation = false;
  String? _lastRequestId;
  final logger = Logger('ManualControlScreen');

  // MQTT Configuration
  MqttServerClient? client;
  final String _mqttBroker = 'mqtt.antares.id';
  final int _mqttPort = 1883;
  final String _accessKey = 'b1e8024f40e20d77:9f09d4019f441404';
  final String _projectName = 'TA-YAZ';
  final String _deviceName = 'COUNTER';
  final String _clientId =
      'dart_client_${DateTime.now().millisecondsSinceEpoch}';
  final String _responseTopic =
      '/oneM2M/resp/b1e8024f40e20d77:9f09d4019f441404/antares-cse/json';
  final String _requestTopic =
      '/oneM2M/req/b1e8024f40e20d77:9f09d4019f441404/antares-cse/json';
  StreamSubscription? _mqttSubscription;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    fanStatus = widget.initialFanStatus;
    lampStatus = widget.initialLampStatus;
    acStatus = widget.initialAcStatus;
    dispenserStatus = widget.initialDispenserStatus;
    isSystemActive = widget.systemActive;
    _setupLogging();
    _connectMqtt();
  }

  @override
  void dispose() {
    logger.info("Disposing ManualControlScreen - Disconnecting MQTT");
    _disconnectMqtt();
    _reconnectTimer?.cancel();
    super.dispose();
  }

  void _setupLogging() {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint(
        '${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}',
      );
    });
  }

  Future<void> _connectMqtt() async {
    if (client != null &&
        client?.connectionStatus?.state == MqttConnectionState.connected) {
      logger.info("MQTT Client already connected.");
      return;
    }

    client = MqttServerClient(_mqttBroker, _clientId);
    client!.port = _mqttPort;
    client!.keepAlivePeriod = 60;
    client!.logging(on: false);
    client!.onConnected = _onMqttConnected;
    client!.onDisconnected = _onMqttDisconnected;
    client!.onSubscribed = _onMqttSubscribed;
    client!.pongCallback = _pong;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    client!.connectionMessage = connMessage;

    try {
      logger.info('MQTT: Attempting connection to $_mqttBroker...');
      await client!.connect();
    } catch (e) {
      logger.severe('MQTT: Connection exception: $e');
      _handleDisconnect();
    }
  }

  void _disconnectMqtt() {
    logger.info("MQTT: Explicitly disconnecting...");
    client?.disconnect();
    _mqttSubscription?.cancel();
    _mqttSubscription = null;
  }

  void _onMqttConnected() {
    logger.info('MQTT: Connected successfully.');
    if (mounted) {
      setState(() {
        _isMqttConnected = true;
      });
    }
    logger.info('MQTT: Subscribing to response topic: $_responseTopic');
    client?.subscribe(_responseTopic, MqttQos.atLeastOnce);
    _listenToMqttMessages();
  }

  void _listenToMqttMessages() {
    _mqttSubscription?.cancel();
    _mqttSubscription = client?.updates?.listen((
      List<MqttReceivedMessage<MqttMessage>> c,
    ) {
      final recMess = c[0];
      if (recMess.payload is MqttPublishMessage) {
        final message = recMess.payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(
          message.payload.message,
        );
        logger.fine(
          'MQTT: Received message: topic is ${recMess.topic}, payload is $payload',
        );
        _processMqttData(payload);
      } else {
        logger.warning(
          'MQTT: Received non-publish message type on topic ${recMess.topic}',
        );
      }
    });
    logger.info("MQTT: Listening for updates started.");
  }

  void _onMqttDisconnected() {
    logger.warning('MQTT: Disconnected.');
    _handleDisconnect();
    _scheduleReconnect();
  }

  void _handleDisconnect() {
    if (mounted) {
      setState(() {
        _isMqttConnected = false;
      });
    }
    _mqttSubscription?.cancel();
    _mqttSubscription = null;
    client = null;
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (mounted) {
      logger.info("MQTT: Scheduling reconnect in 5 seconds...");
      _reconnectTimer = Timer(const Duration(seconds: 5), () {
        logger.info("MQTT: Attempting scheduled reconnect...");
        _connectMqtt();
      });
    } else {
      logger.info("MQTT: Widget not mounted, cancelling reconnect schedule.");
    }
  }

  void _onMqttSubscribed(String topic) {
    logger.info('MQTT: Subscribed to topic: $topic');
  }

  void _pong() {
    logger.fine('MQTT: Ping response received (pong)');
  }

  void _processMqttData(String payload) {
    logger.info('MQTT: Processing received data: $payload');
    try {
      final data = jsonDecode(payload);

      if (data['m2m:rsp'] != null) {
        final rsp = data['m2m:rsp'];
        final int statusCode = rsp['rsc'] ?? 0;
        final String? requestId = rsp['rqi'];

        logger.info(
          "MQTT: Received response with status $statusCode for request $requestId",
        );

        if (requestId == _lastRequestId) {
          setState(() {
            _waitingForConfirmation = false;
          });

          if (statusCode == 2000) {
            // Success status code for oneM2M
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Kontrol berhasil diperbarui'),
                  backgroundColor: Colors.green,
                ),
              );
            }
          } else {
            logger.warning(
              "MQTT: Received error response from Antares: $statusCode",
            );
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error dari server: $statusCode'),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          }
        }
      } else {
        logger.info("MQTT: Received data doesn't match known response format.");
      }
    } catch (e) {
      logger.severe('MQTT: Error processing MQTT data: $e\nPayload: $payload');
    }
  }

  Future<void> updateDeviceStatus() async {
    if (isSending) return;

    if (!_isMqttConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('MQTT Tidak Terhubung. Tidak dapat mengirim.'),
          backgroundColor: Colors.orange,
        ),
      );
      await _connectMqtt();
      if (!_isMqttConnected) {
        return;
      }
    }

    setState(() {
      isSending = true;
      _waitingForConfirmation = true;
      _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
    });

    try {
      // Create payload for Antares
      final contentPayload = {
        'Jumlah Orang Masuk': 0,
        'Jumlah Orang Keluar': 0,
        'manual_control': 1,
        'system_active': isSystemActive ? 1 : 0,
        'fan_status': fanStatus ? 1 : 0,
        'lamp_status': lampStatus ? 1 : 0,
        'ac_status': acStatus ? 1 : 0,
        'dispenser_status': dispenserStatus ? 1 : 0,
        'max_occupancy': 10,
      };

      final requestPayload = {
        "m2m:rqp": {
          "fr": _accessKey,
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName",
          "op": 1,
          "rqi": _lastRequestId,
          "pc": {
            "m2m:cin": {"cnf": "message", "con": jsonEncode(contentPayload)},
          },
          "ty": 4,
        },
      };

      final String finalPayloadString = jsonEncode(requestPayload);
      logger.info('MQTT: Publishing to topic: $_requestTopic');
      logger.fine('MQTT: Publishing payload: $finalPayloadString');

      final builder = MqttClientPayloadBuilder();
      builder.addString(finalPayloadString);

      client!.publishMessage(
        _requestTopic,
        MqttQos.atLeastOnce,
        builder.payload!,
        retain: false,
      );

      // Wait for confirmation
      await Future.delayed(const Duration(seconds: 5));

      if (_waitingForConfirmation && mounted) {
        logger.warning(
          'Did not receive confirmation for request $_lastRequestId',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tidak menerima konfirmasi dari perangkat'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      logger.severe('MQTT: Error publishing device status: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengirim via MQTT: $e'),
            backgroundColor: Colors.red,
          ),
        );

        // Fallback to HTTP if MQTT fails
        _fallbackToHttpUpdate();
      }
    } finally {
      if (mounted) {
        setState(() {
          isSending = false;
        });
      }
    }
  }

  Future<void> _fallbackToHttpUpdate() async {
    try {
      logger.info('Attempting HTTP fallback method');
      // Create payload for Antares
      final payload = {
        'fan_status': fanStatus,
        'lamp_status': lampStatus,
        'ac_status': acStatus,
        'dispenser_status': dispenserStatus,
        'system_active': isSystemActive,
        'manual_control': true, // Flag to indicate manual control
        'Jumlah Orang Masuk': 0,
        'Jumlah Orang Keluar': 0,
      };

      // Convert payload to JSON string
      final jsonPayload = jsonEncode({
        'm2m:cin': {'con': jsonEncode(payload)},
      });

      // Send POST request to Antares
      final response = await http
          .post(
            Uri.parse(
              'https://platform.antares.id:8443/~/antares-cse/antares-id/TA-YAZ/COUNTER',
            ),
            headers: {
              'X-M2M-Origin': 'b1e8024f40e20d77:9f09d4019f441404',
              'Content-Type': 'application/json;ty=4',
              'Accept': 'application/json',
            },
            body: jsonPayload,
          )
          .timeout(const Duration(seconds: 10));

      logger.info('HTTP Fallback response status code: ${response.statusCode}');
      logger.info('HTTP Fallback response body: ${response.body}');

      if (response.statusCode == 201) {
        logger.info('Device status updated successfully via HTTP');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kontrol berhasil diperbarui (via HTTP)'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        logger.severe(
          'Failed to update device status via HTTP: ${response.statusCode}',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Gagal memperbarui kontrol perangkat'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      logger.severe('Error updating device status via HTTP: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Terjadi kesalahan saat memperbarui status perangkat'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget buildControlRow(String title, bool value, Function(bool) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
          Switch(value: value, onChanged: onChanged, activeColor: Colors.blue),
        ],
      ),
    );
  }

  Widget buildDeviceControlSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kontrol Perangkat',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            buildControlRow('Kipas', fanStatus, (value) {
              setState(() {
                fanStatus = value;
              });
            }),
            const Divider(),
            buildControlRow('Lampu', lampStatus, (value) {
              setState(() {
                lampStatus = value;
              });
            }),
            const Divider(),
            buildControlRow('AC', acStatus, (value) {
              setState(() {
                acStatus = value;
              });
            }),
            const Divider(),
            buildControlRow('Dispenser', dispenserStatus, (value) {
              setState(() {
                dispenserStatus = value;
              });
            }),
          ],
        ),
      ),
    );
  }

  Widget buildSystemControlSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kontrol Sistem',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Aktifkan Sistem',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                ),
                Switch(
                  value: isSystemActive,
                  onChanged: (value) {
                    setState(() {
                      isSystemActive = value;
                      // If system is being turned off, turn off all devices
                      if (!value) {
                        fanStatus = false;
                        lampStatus = false;
                        acStatus = false;
                        dispenserStatus = false;
                      }
                    });
                  },
                  activeColor: Colors.green,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isSystemActive
                  ? 'Sistem aktif - kontrol manual dapat digunakan'
                  : 'Sistem nonaktif - semua perangkat akan dimatikan',
              style: TextStyle(
                fontSize: 14,
                color: isSystemActive ? Colors.green[700] : Colors.red[700],
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Kontrol Manual'),
            const Spacer(),
            Icon(
              Icons.circle,
              color: _isMqttConnected ? Colors.greenAccent : Colors.redAccent,
              size: 12,
            ),
            const SizedBox(width: 4),
            Text(
              _isMqttConnected ? 'Online' : 'Offline',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () {
              showDialog(
                context: context,
                builder:
                    (context) => AlertDialog(
                      title: const Text('Bantuan Kontrol Manual'),
                      content: const SingleChildScrollView(
                        child: ListBody(
                          children: [
                            Text(
                              'Pada halaman ini Anda dapat mengendalikan perangkat secara manual "DILUAR JAM KERJA":',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 12),
                            Text(
                              '1. Aktifkan "Sistem" untuk menggunakan kontrol manual',
                            ),
                            Text(
                              '2. Gunakan tombol untuk menyalakan/mematikan setiap perangkat',
                            ),
                            Text(
                              '3. Tekan "Terapkan Perubahan" untuk mengirimkan perintah',
                            ),
                            SizedBox(height: 12),
                            Text(
                              'Catatan: Pengaturan ini akan menggantikan sistem otomatis sampai Anda menonaktifkan "Sistem".',
                              style: TextStyle(fontStyle: FontStyle.italic),
                            ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Mengerti'),
                        ),
                      ],
                    ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              buildSystemControlSection(),
              const SizedBox(height: 16),
              buildDeviceControlSection(),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed:
                    isSystemActive
                        ? (isSending ? null : updateDeviceStatus)
                        : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: _isMqttConnected ? Colors.blue : Colors.grey,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child:
                    isSending
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : const Text(
                          'Terapkan Perubahan',
                          style: TextStyle(fontSize: 16),
                        ),
              ),
              const SizedBox(height: 16),
              Card(
                color: Colors.amber[50],
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.amber[800]),
                          const SizedBox(width: 8),
                          const Text(
                            'Informasi Penting',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Pengaturan manual akan menggantikan sistem otomatis. Untuk kembali ke mode otomatis, nonaktifkan sistem di halaman ini.',
                        style: TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
