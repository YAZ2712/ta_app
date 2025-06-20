import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
// import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ManualControlScreen extends StatefulWidget {
  // Initial states for Floor 1
  final bool initialFanStatusL1;
  final bool initialLampStatusL1;
  final bool initialAcStatusL1;
  final bool initialDispenserStatusL1;
  final bool initialSystemActiveL1;

  // Initial states for Floor 2
  final bool initialFanStatusL2;
  final bool initialLampStatusL2;
  final bool initialAcStatusL2;
  final bool initialDispenserStatusL2;
  final bool initialSystemActiveL2;

  const ManualControlScreen({
    super.key,
    // Floor 1
    this.initialFanStatusL1 = false,
    this.initialLampStatusL1 = false,
    this.initialAcStatusL1 = false,
    this.initialDispenserStatusL1 = false,
    this.initialSystemActiveL1 = false,
    // Floor 2
    this.initialFanStatusL2 = false,
    this.initialLampStatusL2 = false,
    this.initialAcStatusL2 = false,
    this.initialDispenserStatusL2 = false,
    this.initialSystemActiveL2 = false,
  });

  @override
  State<ManualControlScreen> createState() => _ManualControlScreenState();
}

class _ManualControlScreenState extends State<ManualControlScreen> {
  // --- State Variables for 2 Floors ---
  // Floor 1
  late bool fanStatusL1,
      lampStatusL1,
      acStatusL1,
      dispenserStatusL1,
      systemActiveL1;
  // Floor 2
  late bool fanStatusL2,
      lampStatusL2,
      acStatusL2,
      dispenserStatusL2,
      systemActiveL2;

  // --- State Tracking for Unsaved Changes ---
  // Floor 1
  late bool _lastFanStatusL1,
      _lastLampStatusL1,
      _lastAcStatusL1,
      _lastDispenserStatusL1,
      _lastSystemActiveL1;
  // Floor 2
  late bool _lastFanStatusL2,
      _lastLampStatusL2,
      _lastAcStatusL2,
      _lastDispenserStatusL2,
      _lastSystemActiveL2;

  bool _hasUnsavedChanges = false;
  bool _isDisposed = false;
  bool _isApplyingChanges = false;
  bool _isSwitchingToAuto = false;
  bool _isMqttConnected = false;
  bool _waitingForConfirmation = false;
  String? _lastRequestId;
  Timer? _changeDebounceTimer;

  final logger = Logger('ManualControlScreen');
  static const Duration _debounceDelay = Duration(seconds: 2);

  // --- SharedPreferences Keys ---
  static const String _keyHasManualSettings = 'has_manual_settings';
  // Floor 1 Keys
  static const String _keyFanStatusL1 = 'manual_fan_status_l1';
  static const String _keyLampStatusL1 = 'manual_lamp_status_l1';
  static const String _keyAcStatusL1 = 'manual_ac_status_l1';
  static const String _keyDispenserStatusL1 = 'manual_dispenser_status_l1';
  static const String _keySystemActiveL1 = 'manual_system_active_l1';
  // Floor 2 Keys
  static const String _keyFanStatusL2 = 'manual_fan_status_l2';
  static const String _keyLampStatusL2 = 'manual_lamp_status_l2';
  static const String _keyAcStatusL2 = 'manual_ac_status_l2';
  static const String _keyDispenserStatusL2 = 'manual_dispenser_status_l2';
  static const String _keySystemActiveL2 = 'manual_system_active_l2';

