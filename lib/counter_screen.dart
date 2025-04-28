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
    // convertToBool(json['system_active']),
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
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          now = DateTime.now();
        });
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
        title: const Text('Kontrol Ruangan Otomatis'),
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

class ManualControlScreen extends StatelessWidget {
  const ManualControlScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kontrol Manual')),
      body: const Center(child: Text('Halaman Kontrol Manual')),
    );
  }
}
