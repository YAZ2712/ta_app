import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

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