  // --- MQTT Configuration (sesuai ESP) ---
  MqttServerClient? client;
  final String _mqttBroker = 'mqtt.antares.id';
  final int _mqttPort = 1883;
  final String _accessKey = 'fe5c7a15d8c13220:bfd764392a99a094';
  final String _projectName = 'TADKT-1';
  final String _deviceName = 'PMM';
  final String _clientId =
      'flutter_client_${DateTime.now().millisecondsSinceEpoch}';
  final String _responseTopic =
      '/oneM2M/resp/fe5c7a15d8c13220:bfd764392a99a094/antares-cse/json';
  final String _requestTopic =
      '/oneM2M/req/fe5c7a15d8c13220:bfd764392a99a094/antares-cse/json';
  StreamSubscription? _mqttSubscription;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _initializeStatus();
    _setupLogging();
    _connectMqtt();
  }

  Future<void> _initializeStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final hasManualSettings = prefs.getBool(_keyHasManualSettings) ?? false;

    if (mounted && !_isDisposed) {
      setState(() {
        if (hasManualSettings) {
          // Load saved manual settings
          // Floor 1
          fanStatusL1 =
              prefs.getBool(_keyFanStatusL1) ?? widget.initialFanStatusL1;
          lampStatusL1 =
              prefs.getBool(_keyLampStatusL1) ?? widget.initialLampStatusL1;
          acStatusL1 =
              prefs.getBool(_keyAcStatusL1) ?? widget.initialAcStatusL1;
          dispenserStatusL1 =
              prefs.getBool(_keyDispenserStatusL1) ??
              widget.initialDispenserStatusL1;
          systemActiveL1 =
              prefs.getBool(_keySystemActiveL1) ?? widget.initialSystemActiveL1;
          // Floor 2
          fanStatusL2 =
              prefs.getBool(_keyFanStatusL2) ?? widget.initialFanStatusL2;
          lampStatusL2 =
              prefs.getBool(_keyLampStatusL2) ?? widget.initialLampStatusL2;
          acStatusL2 =
              prefs.getBool(_keyAcStatusL2) ?? widget.initialAcStatusL2;
          dispenserStatusL2 =
              prefs.getBool(_keyDispenserStatusL2) ??
              widget.initialDispenserStatusL2;
          systemActiveL2 =
              prefs.getBool(_keySystemActiveL2) ?? widget.initialSystemActiveL2;
        } else {
          // Use initial values from the previous screen
          // Floor 1
          fanStatusL1 = widget.initialFanStatusL1;
          lampStatusL1 = widget.initialLampStatusL1;
          acStatusL1 = widget.initialAcStatusL1;
          dispenserStatusL1 = widget.initialDispenserStatusL1;
          systemActiveL1 = widget.initialSystemActiveL1;
          // Floor 2
          fanStatusL2 = widget.initialFanStatusL2;
          lampStatusL2 = widget.initialLampStatusL2;
          acStatusL2 = widget.initialAcStatusL2;
          dispenserStatusL2 = widget.initialDispenserStatusL2;
          systemActiveL2 = widget.initialSystemActiveL2;
        }
      });
    }
    // Store initial state to track changes
    _updateLastKnownState();
  }

  void _updateLastKnownState() {
    // Floor 1
    _lastFanStatusL1 = fanStatusL1;
    _lastLampStatusL1 = lampStatusL1;
    _lastAcStatusL1 = acStatusL1;
    _lastDispenserStatusL1 = dispenserStatusL1;
    _lastSystemActiveL1 = systemActiveL1;
    // Floor 2
    _lastFanStatusL2 = fanStatusL2;
    _lastLampStatusL2 = lampStatusL2;
    _lastAcStatusL2 = acStatusL2;
    _lastDispenserStatusL2 = dispenserStatusL2;
    _lastSystemActiveL2 = systemActiveL2;
    _hasUnsavedChanges = false;
  }

  bool _hasStateChanged() {
    return fanStatusL1 != _lastFanStatusL1 ||
        lampStatusL1 != _lastLampStatusL1 ||
        acStatusL1 != _lastAcStatusL1 ||
        dispenserStatusL1 != _lastDispenserStatusL1 ||
        systemActiveL1 != _lastSystemActiveL1 ||
        fanStatusL2 != _lastFanStatusL2 ||
        lampStatusL2 != _lastLampStatusL2 ||
        acStatusL2 != _lastAcStatusL2 ||
        dispenserStatusL2 != _lastDispenserStatusL2 ||
        systemActiveL2 != _lastSystemActiveL2;
  }

  void _handleStateChange() {
    if (_hasStateChanged()) {
      _hasUnsavedChanges = true;
      _changeDebounceTimer?.cancel();
      _changeDebounceTimer = Timer(_debounceDelay, () {
        final anySystemActive = systemActiveL1 || systemActiveL2;
        if (_hasUnsavedChanges && _hasStateChanged() && anySystemActive) {
          logger.info('Auto-sending changes after debounce delay');
          updateDeviceStatus();
        }
      });
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveStatusToPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHasManualSettings, true);
    // Floor 1
    await prefs.setBool(_keyFanStatusL1, fanStatusL1);
    await prefs.setBool(_keyLampStatusL1, lampStatusL1);
    await prefs.setBool(_keyAcStatusL1, acStatusL1);
    await prefs.setBool(_keyDispenserStatusL1, dispenserStatusL1);
    await prefs.setBool(_keySystemActiveL1, systemActiveL1);
    // Floor 2
    await prefs.setBool(_keyFanStatusL2, fanStatusL2);
    await prefs.setBool(_keyLampStatusL2, lampStatusL2);
    await prefs.setBool(_keyAcStatusL2, acStatusL2);
    await prefs.setBool(_keyDispenserStatusL2, dispenserStatusL2);
    await prefs.setBool(_keySystemActiveL2, systemActiveL2);
    logger.info('Manual control settings for both floors saved to preferences');
  }

  Future<void> _clearManualSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyHasManualSettings);
    // Floor 1
    await prefs.remove(_keyFanStatusL1);
    await prefs.remove(_keyLampStatusL1);
    await prefs.remove(_keyAcStatusL1);
    await prefs.remove(_keyDispenserStatusL1);
    await prefs.remove(_keySystemActiveL1);
    // Floor 2
    await prefs.remove(_keyFanStatusL2);
    await prefs.remove(_keyLampStatusL2);
    await prefs.remove(_keyAcStatusL2);
    await prefs.remove(_keyDispenserStatusL2);
    await prefs.remove(_keySystemActiveL2);
    logger.info('Manual control settings cleared from preferences');
  }

  @override
  void dispose() {
    _isDisposed = true;
    _changeDebounceTimer?.cancel();
    _reconnectTimer?.cancel();
    logger.info("Disposing ManualControlScreen - Disconnecting MQTT");
    _disconnectMqtt();
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

  // --- MQTT Logic (Mostly Unchanged, except for payload creation) ---

  Future<void> _connectMqtt() async {
    if (client != null &&
        client?.connectionStatus?.state == MqttConnectionState.connected) {
      logger.info("MQTT Client already connected.");
      return;
    }
    client = MqttServerClient(_mqttBroker, _clientId)..port = _mqttPort;
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
    if (mounted && !_isDisposed) setState(() => _isMqttConnected = true);
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
    if (mounted && !_isDisposed) setState(() => _isMqttConnected = false);
    _mqttSubscription?.cancel();
    _mqttSubscription = null;
    client = null;
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (mounted && !_isDisposed) {
      logger.info("MQTT: Scheduling reconnect in 5 seconds...");
      _reconnectTimer = Timer(const Duration(seconds: 5), () {
        logger.info("MQTT: Attempting scheduled reconnect...");
        _connectMqtt();
      });
    }
  }

  void _onMqttSubscribed(String topic) =>
      logger.info('MQTT: Subscribed to topic: $topic');
  void _pong() => logger.fine('MQTT: Ping response received (pong)');

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
          if (mounted && !_isDisposed)
            setState(() => _waitingForConfirmation = false);
          if (statusCode == 2001 || statusCode == 2000) {
            // 2001 (Created) or 2000 (OK)
            _updateLastKnownState();
            _saveStatusToPreferences();
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
      }
    } catch (e) {
      logger.severe('MQTT: Error processing MQTT data: $e\nPayload: $payload');
    }
  }

  // --- Core Logic for Sending Data ---

  Future<void> updateDeviceStatus() async {
    if (_isApplyingChanges || _isSwitchingToAuto) return;
    if (!_hasStateChanged()) {
      logger.info('No state changes detected, skipping update');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tidak ada perubahan untuk diterapkan'),
          backgroundColor: Colors.blue,
        ),
      );
      return;
    }
    if (!_isMqttConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Koneksi Gagal. Coba hubungkan kembali...'),
          backgroundColor: Colors.orange,
        ),
      );
      await _connectMqtt();
      if (!_isMqttConnected) return;
    }

    if (mounted && !_isDisposed) {
      setState(() {
        _isApplyingChanges = true;
        _waitingForConfirmation = true;
        _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
      });
    }
    _changeDebounceTimer?.cancel();

    try {
      logger.info('Sending multi-floor device status update');

      // *** PAYLOAD SESUAI DENGAN KODE ESP32 ***
      final contentPayload = {
        "source": "flutter_app",
        "control_command": "1",
        "manual_control": 1,
        "resetOccupancy": 0, // Default value, can be changed if needed
        // Floor 1 Data (Konversi boolean ke integer 1/0)
        "system_active_l1": systemActiveL1 ? 1 : 0,
        "fan_status_l1": fanStatusL1 ? 1 : 0,
        "lamp_status_l1": lampStatusL1 ? 1 : 0,
        "ac_status_l1": acStatusL1 ? 1 : 0,
        "dispenser_status_l1": dispenserStatusL1 ? 1 : 0,

        // Floor 2 Data (Konversi boolean ke integer 1/0)
        "system_active_l2": systemActiveL2 ? 1 : 0,
        "fan_status_l2": fanStatusL2 ? 1 : 0,
        "lamp_status_l2": lampStatusL2 ? 1 : 0,
        "ac_status_l2": acStatusL2 ? 1 : 0,
        "dispenser_status_l2": dispenserStatusL2 ? 1 : 0,
      };

      final requestPayload = {
        "m2m:rqp": {
          "fr": _accessKey,
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName",
          "op": 1,
          "rqi": _lastRequestId,
          "ty": 4,
          "pc": {
            "m2m:cin": {"cnf": "message", "con": jsonEncode(contentPayload)},
          },
        },
      };

      _publishMqttMessage(jsonEncode(requestPayload));

      await Future.delayed(const Duration(seconds: 4));
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
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengirim via MQTT: $e'),
            backgroundColor: Colors.red,
          ),
        );
    } finally {
      if (mounted && !_isDisposed) setState(() => _isApplyingChanges = false);
    }
  }

  Future<void> switchToAutomaticMode() async {
    if (_isApplyingChanges || _isSwitchingToAuto) return;
    if (!_isMqttConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Koneksi Gagal. Coba hubungkan kembali...'),
          backgroundColor: Colors.orange,
        ),
      );
      await _connectMqtt();
      if (!_isMqttConnected) return;
    }

    setState(() {
      _isSwitchingToAuto = true;
      _waitingForConfirmation = true;
      _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
    });

    try {
      // Payload untuk menonaktifkan mode manual di ESP32
      final contentPayload = {
        "source": "flutter_app",
        "control_command": "1", // Tetap command
        "manual_control": 0, // Kunci untuk beralih ke otomatis
      };
      final requestPayload = {
        "m2m:rqp": {
          "fr": _accessKey,
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName",
          "op": 1,
          "rqi": _lastRequestId,
          "ty": 4,
          "pc": {
            "m2m:cin": {"cnf": "message", "con": jsonEncode(contentPayload)},
          },
        },
      };
      _publishMqttMessage(jsonEncode(requestPayload));

      await Future.delayed(const Duration(seconds: 3));
      if (_waitingForConfirmation && mounted) {
        logger.warning('Did not receive confirmation for switch to auto mode');
      } else {
        await _clearManualSettings();
        if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      logger.severe('MQTT: Error switching to automatic mode: $e');
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengirim via MQTT: $e'),
            backgroundColor: Colors.red,
          ),
        );
    } finally {
      if (mounted && !_isDisposed) setState(() => _isSwitchingToAuto = false);
    }
  }

  void _publishMqttMessage(String payloadString) {
    logger.info('MQTT: Publishing to topic: $_requestTopic');
    logger.fine('MQTT: Publishing payload: $payloadString');
    final builder = MqttClientPayloadBuilder();
    builder.addString(payloadString);
    client!.publishMessage(
      _requestTopic,
      MqttQos.atLeastOnce,
      builder.payload!,
      retain: false,
    );
  }

  // --- UI Building ---

  Widget _buildControlRow(String title, bool value, Function(bool) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
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

  Widget _buildFloorControlSection({
    required int floor,
    required bool systemActive,
    required bool fanStatus,
    required bool lampStatus,
    required bool acStatus,
    required bool dispenserStatus,
    required ValueChanged<bool> onSystemActiveChanged,
    required ValueChanged<bool> onFanChanged,
    required ValueChanged<bool> onLampChanged,
    required ValueChanged<bool> onAcChanged,
    required ValueChanged<bool> onDispenserChanged,
  }) {
    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Kontrol Lantai $floor',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.blueAccent,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Aktifkan Sistem Lantai $floor',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Switch(
                  value: systemActive,
                  onChanged: onSystemActiveChanged,
                  activeColor: Colors.green,
                ),
              ],
            ),
            Text(
              systemActive
                  ? 'Sistem aktif, perangkat dapat dikontrol.'
                  : 'Sistem non-aktif, semua perangkat mati.',
              style: TextStyle(
                fontSize: 14,
                fontStyle: FontStyle.italic,
                color: Colors.grey[600],
              ),
            ),
            const Divider(height: 24, thickness: 1),
            AnimatedOpacity(
              opacity: systemActive ? 1.0 : 0.4,
              duration: const Duration(milliseconds: 300),
              child: IgnorePointer(
                ignoring: !systemActive,
                child: Column(
                  children: [
                    _buildControlRow('Kipas', fanStatus, onFanChanged),
                    _buildControlRow('Lampu', lampStatus, onLampChanged),
                    _buildControlRow('AC', acStatus, onAcChanged),
                    _buildControlRow(
                      'Dispenser',
                      dispenserStatus,
                      onDispenserChanged,
                    ),
                  ],
                ),
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
            const Text('Kontrol Manual\nMulti-Lantai'),
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
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- Floor 1 Control Section ---
              _buildFloorControlSection(
                floor: 1,
                systemActive: systemActiveL1,
                fanStatus: fanStatusL1,
                lampStatus: lampStatusL1,
                acStatus: acStatusL1,
                dispenserStatus: dispenserStatusL1,
                onSystemActiveChanged: (value) {
                  setState(() {
                    systemActiveL1 = value;
                    if (!value) {
                      fanStatusL1 = false;
                      lampStatusL1 = false;
                      acStatusL1 = false;
                      dispenserStatusL1 = false;
                    }
                  });
                  _handleStateChange();
                },
                onFanChanged:
                    (value) => setState(() {
                      fanStatusL1 = value;
                      _handleStateChange();
                    }),
                onLampChanged:
                    (value) => setState(() {
                      lampStatusL1 = value;
                      _handleStateChange();
                    }),
                onAcChanged:
                    (value) => setState(() {
                      acStatusL1 = value;
                      _handleStateChange();
                    }),
                onDispenserChanged:
                    (value) => setState(() {
                      dispenserStatusL1 = value;
                      _handleStateChange();
                    }),
              ),

              // --- Floor 2 Control Section ---
              _buildFloorControlSection(
                floor: 2,
                systemActive: systemActiveL2,
                fanStatus: fanStatusL2,
                lampStatus: lampStatusL2,
                acStatus: acStatusL2,
                dispenserStatus: dispenserStatusL2,
                onSystemActiveChanged: (value) {
                  setState(() {
                    systemActiveL2 = value;
                    if (!value) {
                      fanStatusL2 = false;
                      lampStatusL2 = false;
                      acStatusL2 = false;
                      dispenserStatusL2 = false;
                    }
                  });
                  _handleStateChange();
                },
                onFanChanged:
                    (value) => setState(() {
                      fanStatusL2 = value;
                      _handleStateChange();
                    }),
                onLampChanged:
                    (value) => setState(() {
                      lampStatusL2 = value;
                      _handleStateChange();
                    }),
                onAcChanged:
                    (value) => setState(() {
                      acStatusL2 = value;
                      _handleStateChange();
                    }),
                onDispenserChanged:
                    (value) => setState(() {
                      dispenserStatusL2 = value;
                      _handleStateChange();
                    }),
              ),

              const SizedBox(height: 24),
              ElevatedButton(
                onPressed:
                    _isApplyingChanges || !_hasStateChanged()
                        ? null
                        : updateDeviceStatus,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor:
                      _hasStateChanged() && _isMqttConnected
                          ? Colors.orangeAccent
                          : Colors.blue,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  disabledBackgroundColor: Colors.grey[400],
                ),
                child:
                    _isApplyingChanges
                        ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        )
                        : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.save, color: Colors.white),
                            const SizedBox(width: 8),
                            const Text(
                              'Terapkan Perubahan',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.white,
                              ),
                            ),
                            if (_hasUnsavedChanges && _hasStateChanged()) ...[
                              const SizedBox(width: 8),
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isSwitchingToAuto ? null : switchToAutomaticMode,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.teal,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child:
                    _isSwitchingToAuto
                        ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        )
                        : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.autorenew, color: Colors.white),
                            SizedBox(width: 8),
                            Text(
                              'Kembali ke Mode Otomatis',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
