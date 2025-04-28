import 'dart:async'; // For Timer and async operations
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart'; // MQTT Client imports
import 'package:mqtt_client/mqtt_server_client.dart';

class LimitenergyScreen extends StatefulWidget {
  // Keep widget properties for initial values
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
  bool _isLoading = false; // Renamed to avoid conflict
  bool _isMqttConnected = false;

  // --- MQTT Client and Configuration Embedded Here ---
  MqttServerClient? client; // Make client nullable
  final String _mqttBroker = 'mqtt.antares.id';
  final int _mqttPort = 1883;
  final String _accessKey =
      'b1e8024f40e20d77:9f09d4019f441404'; // Your Antares Key
  final String _projectName = 'TA-YAZ'; // Your Antares Project
  final String _deviceName = 'COUNTER'; // Your Antares Device
  final String _clientId =
      'dart_client_${DateTime.now().millisecondsSinceEpoch}';
  final String _responseTopic =
      '/oneM2M/resp/b1e8024f40e20d77:9f09d4019f441404/antares-cse/json'; // Listen for responses
  final String _requestTopic =
      '/oneM2M/req/b1e8024f40e20d77:9f09d4019f441404/antares-cse/json'; // Send requests
  StreamSubscription? _mqttSubscription; // To manage the listener

  @override
  void initState() {
    super.initState();
    _limitController.text = widget.currentLimit.toStringAsFixed(2);
    _setupLogging(); // Optional: Setup logger if not done globally
    _connectMqtt(); // Initiate connection when the screen loads
  }

  @override
  void dispose() {
    logger.info("Disposing LimitenergyScreen - Disconnecting MQTT");
    _disconnectMqtt(); // Disconnect MQTT when the screen is removed
    _limitController.dispose();
    super.dispose();
  }

  // Optional: Setup logger level for debugging
  void _setupLogging() {
    // Logger.root.level = Level.ALL; // Or Level.INFO
    // Logger.root.onRecord.listen((record) {
    //   debugPrint('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    // });
  }

  // --- MQTT Connection Logic ---
  Future<void> _connectMqtt() async {
    if (client != null &&
        client?.connectionStatus?.state == MqttConnectionState.connected) {
      logger.info("MQTT Client already connected.");
      return;
    }

    client = MqttServerClient(_mqttBroker, _clientId);
    client!.port = _mqttPort;
    client!.keepAlivePeriod = 60;
    client!.logging(
      on: false,
    ); // Disable default client logging if using Flutter logger
    client!.onConnected = _onMqttConnected;
    client!.onDisconnected = _onMqttDisconnected;
    client!.onSubscribed = _onMqttSubscribed;
    client!.pongCallback = _pong; // Optional: Handle ping responses

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .startClean() // Clean session for commands is usually good
        .withWillQos(MqttQos.atLeastOnce);
    client!.connectionMessage = connMessage;

    try {
      logger.info('MQTT: Attempting connection to $_mqttBroker...');
      // Use Access Key as username, password can often be empty for Antares key-based auth
      await client!.connect();
    } catch (e) {
      logger.severe('MQTT: Connection exception: $e');
      _handleDisconnect(); // Handle cleanup and potentially schedule reconnect
    }
  }

  void _disconnectMqtt() {
    logger.info("MQTT: Explicitly disconnecting...");
    client?.disconnect();
    _mqttSubscription?.cancel(); // Cancel the listener
    _mqttSubscription = null;
    // Don't call _onMqttDisconnected here, let the client trigger it
  }

  void _onMqttConnected() {
    logger.info('MQTT: Connected successfully.');
    if (mounted) {
      // Ensure widget is still in tree
      setState(() {
        _isMqttConnected = true;
      });
    }
    // Subscribe to the response topic
    logger.info('MQTT: Subscribing to response topic: $_responseTopic');
    client?.subscribe(_responseTopic, MqttQos.atLeastOnce);

    // Start listening to MQTT messages
    _listenToMqttMessages();
  }

