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
    return DeviceStatus(
      fan: systemActive ? convertToBool(json['fan_status']) : false,
      lamp: systemActive ? convertToBool(json['lamp_status']) : false,
      ac: systemActive ? convertToBool(json['ac_status']) : false,
      dispenser: systemActive ? convertToBool(json['dispenser_status']) : false,
      systemActive: systemActive,
      maxOccupancy: json['max_occupancy'] is int ? json['max_occupancy'] : 10,
    );
  }

  // Tambahkan method untuk membandingkan DeviceStatus
  bool isEqual(DeviceStatus other) {
    return fan == other.fan &&
        lamp == other.lamp &&
        ac == other.ac &&
        dispenser == other.dispenser &&
        systemActive == other.systemActive &&
        maxOccupancy == other.maxOccupancy;
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
      maxOccupancy.hashCode;
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

  // Tambahkan variabel untuk menyimpan data sebelumnya
  int _previousPeopleIn = -1;
  int _previousPeopleOut = -1;
  DeviceStatus? _previousDeviceStatus;

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
  void updateDataFromMqtt(Map<String, dynamic> data) {
    if (!mounted) return;

    // Check if this data contains counter-relevant information
    if (!_isCounterRelevantData(data)) {
      logger.info('Received non-counter data (power monitoring), ignoring...');
      return;
    }

    // Ambil data baru
    int newPeopleIn = data['Jumlah Orang Masuk'] ?? peopleIn;
    int newPeopleOut = data['Jumlah Orang Keluar'] ?? peopleOut;

    // Create new device status
    DeviceStatus newDeviceStatus;
    try {
      newDeviceStatus = DeviceStatus.fromJson(data);
    } catch (e) {
      logger.warning('Failed to parse device status from MQTT data: $e');
      return;
    }

    // Cek apakah ada perubahan data
    bool hasChanges = false;

    if (newPeopleIn != _previousPeopleIn ||
        newPeopleOut != _previousPeopleOut ||
        _previousDeviceStatus == null ||
        !newDeviceStatus.isEqual(_previousDeviceStatus!)) {
      hasChanges = true;
      logger.info(
        'MQTT Counter Data changed - PeopleIn: $newPeopleIn, PeopleOut: $newPeopleOut',
      );
    }

    // Hanya update UI jika ada perubahan
    if (hasChanges && mounted && !_isDisposed) {
      setState(() {
        peopleIn = newPeopleIn;
        peopleOut = newPeopleOut;
        _deviceStatus = newDeviceStatus;
      });

      // Update data sebelumnya
      _previousPeopleIn = newPeopleIn;
      _previousPeopleOut = newPeopleOut;
      _previousDeviceStatus = newDeviceStatus;
    } else if (!hasChanges) {
      logger.info('MQTT Counter Data unchanged - skipping UI update');
    }
  }

  // Add this helper method to check if data is relevant for counter
  bool _isCounterRelevantData(Map<String, dynamic> data) {
    // Check if data contains counter-specific fields
    final counterFields = [
      'Jumlah Orang Masuk',
      'Jumlah Orang Keluar',
      'system_active',
      'fan_status',
      'lamp_status',
      'ac_status',
      'dispenser_status',
      'manual_control',
      'max_occupancy',
    ];

    // Check if any counter-relevant field exists in the data
    for (String field in counterFields) {
      if (data.containsKey(field)) {
        return true;
      }
    }

    // If no counter fields found, this is probably power monitoring data
    return false;
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
              // Check if this is counter-relevant data
              if (!_isCounterRelevantData(deviceData)) {
                logger.info(
                  'HTTP response contains non-counter data, ignoring...',
                );
                return;
              }

              // Ambil data baru
              int newPeopleIn = deviceData['Jumlah Orang Masuk'] ?? 0;
              int newPeopleOut = deviceData['Jumlah Orang Keluar'] ?? 0;
              DeviceStatus newDeviceStatus = DeviceStatus.fromJson(deviceData);

              // Cek apakah ada perubahan
              bool hasChanges = false;

              if (newPeopleIn != _previousPeopleIn ||
                  newPeopleOut != _previousPeopleOut ||
                  _previousDeviceStatus == null ||
                  !newDeviceStatus.isEqual(_previousDeviceStatus!)) {
                hasChanges = true;
                logger.info(
                  'HTTP Counter Data changed - PeopleIn: $newPeopleIn, PeopleOut: $newPeopleOut',
                );
              }

              // Hanya update UI jika ada perubahan
              if (hasChanges) {
                setState(() {
                  peopleIn = newPeopleIn;
                  peopleOut = newPeopleOut;
                  _deviceStatus = newDeviceStatus;

                  final bool isWeekendDay = isWeekend(now);
                  final bool isHolidayDay = isHoliday(now);
                  if (isWeekendDay || isHolidayDay) {
                    _hasInitialDataOnHoliday = true;
                  }
                });

                // Update data sebelumnya
                _previousPeopleIn = newPeopleIn;
                _previousPeopleOut = newPeopleOut;
                _previousDeviceStatus = newDeviceStatus;
              } else {
                logger.info('HTTP Counter Data unchanged - skipping UI update');
              }
            }
          }
        } else {
          logger.severe('Failed to fetch data: ${response.statusCode}');
          if (!isWeekend(now) && !isHoliday(now)) {
            await Future.delayed(const Duration(seconds: 5));
            fetchDataFromAntares();
          }
        }
      } catch (e) {
        logger.severe('Fetch error: $e');
        if (!isWeekend(now) && !isHoliday(now)) {
          await Future.delayed(const Duration(seconds: 5));
          fetchDataFromAntares();
        }
      } finally {
        if (mounted) setState(() => isLoading = false);
      }
    }
  }

  void checkWorkingHours() {
    final currentHour = now.hour;
    final bool isWeekendDay = isWeekend(now);
    final bool isHolidayDay = isHoliday(now);

    final bool isCurrentlyWorkingHours =
        !isWeekendDay && !isHolidayDay && currentHour >= 9 && currentHour < 16;

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
