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
      client.logging(on: true);

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

      // Calculate CO2 and cost based on energy consumption
      co2Emission = totalEnergy * co2Factor;
      cost = totalEnergy * costPerKwh;
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

            // Calculate CO2 and cost based on energy consumption
            co2Emission = totalEnergy * co2Factor;
            cost = totalEnergy * costPerKwh;
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
              // Time display card
              Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'WAKTU SEKARANG',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo[800],
                        ),
                      ),
                      Text(
                        DateFormat('HH:mm:ss').format(now),
                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),
              buildPowerDetails(),
              const SizedBox(height: 16),

              SizedBox(
                height: 70,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const LimitenergyScreen(),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Limit Energy',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ),
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

class LimitenergyScreen extends StatefulWidget {
  final double currentLimit;
  final double limit90;
  final double limit80;

  const LimitenergyScreen({
    super.key,
    this.currentLimit = 0,
    this.limit90 = 0,
    this.limit80 = 0,
  });

  @override
  State<LimitenergyScreen> createState() => _LimitenergyScreenState();
}

class _LimitenergyScreenState extends State<LimitenergyScreen> {
  final TextEditingController _limitController = TextEditingController();
  final logger = Logger('LimitenergyScreen');
  bool _isLoading = false;
  bool _isMqttConnected = false;
  bool _waitingForConfirmation = false;
  String? _lastRequestId;

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

  @override
  void initState() {
    super.initState();
    _limitController.text = widget.currentLimit.toStringAsFixed(2);
    _setupLogging();
    _connectMqtt();
  }

  @override
  void dispose() {
    logger.info("Disposing LimitenergyScreen - Disconnecting MQTT");
    _disconnectMqtt();
    _limitController.dispose();
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

  Timer? _reconnectTimer;
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
                  content: Text('Update berhasil diterima oleh server'),
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

  Future<void> _publishEnergyLimit() async {
    if (_limitController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Silakan masukkan nilai batas'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final newLimit = double.tryParse(_limitController.text);
    if (newLimit == null || newLimit <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Batas harus berupa angka positif'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (client == null ||
        client!.connectionStatus?.state != MqttConnectionState.connected) {
      logger.warning('MQTT: Client not connected. Cannot send.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('MQTT Tidak Terhubung. Tidak dapat mengirim.'),
          backgroundColor: Colors.orange,
        ),
      );
      await _connectMqtt();
      if (client == null ||
          client!.connectionStatus?.state != MqttConnectionState.connected) {
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _waitingForConfirmation = true;
      _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
    });

    try {
      final contentPayload = {"energyLimit2": newLimit};

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
      logger.severe('MQTT: Error publishing energy limit: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengirim via MQTT: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Atur Batas Penggunaan'),
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
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      const Text(
                        'BATAS PENGGUNAAN LISTRIK',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Batas saat ini: ${widget.currentLimit.toStringAsFixed(2)} kWh',
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _limitController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Batas Baru',
                          hintText: 'Masukkan batas (kWh)',
                          suffixText: 'kWh',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          filled: true,
                          fillColor: Colors.grey[100],
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              _isLoading || !_isMqttConnected
                                  ? null
                                  : _publishEnergyLimit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isMqttConnected
                                    ? Colors.amber[700]
                                    : Colors.grey,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child:
                              _isLoading
                                  ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : const Text('SIMPAN'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'INFORMASI BATAS',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        title: const Text('Batas Peringatan 90%'),
                        subtitle: Text(
                          '${widget.limit90.toStringAsFixed(2)} kWh',
                        ),
                        leading: const Icon(
                          Icons.warning_amber,
                          color: Colors.orange,
                        ),
                      ),
                      ListTile(
                        title: const Text('Batas Peringatan 80%'),
                        subtitle: Text(
                          '${widget.limit80.toStringAsFixed(2)} kWh',
                        ),
                        leading: const Icon(
                          Icons.info_outline,
                          color: Colors.blue,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Ketika penggunaan energi mencapai batas ini, sistem akan memberikan peringatan.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
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