  void _listenToMqttMessages() {
    _mqttSubscription?.cancel(); // Cancel previous subscription if any
    _mqttSubscription = client?.updates?.listen((
      List<MqttReceivedMessage<MqttMessage>> c,
    ) {
      final MqttReceivedMessage<MqttMessage> recMess = c[0];

      // Ensure payload is MqttPublishMessage before proceeding
      if (recMess.payload is MqttPublishMessage) {
        final MqttPublishMessage message =
            recMess.payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(
          message.payload.message,
        );
        logger.fine(
          'MQTT: Received message: topic is ${recMess.topic}, payload is $payload',
        );
        _processMqttData(payload); // Process the received data
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
    // Optional: Implement automatic reconnection logic here if desired
    // Be careful with infinite loops on persistent failures
    _scheduleReconnect();
  }

  void _handleDisconnect() {
    if (mounted) {
      setState(() {
        _isMqttConnected = false;
      });
    }
    _mqttSubscription?.cancel(); // Ensure listener is stopped
    _mqttSubscription = null;
    client = null; // Clear the client instance
  }

  Timer? _reconnectTimer;
  void _scheduleReconnect() {
    _reconnectTimer?.cancel(); // Cancel any existing timer
    // Only try to reconnect if the widget is still mounted
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

  // --- Process Incoming MQTT Data ---
  void _processMqttData(String payload) {
    // This function handles data RECEIVED from Antares via MQTT.
    // You might receive confirmations or other data updates here.
    logger.info('MQTT: Processing received data: $payload');
    try {
      final data = jsonDecode(payload);

      // Example: Check if it's a confirmation response for our request
      if (data['m2m:rsp'] != null) {
        final rsp = data['m2m:rsp'];
        final int statusCode = rsp['rsc'] ?? 0; // Response Status Code
        final String? requestId = rsp['rqi']; // Original Request ID

        logger.info(
          "MQTT: Received response with status $statusCode for request $requestId",
        );

        if (statusCode == 201 || statusCode == 200) {
          // Optionally show a confirmation SnackBar based on response
          // Be careful not to show duplicate SnackBars if already shown optimistically
          // ScaffoldMessenger.of(context).showSnackBar(
          //   SnackBar(content: Text("Konfirmasi diterima: Batas diatur (Kode: $statusCode)"), backgroundColor: Colors.blue)
          // );
          // Maybe update local state if the response contains new confirmed data
        } else {
          // Handle error responses from Antares
          logger.warning(
            "MQTT: Received error response from Antares: $statusCode",
          );
          // ScaffoldMessenger.of(context).showSnackBar(
          //   SnackBar(content: Text("Server Antares merespon error: $statusCode"), backgroundColor: Colors.orange)
          // );
        }
      } else {
        // Handle other types of incoming data if needed
        logger.info("MQTT: Received data doesn't match known response format.");
        // onDataReceived(contentData); // If you were passing data up before
      }
    } catch (e) {
      logger.severe('MQTT: Error processing MQTT data: $e\nPayload: $payload');
    }
  }

  // --- Publish Energy Limit via MQTT (Called by Button) ---
  Future<void> _publishEnergyLimit() async {
    // --- Input validation ---
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
    // --- End validation ---

    // --- Check MQTT Connection ---
    if (client == null ||
        client!.connectionStatus?.state != MqttConnectionState.connected) {
      logger.warning('MQTT: Client not connected. Cannot send.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('MQTT Tidak Terhubung. Tidak dapat mengirim.'),
          backgroundColor: Colors.orange,
        ),
      );
      // Try to reconnect
      await _connectMqtt();
      if (client == null ||
          client!.connectionStatus?.state != MqttConnectionState.connected)
        return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Calculate limits using the exact format from the JSON data
      final newLimit90 = (newLimit * 0.9);
      final newLimit80 = (newLimit * 0.8);

      // Step 1: Create the content payload matching the JSON format
      final Map<String, dynamic> contentPayload = {
        "energyLimit2": newLimit, // Use exact field name from JSON
        "limit90": newLimit90, // These will be calculated
        "limit80": newLimit80, // on the server side too
      };

      // Step 2: Create the properly structured oneM2M request
      final Map<String, dynamic> requestPayload = {
        "m2m:rqp": {
          "fr": _accessKey,
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName",
          "op": 1,
          "rqi":
              DateTime.now().millisecondsSinceEpoch
                  .toString(), // Use timestamp for unique request ID
          "pc": {
            "m2m:cin": {
              "cnf": "message",
              "con": jsonEncode(
                contentPayload,
              ), // Properly encode the inner content
            },
          },
          "ty": 4,
        },
      };

      // Step 3: Convert the entire structure to JSON
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

      // --- Optimistic Success Feedback ---
      logger.info('MQTT: Energy limit update message published.');
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Perintah pengaturan batas telah dikirim'),
          backgroundColor: Colors.green,
        ),
      );

      // Pop the screen, passing the *intended* new values
      Navigator.pop(context, {
        'newLimit': newLimit,
        'newLimit90': newLimit90,
        'newLimit80': newLimit80,
      });
    } catch (e) {
      logger.severe('MQTT: Error publishing energy limit: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Gagal mengirim via MQTT: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // --- Build Method ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          // Show connection status in AppBar
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
                          // Call the publishing function directly
                          onPressed:
                              _isLoading || !_isMqttConnected
                                  ? null
                                  : _publishEnergyLimit, // Disable if loading or disconnected
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isMqttConnected
                                    ? Colors.amber[700]
                                    : Colors.grey, // Grey out if disconnected
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
