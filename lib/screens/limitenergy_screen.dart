import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  bool _isDisposed = false;
  bool _isLoading = false;
  bool _isMqttConnected = false;
  bool _waitingForConfirmation = false;
  String? _lastRequestId;

  // Local storage for current limits
  double _currentStoredLimit = 0;
  double _currentLimit90 = 0;
  double _currentLimit80 = 0;

  // SharedPreferences keys
  static const String _keyEnergyLimit2 = 'energy_limit';
  static const String _keyLimit90 = 'energy_limit_90';
  static const String _keyLimit80 = 'energy_limit_80';

  // MQTT Configuration
  MqttServerClient? client;
  final String _mqttBroker = 'mqtt.antares.id';
  final int _mqttPort = 1883;
  final String _accessKey = 'fe5c7a15d8c13220:bfd764392a99a094';
  final String _projectName = 'TADKT-1';
  final String _deviceName = 'PMM';
  final String _clientId =
      'dart_client_${DateTime.now().millisecondsSinceEpoch}';
  final String _responseTopic =
      '/oneM2M/resp/fe5c7a15d8c13220:bfd764392a99a094/antares-cse/json';
  final String _requestTopic =
      '/oneM2M/req/fe5c7a15d8c13220:bfd764392a99a094/antares-cse/json';
  StreamSubscription? _mqttSubscription;

  @override
  void initState() {
    super.initState();
    _loadSavedLimits();
    _setupLogging();
    _connectMqtt();
  }

  @override
  void dispose() {
    _isDisposed = true;
    logger.info("Disposing LimitenergyScreen - Disconnecting MQTT");
    _disconnectMqtt();
    _limitController.dispose();
    _reconnectTimer?.cancel();
    super.dispose();
  }

  // Load saved limits from SharedPreferences
  Future<void> _loadSavedLimits() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load saved values or use widget defaults
      _currentStoredLimit =
          prefs.getDouble(_keyEnergyLimit2) ?? widget.currentLimit;
      _currentLimit90 = prefs.getDouble(_keyLimit90) ?? widget.limit90;
      _currentLimit80 = prefs.getDouble(_keyLimit80) ?? widget.limit80;

      // Set the text controller
      _limitController.text = _currentStoredLimit.toStringAsFixed(2);

      // Update UI
      if (mounted) {
        setState(() {});
      }

      logger.info(
        'Loaded saved limits: Current=$_currentStoredLimit, 90%=$_currentLimit90, 80%=$_currentLimit80',
      );
    } catch (e) {
      logger.severe('Error loading saved limits: $e');
      // Fallback to widget values
      _currentStoredLimit = widget.currentLimit;
      _currentLimit90 = widget.limit90;
      _currentLimit80 = widget.limit80;
      _limitController.text = _currentStoredLimit.toStringAsFixed(2);
    }
  }

  // Save limits to SharedPreferences
  Future<void> _saveLimits(double newLimit) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Calculate new warning limits (90% and 80% of the new limit)
      final new90Limit = newLimit * 0.9;
      final new80Limit = newLimit * 0.8;

      // Save to SharedPreferences
      await prefs.setDouble(_keyEnergyLimit2, newLimit);
      await prefs.setDouble(_keyLimit90, new90Limit);
      await prefs.setDouble(_keyLimit80, new80Limit);

      // Update local variables
      _currentStoredLimit = newLimit;
      _currentLimit90 = new90Limit;
      _currentLimit80 = new80Limit;

      logger.info(
        'Saved new limits: Current=$newLimit, 90%=$new90Limit, 80%=$new80Limit',
      );
    } catch (e) {
      logger.severe('Error saving limits: $e');
      rethrow;
    }
  }

  // Clear saved limits (for testing or reset purposes)
  Future<void> _clearSavedLimits() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyEnergyLimit2);
      await prefs.remove(_keyLimit90);
      await prefs.remove(_keyLimit80);

      // Reset to widget defaults
      _currentStoredLimit = widget.currentLimit;
      _currentLimit90 = widget.limit90;
      _currentLimit80 = widget.limit80;
      _limitController.text = _currentStoredLimit.toStringAsFixed(2);

      if (mounted) {
        setState(() {});
      }

      logger.info('Cleared saved limits');
    } catch (e) {
      logger.severe('Error clearing saved limits: $e');
    }
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
    if (mounted && !_isDisposed) {
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
    if (mounted && !_isDisposed) {
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
          if (mounted && !_isDisposed) {
            setState(() {
              _waitingForConfirmation = false;
            });
          }

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

    if (mounted && !_isDisposed) {
      setState(() {
        _isLoading = true;
        _waitingForConfirmation = true;
        _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
      });
    }

    try {
      // Save to local storage first
      await _saveLimits(newLimit);

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

      // Update UI immediately after saving locally
      if (mounted && !_isDisposed) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Batas energy berhasil disimpan'),
            backgroundColor: Colors.green,
          ),
        );
      }

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
            content: Text('Gagal menyimpan batas energy: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted && !_isDisposed) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _sendResetEspCommand() async {
    if (!_isMqttConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Koneksi Gagal. Tidak dapat mengirim perintah restart.',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      final contentPayload = {"source": "flutter_app", "reset_command": 1};
      final requestId = 'reset_${DateTime.now().millisecondsSinceEpoch}';

      final mqttPayload = {
        "m2m:rqp": {
          "fr": _accessKey,
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName/la",
          "op": 1,
          "rqi": requestId,
          "pc": {
            "m2m:cin": {"cnf": "message", "con": jsonEncode(contentPayload)},
          },
          "ty": 4,
        },
      };

      final builder = MqttClientPayloadBuilder();
      builder.addString(jsonEncode(mqttPayload));

      client?.publishMessage(
        _requestTopic,
        MqttQos.atLeastOnce,
        builder.payload!,
      );

      logger.info('Perintah restart ESP berhasil dikirim.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Perintah restart ESP berhasil dikirim ke perangkat.',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e, s) {
      logger.severe('Gagal mengirim perintah restart ESP: $e\n$s');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengirim perintah restart: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // --- TAMBAHAN: Dialog konfirmasi sebelum reset ---
  void _showResetConfirmationDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Konfirmasi Restart Perangkat'),
          content: const Text(
            'Apakah Anda yakin ingin merestart perangkat ESP? Tindakan ini akan memulai ulang perangkat.',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Batal'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Ya, Restart'),
              onPressed: () {
                Navigator.of(context).pop();
                _sendResetEspCommand();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Atur Limit Energy'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          // Connection Status Indicator - Improved design
          Container(
            margin: const EdgeInsets.only(right: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: _isMqttConnected ? Colors.green : Colors.red,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isMqttConnected ? Icons.wifi : Icons.wifi_off,
                  color: _isMqttConnected ? Colors.white : Colors.red,
                  size: 16,
                ),
                const SizedBox(width: 4),
                Text(
                  _isMqttConnected ? 'Online' : 'Offline',
                  style: TextStyle(
                    fontSize: 12,
                    color: _isMqttConnected ? Colors.white : Colors.red,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          // Debug reset button (remove in production)
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'reset') {
                await _clearSavedLimits();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Data batas telah direset'),
                      backgroundColor: Colors.blue,
                    ),
                  );
                }
              }
            },
            itemBuilder:
                (context) => [
                  const PopupMenuItem(
                    value: 'reset',
                    child: Row(
                      children: [
                        Icon(Icons.refresh, size: 20),
                        SizedBox(width: 8),
                        Text('Reset Data'),
                      ],
                    ),
                  ),
                ],
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.indigo, Colors.white],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Main Energy Limit Card
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        colors: [Colors.indigo.shade50, Colors.white],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.electric_bolt,
                              color: Colors.indigo,
                              size: 24,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'BATAS PENGGUNAAN LISTRIK',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.indigo,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.indigo,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: Colors.white,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Batas saat ini: ${_currentStoredLimit.toStringAsFixed(2)} kWh',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _limitController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Batas Baru',
                            hintText: 'Masukkan batas (kWh)',
                            suffixText: 'kWh',
                            suffixIcon: const Icon(Icons.electric_meter),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                color: Colors.indigo,
                                width: 2,
                              ),
                            ),
                            filled: true,
                            fillColor: Colors.grey[50],
                          ),
                        ),
                        const SizedBox(height: 20),
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
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 2,
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
                                    : const Text(
                                      'SIMPAN',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Information Card
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        colors: [Colors.orange.shade50, Colors.white],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.info, color: Colors.orange, size: 24),
                            const SizedBox(width: 8),
                            const Text(
                              'INFORMASI BATAS',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.orange,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _buildInfoTile(
                          icon: Icons.warning_amber,
                          iconColor: Colors.orange,
                          title: 'Batas Peringatan 90%',
                          value: '${_currentLimit90.toStringAsFixed(2)} kWh',
                        ),
                        const SizedBox(height: 12),
                        _buildInfoTile(
                          icon: Icons.info_outline,
                          iconColor: Colors.blue,
                          title: 'Batas Peringatan 80%',
                          value: '${_currentLimit80.toStringAsFixed(2)} kWh',
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Ketika penggunaan energi mencapai batas ini, sistem akan memberikan peringatan. Batas peringatan akan otomatis terhitung berdasarkan batas utama yang Anda tetapkan.',
                            style: TextStyle(fontSize: 13, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Restart Perangkat ESP'),
                    onPressed: _showResetConfirmationDialog,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      side: BorderSide(color: Colors.red.shade700, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.indigo,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
