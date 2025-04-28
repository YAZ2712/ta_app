import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({super.key});

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class AntaresMqttService {
  final String accessKey = 'b1e8024f40e20d77:9f09d4019f441404';
  final String projectName = 'TA-YAZ';
  final String deviceName = 'COUNTER';
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
      // Jika data langsung dikirim sebagai JSON root
      else if (data['voltage'] != null || data['power'] != null) {
        contentData = data;
      }

      if (contentData != null) {
        onDataReceived(contentData);
      }
    } catch (e) {
      logger.severe('Error processing MQTT data: $e');
    }
  }

  void disconnect() {
    client.disconnect();
  }
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  final logger = Logger('MonitoringScreenState');
  DateTime now = DateTime.now();
  bool isLoading = false;
  bool _isConnectedToAntares = false;
  bool _isDisposed = false;
  Timer? _timer;
  Timer? _httpPollingTimer;
  late AntaresMqttService _antaresService;

  // Monitoring data that matches the exact JSON structure from Antares
  double voltage = 0.0;
  double current = 0.0;
  double power = 0.0;
  double energy = 0.0;
  double totalEnergy = 0.0;
  double dailyEnergy = 0.0;
  double energyLimit = 5.0; // Default limit
  double limit90 = 4.5;
  double limit80 = 4.0;
  double co2Emission = 0.0; // Calculated based on energy consumption
  double cost = 0.0; // Calculated based on energy consumption

  // Constants for calculation
  final double co2Factor = 0.79; // kg CO2 per kWh
  final double costPerKwh = 1444.7; // Rp per kWh

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
    _httpPollingTimer?.cancel();
    _httpPollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) {
        fetchDataFromAntares();
      }
    });
    logger.info('HTTP polling timer set up to fetch data every 5 seconds');
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

  @override
  void dispose() {
    _isDisposed = true;
    _timer?.cancel();
    _httpPollingTimer?.cancel();
    _antaresService.disconnect();
    super.dispose();
  }

  void updateDataFromMqtt(Map<String, dynamic> data) {
    if (!mounted) return;

    logger.info('Updating UI with MQTT data: $data');
    setState(() {
      // Match exact field names from the JSON
      if (data['Voltage'] != null) {
        voltage = double.tryParse(data['Voltage'].toString()) ?? voltage;
      }
      if (data['Current'] != null) {
        current = double.tryParse(data['Current'].toString()) ?? current;
      }
      if (data['Power'] != null) {
        power = double.tryParse(data['Power'].toString()) ?? power;
      }
      if (data['Energy'] != null) {
        energy = double.tryParse(data['Energy'].toString()) ?? energy;
      }
      if (data['TotalEnergy'] != null) {
        totalEnergy =
            double.tryParse(data['TotalEnergy'].toString()) ?? totalEnergy;
      }
      if (data['DailyEnergy'] != null) {
        dailyEnergy =
            double.tryParse(data['DailyEnergy'].toString()) ?? dailyEnergy;
      }
      if (data['energyLimit2'] != null) {
        energyLimit =
            double.tryParse(data['energyLimit2'].toString()) ?? energyLimit;
      }
      if (data['limit90'] != null) {
        limit90 = double.tryParse(data['limit90'].toString()) ?? limit90;
      }
      if (data['limit80'] != null) {
        limit80 = double.tryParse(data['limit80'].toString()) ?? limit80;

        // Calculate CO2 and cost based on energy consumption
        co2Emission = totalEnergy * co2Factor;
        cost = totalEnergy * costPerKwh;
      }
    });
  }

  Future<void> fetchDataFromAntares() async {
    if (isLoading || !mounted) return;

    setState(() => isLoading = true);
    try {
      final response = await http
          .get(
            Uri.parse(
              'https://platform.antares.id:8443/~/antares-cse/antares-id/TA-YAZ/COUNTER/la',
            ),
            headers: {
              'X-M2M-Origin': 'b1e8024f40e20d77:9f09d4019f441404',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        logger.info('Successfully fetched data from Antares');
        final data = jsonDecode(response.body);
        if (data['m2m:cin']?['con'] != null) {
          // Handle different possible formats of 'con'
          dynamic conData = data['m2m:cin']['con'];
          Map<String, dynamic> deviceData;

          if (conData is String) {
            // If con is a JSON string, parse it
            try {
              deviceData = jsonDecode(conData);
              logger.info('Parsed JSON data from con string: $deviceData');
            } catch (e) {
              logger.warning('Failed to parse con as JSON: $e');
              deviceData = {'con': conData};
            }
          } else if (conData is Map) {
            // If con is already a Map
            deviceData = Map<String, dynamic>.from(conData);
            logger.info('Con is already a Map: $deviceData');
          } else {
            logger.warning('Unexpected con format: ${conData.runtimeType}');
            deviceData = {};
          }

          setState(() {
            // Match exact field names from the JSON in Image 1
            if (deviceData['Voltage'] != null) {
              voltage =
                  double.tryParse(deviceData['Voltage'].toString()) ?? voltage;
            }
            if (deviceData['Current'] != null) {
              current =
                  double.tryParse(deviceData['Current'].toString()) ?? current;
            }
            if (deviceData['Power'] != null) {
              power = double.tryParse(deviceData['Power'].toString()) ?? power;
            }
            if (deviceData['Energy'] != null) {
              energy =
                  double.tryParse(deviceData['Energy'].toString()) ?? energy;
            }
            if (deviceData['TotalEnergy'] != null) {
              totalEnergy =
                  double.tryParse(deviceData['TotalEnergy'].toString()) ??
                  totalEnergy;
            }
            if (deviceData['DailyEnergy'] != null) {
              dailyEnergy =
                  double.tryParse(deviceData['DailyEnergy'].toString()) ??
                  dailyEnergy;
            }
            if (deviceData['energyLimit2'] != null) {
              energyLimit =
                  double.tryParse(deviceData['energyLimit2'].toString()) ??
                  energyLimit;
            }
            if (deviceData['limit90'] != null) {
              limit90 =
                  double.tryParse(deviceData['limit90'].toString()) ?? limit90;
            }
            if (deviceData['limit80'] != null) {
              limit80 =
                  double.tryParse(deviceData['limit80'].toString()) ?? limit80;

              // Calculate CO2 and cost based on energy consumption
              co2Emission = totalEnergy * co2Factor;
              cost = totalEnergy * costPerKwh;
            }
          });
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

  Widget buildInfoCard({
    required IconData icon,
    required String title,
    required String value,
    required String unit,
    Color? iconColor,
    Color? backgroundColor,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: (iconColor ?? Colors.blue).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor ?? Colors.blue, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[600],
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        value,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        unit,
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildPowerDetails() {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'DETAIL DAYA',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    Text(
                      'TEGANGAN',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    Row(
                      children: [
                        Text(
                          voltage.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(' V'),
                      ],
                    ),
                  ],
                ),
                Column(
                  children: [
                    Text(
                      'ARUS',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    Row(
                      children: [
                        Text(
                          current.toStringAsFixed(2),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(' A'),
                      ],
                    ),
                  ],
                ),
                Column(
                  children: [
                    Text(
                      'DAYA',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    Row(
                      children: [
                        Text(
                          power.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(' W'),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        'ENERGI',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            energy.toStringAsFixed(1),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Text(' kWh'),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
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
          size: 20,
        ),
        const SizedBox(width: 4),
        Text(
          _isConnectedToAntares ? 'Terhubung' : 'Tidak terhubung',
          style: TextStyle(
            color: _isConnectedToAntares ? Colors.green : Colors.red,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MONITORING'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          buildConnectionStatusIndicator(),
          const SizedBox(width: 8),
          IconButton(
            icon:
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
              // Progress indicator card
              Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'TASKBAR',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.amber[800],
                            ),
                          ),
                          Text(
                            DateFormat('HH:mm:ss').format(now),
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'BATAS PENGGUNAAN: $energyLimit kWh',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value:
                            energyLimit > 0
                                ? (dailyEnergy / energyLimit).clamp(0.0, 1.0)
                                : 0,
                        backgroundColor: Colors.grey[200],
                        color:
                            dailyEnergy >= energyLimit
                                ? Colors.red
                                : Colors.amber[700],
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '0 kWh',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                          Text(
                            '$energyLimit kWh',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),
              buildPowerDetails(),
              const SizedBox(height: 16),

              buildInfoCard(
                icon: Icons.bolt,
                title: 'TOTAL ENERGI / HARI',
                value: dailyEnergy.toStringAsFixed(1),
                unit: 'kWh',
                iconColor: Colors.amber[700],
              ),
              const SizedBox(height: 12),

              buildInfoCard(
                icon: Icons.watch_later_outlined,
                title: 'TOTAL ENERGI',
                value: totalEnergy.toStringAsFixed(1),
                unit: 'kWh',
                iconColor: Colors.blue[700],
              ),
              const SizedBox(height: 12),

              buildInfoCard(
                icon: Icons.cloud_outlined,
                title: 'TOTAL CO₂',
                value: co2Emission.toStringAsFixed(1),
                unit: 'kg',
                iconColor: Colors.green[700],
              ),
              const SizedBox(height: 12),

              buildInfoCard(
                icon: Icons.attach_money,
                title: 'TOTAL BIAYA',
                value: NumberFormat.currency(
                  locale: 'id',
                  symbol: 'Rp',
                  decimalDigits: 0,
                ).format(cost),
                unit: '',
                iconColor: Colors.purple[700],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
