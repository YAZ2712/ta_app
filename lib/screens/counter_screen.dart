import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'home_page_screen.dart';
import 'manual_control_screen.dart';

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
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomePageScreen(),
    );
  }
}

enum ControlMode { otomatis, manual }

class DeviceStatus {
  final bool fan;
  final bool lamp;
  final bool ac;
  final bool dispenser;
  final bool systemActive;
  // final int maxOccupancy;
  final ControlMode controlMode;

  DeviceStatus({
    required this.fan,
    required this.lamp,
    required this.ac,
    required this.dispenser,
    required this.systemActive,
    // this.maxOccupancy = 10,
    required this.controlMode,
  });

  // Diubah: Factory method sekarang menerima prefix (misal: '_l1' atau '_l2')
  factory DeviceStatus.fromJson(
    Map<String, dynamic> json, {
    String prefix = '',
  }) {
    // Helper function untuk konversi nilai apapun ke boolean
    bool convertToBool(dynamic value) {
      if (value is bool) return value;
      if (value is int) return value != 0;
      if (value is String) {
        return value.toLowerCase() == 'true' || value == '1';
      }
      return false;
    }

    // --- PERUBAHAN LOGIKA DIMULAI DI SINI ---
    // 1. Ambil nilai 'manual_control' dari JSON.
    //    Ini adalah kunci global, jadi tidak perlu prefix.
    // 2. Jika kunci tidak ada (null), kita anggap nilainya 0 (mode otomatis) sebagai default.
    final int manualControlValue = json['manual_control'] ?? 0;

    // 3. Tentukan ControlMode berdasarkan nilai tersebut.
    //    Jika manual_control adalah 1, set mode ke Manual. Jika tidak, Otomatis.
    final ControlMode mode =
        (manualControlValue == 1) ? ControlMode.manual : ControlMode.otomatis;
    // --- AKHIR PERUBAHAN LOGIKA ---

    // Gunakan prefix untuk mendapatkan kunci status perangkat per lantai
    final systemActive = convertToBool(json['system_active$prefix']);

    return DeviceStatus(
      // Status perangkat tetap bergantung pada systemActive per lantai
      fan: systemActive ? convertToBool(json['fan_status$prefix']) : false,
      lamp: systemActive ? convertToBool(json['lamp_status$prefix']) : false,
      ac: systemActive ? convertToBool(json['ac_status$prefix']) : false,
      dispenser:
          systemActive ? convertToBool(json['dispenser_status$prefix']) : false,
      systemActive: systemActive,
      // maxOccupancy: json['max_occupancy'] is int ? json['max_occupancy'] : 10,

      // Gunakan mode yang sudah kita tentukan dari 'manual_control'
      controlMode: mode,
    );
  }

  bool isEqual(DeviceStatus other) {
    return fan == other.fan &&
        lamp == other.lamp &&
        ac == other.ac &&
        dispenser == other.dispenser &&
        systemActive == other.systemActive &&
        // maxOccupancy == other.maxOccupancy &&
        controlMode == other.controlMode;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DeviceStatus && isEqual(other);

  @override
  int get hashCode =>
      fan.hashCode ^
      lamp.hashCode ^
      ac.hashCode ^
      dispenser.hashCode ^
      systemActive.hashCode ^
      // maxOccupancy.hashCode ^
      controlMode.hashCode;
}

final String accessKey = 'fe5c7a15d8c13220:bfd764392a99a094';
final String projectName = 'TADKT-1';
final String deviceName = 'PMM';

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
        '/oneM2M/resp/antares-cse/fe5c7a15d8c13220:bfd764392a99a094/json';

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

      if (data['m2m:rsp'] != null &&
          data['m2m:rsp']['m2m:cin'] != null &&
          data['m2m:rsp']['m2m:cin']['con'] != null) {
        final conData = data['m2m:rsp']['m2m:cin']['con'];
        if (conData is String) {
          contentData = jsonDecode(conData);
        } else {
          contentData = conData;
        }
      } else if (data['con'] != null) {
        final conData = data['con'];
        if (conData is String) {
          contentData = jsonDecode(conData);
        } else {
          contentData = conData;
        }
      } else if (data['Jumlah Orang Masuk'] != null) {
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

enum Floor { lantai1, lantai2 }

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
  bool _hasInitialDataOnHoliday = false;

  // --- PERUBAHAN STATE: Data untuk 2 Lantai ---
  int peopleInL1 = 0;
  int peopleOutL1 = 0;
  DeviceStatus _deviceStatusL1 = DeviceStatus(
    fan: false,
    lamp: false,
    ac: false,
    dispenser: false,
    systemActive: false,
    controlMode: ControlMode.otomatis,
  );

  int peopleInL2 = 0;
  int peopleOutL2 = 0;
  DeviceStatus _deviceStatusL2 = DeviceStatus(
    fan: false,
    lamp: false,
    ac: false,
    dispenser: false,
    systemActive: false,
    controlMode: ControlMode.otomatis,
  );

  // Variabel untuk menyimpan data sebelumnya
  int _previousPeopleInL1 = -1, _previousPeopleOutL1 = -1;
  int _previousPeopleInL2 = -1, _previousPeopleOutL2 = -1;
  DeviceStatus? _previousDeviceStatusL1, _previousDeviceStatusL2;

  // Variabel untuk UI selector
  Set<Floor> _selectedFloor = {Floor.lantai1};

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
        !isWeekendDay && !isHolidayDay && currentHour >= 9 && currentHour < 15;

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && !_isDisposed) {
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

  @override
  void dispose() {
    _isDisposed = true;
    _timer?.cancel();
    _httpPollingTimer?.cancel();
    _antaresService.disconnect();
    super.dispose();
  }

  void _setupHttpPollingTimer() {
    _httpPollingTimer?.cancel();

    final bool isWeekendDay = isWeekend(now);
    final bool isHolidayDay = isHoliday(now);
    final bool isNonWorkingDay = isWeekendDay || isHolidayDay;

    if (isNonWorkingDay) {
      if (!_hasInitialDataOnHoliday) {
        fetchDataFromAntares();
        _hasInitialDataOnHoliday = true;
      }
      logger.info('Hari libur/weekend: data hanya diambil sekali');
    } else {
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
        if (mounted && !_isDisposed) {
          setState(() {
            _isConnectedToAntares = isConnected;
          });
        }
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

  // Method untuk update data dengan pengecekan perubahan
  void _parseAndUpdateData(Map<String, dynamic> data) {
    if (!mounted) return;

    // Cek apakah data relevan (mencegah update dari data monitoring daya, dll)
    if (!_isCounterRelevantData(data)) {
      logger.info('Received non-counter data, ignoring...');
      return;
    }

    // Ambil data baru untuk Lantai 1
    int newPeopleInL1 = data['current_occupancy_l1'] ?? peopleInL1;
    int newPeopleOutL1 = data['total_people_exited_l1'] ?? peopleOutL1;
    DeviceStatus newDeviceStatusL1 = DeviceStatus.fromJson(data, prefix: '_l1');

    // Ambil data baru untuk Lantai 2
    int newPeopleInL2 = data['current_occupancy_l2'] ?? peopleInL2;
    int newPeopleOutL2 = data['total_people_exited_l2'] ?? peopleOutL2;
    DeviceStatus newDeviceStatusL2 = DeviceStatus.fromJson(data, prefix: '_l2');

    // Cek apakah ada perubahan data
    bool hasChanges = false;
    if (newPeopleInL1 != _previousPeopleInL1 ||
        newPeopleOutL1 != _previousPeopleOutL1 ||
        newPeopleInL2 != _previousPeopleInL2 ||
        newPeopleOutL2 != _previousPeopleOutL2 ||
        _previousDeviceStatusL1 == null ||
        !newDeviceStatusL1.isEqual(_previousDeviceStatusL1!) ||
        _previousDeviceStatusL2 == null ||
        !newDeviceStatusL2.isEqual(_previousDeviceStatusL2!)) {
      hasChanges = true;
      logger.info('Data changed. L1 In: $newPeopleInL1, L2 In: $newPeopleInL2');
    }

    // Hanya update UI jika ada perubahan
    if (hasChanges && mounted && !_isDisposed) {
      setState(() {
        // Update data state
        peopleInL1 = newPeopleInL1;
        peopleOutL1 = newPeopleOutL1;
        _deviceStatusL1 = newDeviceStatusL1;

        peopleInL2 = newPeopleInL2;
        peopleOutL2 = newPeopleOutL2;
        _deviceStatusL2 = newDeviceStatusL2;

        // Handle initial data on holiday
        final bool isWeekendDay = isWeekend(now);
        final bool isHolidayDay = isHoliday(now);
        if (isWeekendDay || isHolidayDay) {
          _hasInitialDataOnHoliday = true;
        }
      });

      // Update data sebelumnya untuk perbandingan berikutnya
      _previousPeopleInL1 = newPeopleInL1;
      _previousPeopleOutL1 = newPeopleOutL1;
      _previousDeviceStatusL1 = newDeviceStatusL1;

      _previousPeopleInL2 = newPeopleInL2;
      _previousPeopleOutL2 = newPeopleOutL2;
      _previousDeviceStatusL2 = newDeviceStatusL2;
    } else if (!hasChanges) {
      logger.info('Data unchanged - skipping UI update');
    }
  }

  void updateDataFromMqtt(Map<String, dynamic> data) {
    logger.info('Processing MQTT data');
    _parseAndUpdateData(data);
  }

  Future<void> fetchDataFromAntares() async {
    logger.info('Fetching data from HTTP at ${DateTime.now()}');
    if (isLoading || !mounted) return;

    if (mounted && !_isDisposed) {
      setState(() => isLoading = true);
      try {
        final response = await http
            .get(
              Uri.parse(
                'https://platform.antares.id:8443/~/antares-cse/antares-id/$projectName/$deviceName/la',
              ),
              headers: {
                'X-M2M-Origin': accessKey,
                'Accept': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['m2m:cin']?['con'] != null) {
            final deviceData = jsonDecode(data['m2m:cin']['con']);
            if (deviceData is Map<String, dynamic>) {
              logger.info('Processing HTTP data');
              _parseAndUpdateData(
                deviceData,
              ); // Gunakan fungsi parsing yang sudah dibuat
            }
          }
        } else {
          logger.severe('Failed to fetch data: ${response.statusCode}');
        }
      } catch (e) {
        logger.severe('Fetch error: $e');
      } finally {
        if (mounted) setState(() => isLoading = false);
      }
    }
  }

  // --- UPDATE: Helper method ini diubah untuk mencari kunci baru ---
  bool _isCounterRelevantData(Map<String, dynamic> data) {
    // Cukup cek salah satu kunci unik dari data baru, misal 'current_occupancy_l1'
    return data.containsKey('current_occupancy_l1') ||
        data.containsKey('source');
  }

  void checkWorkingHours() {
    final currentHour = now.hour;
    final bool isWeekendDay = isWeekend(now);
    final bool isHolidayDay = isHoliday(now);

    final bool isCurrentlyWorkingHours =
        !isWeekendDay && !isHolidayDay && currentHour >= 9 && currentHour < 15;

    if (isWorkingHours != isCurrentlyWorkingHours) {
      if (mounted && !_isDisposed) {
        setState(() {
          isWorkingHours = isCurrentlyWorkingHours;
        });
      }

      if (!isCurrentlyWorkingHours && isWorkingHours) {
        _hasInitialDataOnHoliday = false;
      }

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
    return days[weekday - 1];
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

  // --- PERUBAHAN: Widget Indikator Mode untuk AppBar ---
  Widget buildModeIndicator(ControlMode mode) {
    final bool isOtomatis = mode == ControlMode.otomatis;
    final IconData icon = isOtomatis ? Icons.auto_awesome : Icons.pan_tool;
    final String text =
        isOtomatis ? 'Mode Otomatis Aktif' : 'Mode Kontrol Manual Aktif';
    final Color color = isOtomatis ? Colors.green : Colors.orange;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.grey.shade300, // Warna latar yang lembut
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
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
    // Ambil data berdasarkan lantai yang dipilih
    final isLantai1 = _selectedFloor.first == Floor.lantai1;
    final DeviceStatus status = isLantai1 ? _deviceStatusL1 : _deviceStatusL2;

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
                buildStatusRow('Kipas', status.systemActive && status.fan),
                const Divider(),
                buildStatusRow('Lampu', status.systemActive && status.lamp),
                const Divider(),
                buildStatusRow('AC', status.systemActive && status.ac),
                const Divider(),
                buildStatusRow(
                  'Dispenser',
                  status.systemActive && status.dispenser,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildPeopleCounter() {
    // Ambil data berdasarkan lantai yang dipilih
    final isLantai1 = _selectedFloor.first == Floor.lantai1;
    final int peopleIn = isLantai1 ? peopleInL1 : peopleInL2;
    final int peopleOut = isLantai1 ? peopleOutL1 : peopleOutL2;
    // final DeviceStatus status = isLantai1 ? _deviceStatusL1 : _deviceStatusL2;

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
                  '$peopleIn',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // LinearProgressIndicator(
            //   value:
            //       peopleIn /
            //       // (status.maxOccupancy == 0 ? 1 : status.maxOccupancy),
            //   // backgroundColor: Colors.grey[200],
            //   // color: peopleIn >= status.maxOccupancy ? Colors.red : Colors.blue,
            // ),
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
    final isLantai1 = _selectedFloor.first == Floor.lantai1;
    final DeviceStatus status = isLantai1 ? _deviceStatusL1 : _deviceStatusL2;

    final bool isWeekendDay = isWeekend(now);
    final bool isHolidayDay = isHoliday(now);
    final bool isSystemReallyActive =
        !isWeekendDay && !isHolidayDay && status.systemActive && isWorkingHours;

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
                  : 'Jam Kerja: 09:00 - 15:00',
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
          Icons.circle,
          color: _isConnectedToAntares ? Colors.green : Colors.red,
          size: 12,
        ),
        const SizedBox(width: 4),
        Text(
          _isConnectedToAntares ? 'Online' : 'Offline',
          style: TextStyle(
            color: _isConnectedToAntares ? Colors.green : Colors.red,
          ),
        ),
      ],
    );
  }

  Widget buildConnectionStatusForAppBar() {
    return Padding(
      padding: const EdgeInsets.only(right: 16.0), // Beri jarak dari tepi kanan
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            color:
                _isConnectedToAntares ? Colors.greenAccent : Colors.redAccent,
            size: 12,
          ),
          const SizedBox(width: 6),
          Text(
            _isConnectedToAntares ? 'Online' : 'Offline',
            style: const TextStyle(
              color: Colors.white, // Agar kontras dengan AppBar
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ControlMode currentMode =
        (_selectedFloor.first == Floor.lantai1)
            ? _deviceStatusL1.controlMode
            : _deviceStatusL2.controlMode;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kontrol Otomatis'),
        // Menambahkan style agar sama dengan halaman lain
        backgroundColor: Colors.indigo.shade400,
        foregroundColor: Colors.grey.shade50,
        elevation: 0,
        actions: [buildConnectionStatusForAppBar()],
      ),
      // Menambahkan Container dengan LinearGradient sebagai background
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.indigo.shade400, Colors.grey.shade50],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              buildModeIndicator(currentMode),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${getIndonesianDay(now.weekday)}, ${now.day} ${getIndonesianMonth(now.month)} ${now.year}',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white, // Agar lebih kontras
                                ),
                              ),
                            ],
                          ),
                          Text(
                            DateFormat('HH:mm:ss').format(now),
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white, // Agar lebih kontras
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Center(
                        child: SegmentedButton<Floor>(
                          style: SegmentedButton.styleFrom(
                            backgroundColor: Colors.white.withOpacity(0.9),
                            foregroundColor: Colors.indigo,
                            selectedForegroundColor: Colors.white,
                            selectedBackgroundColor: Colors.indigo,
                          ),
                          segments: const <ButtonSegment<Floor>>[
                            ButtonSegment<Floor>(
                              value: Floor.lantai1,
                              label: Text('Lantai 1'),
                              icon: Icon(Icons.looks_one),
                            ),
                            ButtonSegment<Floor>(
                              value: Floor.lantai2,
                              label: Text('Lantai 2'),
                              icon: Icon(Icons.looks_two),
                            ),
                          ],
                          selected: _selectedFloor,
                          onSelectionChanged: (Set<Floor> newSelection) {
                            setState(() {
                              _selectedFloor = newSelection;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 20),
                      buildPeopleCounter(),
                      const SizedBox(height: 20),
                      buildDeviceStatus(),
                      const SizedBox(height: 20),
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 2, child: buildSystemStatusCard()),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 1,
                              child: buildManualControlButton(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
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
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
                : const Icon(Icons.refresh),
      ),
    );
  }
}
