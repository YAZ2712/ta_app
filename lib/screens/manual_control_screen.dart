import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
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
  String? _lastRequestId;
  Timer? _changeDebounceTimer;

  Map<String, int> _pendingConfirmations = {};
  Timer? _confirmationTimeoutTimer;

  // Enhanced feedback states
  String _feedbackMessage = '';
  Color _feedbackColor = Colors.blue;
  bool _showProgressIndicator = false;
  int _totalExpectedConfirmations = 0;
  int _receivedConfirmations = 0;

  final logger = Logger('ManualControlScreen');
  // static const Duration _debounceDelay = Duration(seconds: 2);
  static const Duration _confirmationTimeoutDuration = Duration(seconds: 15);

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
  final String _requestTopic =
      '/oneM2M/req/fe5c7a15d8c13220:bfd764392a99a094/antares-cse/json';
  final String _dataTopic =
      '/oneM2M/ntf/fe5c7a15d8c13220:bfd764392a99a094/antares-cse';
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
      if (mounted) {
        setState(() {
          _hasUnsavedChanges = true;
        });
      }
    }
  }

  // Enhanced feedback methods
  void _updateFeedback(
    String message,
    Color color, {
    bool showProgress = false,
  }) {
    if (mounted && !_isDisposed) {
      setState(() {
        _feedbackMessage = message;
        _feedbackColor = color;
        _showProgressIndicator = showProgress;
      });
    }
  }

  void _showFeedbackSnackBar(
    String message,
    Color backgroundColor, {
    Duration? duration,
  }) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                backgroundColor == Colors.green
                    ? Icons.check_circle
                    : backgroundColor == Colors.red
                    ? Icons.error
                    : backgroundColor == Colors.orange
                    ? Icons.warning
                    : Icons.info,
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: backgroundColor,
          duration: duration ?? const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  }

  Future<void> _saveSettingsToPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHasManualSettings, true);

    // Lantai 1
    await prefs.setBool(_keyFanStatusL1, fanStatusL1);
    await prefs.setBool(_keyLampStatusL1, lampStatusL1);
    await prefs.setBool(_keyAcStatusL1, acStatusL1);
    await prefs.setBool(_keyDispenserStatusL1, dispenserStatusL1);
    await prefs.setBool(_keySystemActiveL1, systemActiveL1);

    // Lantai 2
    await prefs.setBool(_keyFanStatusL2, fanStatusL2);
    await prefs.setBool(_keyLampStatusL2, lampStatusL2);
    await prefs.setBool(_keyAcStatusL2, acStatusL2);
    await prefs.setBool(_keyDispenserStatusL2, dispenserStatusL2);
    await prefs.setBool(_keySystemActiveL2, systemActiveL2);

    logger.info('Pengaturan kontrol manual berhasil disimpan.');
    _showFeedbackSnackBar('Pengaturan berhasil disimpan!', Colors.green);

    if (mounted) {
      setState(() {
        _hasUnsavedChanges = false;
        _updateLastKnownState();
      });
    }
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
    _confirmationTimeoutTimer?.cancel();
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

  // --- MQTT Logic ---

  Future<void> _connectMqtt() async {
    if (client != null &&
        client?.connectionStatus?.state == MqttConnectionState.connected) {
      logger.info("MQTT Client already connected.");
      return;
    }

    _updateFeedback(
      'Menghubungkan ke server...',
      Colors.orange,
      showProgress: true,
    );

    client = MqttServerClient(_mqttBroker, _clientId)..port = _mqttPort;
    client!.keepAlivePeriod = 60;
    client!.logging(on: true);
    client!.onConnected = _onMqttConnected;
    client!.onDisconnected = _onMqttDisconnected;
    client!.onSubscribed = _onMqttSubscribed;
    client!.pongCallback = _pong;
    final connMessage = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .startClean()
        // .authenticateAs('fe5c7a15d8c13220', 'bfd764392a99a094')
        .withWillQos(MqttQos.atLeastOnce);
    client!.connectionMessage = connMessage;
    try {
      logger.info('MQTT: Attempting connection to $_mqttBroker...');
      await client!.connect();
    } catch (e) {
      logger.severe('MQTT: Connection exception: $e');
      _updateFeedback('Gagal terhubung ke server', Colors.red);
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
      setState(() => _isMqttConnected = true);
      _updateFeedback('Terhubung ke server', Colors.green);
    }
    logger.info('MQTT: Subscribing to data topic: $_dataTopic');
    client?.subscribe(_dataTopic, MqttQos.atLeastOnce);
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
        if (recMess.topic == _dataTopic) {
          _processDeviceData(payload);
        } else {
          logger.warning(
            "Received message on unhandled topic: ${recMess.topic}",
          );
        }
      }
    });
    logger.info("MQTT: Listening for updates started.");
  }

  void _onMqttDisconnected() {
    logger.warning('MQTT: Disconnected.');
    _updateFeedback('Terputus dari server', Colors.red);
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
      _updateFeedback(
        'Mencoba menghubungkan kembali...',
        Colors.orange,
        showProgress: true,
      );
      _reconnectTimer = Timer(const Duration(seconds: 5), () {
        logger.info("MQTT: Attempting scheduled reconnect...");
        _connectMqtt();
      });
    }
  }

  void _onMqttSubscribed(String topic) =>
      logger.info('MQTT: Subscribed to topic: $topic');
  void _pong() => logger.fine('MQTT: Ping response received (pong)');

  void _processDeviceData(String payload) {
    // Jangan proses jika kita tidak sedang menunggu konfirmasi apapun
    if (_pendingConfirmations.isEmpty) {
      return;
    }

    logger.info("--- Menerima Data untuk Konfirmasi ---");
    logger.fine("Raw Payload: $payload");

    try {
      final notification = jsonDecode(payload);
      final cin = notification['m2m:sgn']?['nev']?['rep']?['m2m:cin'];

      if (cin == null) {
        logger.warning(
          "Struktur payload tidak sesuai, 'm2m:cin' tidak ditemukan.",
        );
        return;
      }

      final String? contentString = cin['con'];
      if (contentString == null || contentString.isEmpty) {
        logger.warning(
          "Payload 'cin' tidak memiliki content ('con') atau kosong.",
        );
        return;
      }

      final Map<String, dynamic> deviceState = jsonDecode(contentString);
      logger.info("Data Perangkat yang Diterima: $deviceState");

      // Update progress feedback
      _updateFeedback(
        'Menerima konfirmasi... ($_receivedConfirmations/$_totalExpectedConfirmations)',
        Colors.blue,
        showProgress: true,
      );

      List<String> confirmedKeys = [];
      _pendingConfirmations.forEach((key, expectedValue) {
        if (deviceState.containsKey(key)) {
          var receivedValue = deviceState[key];

          bool isMatch = _compareValues(expectedValue, receivedValue, key);

          if (isMatch) {
            logger.info(
              'SUKSES: Konfirmasi diterima untuk $key -> $receivedValue',
            );
            confirmedKeys.add(key);
            _receivedConfirmations++;

            // Update progress feedback
            _updateFeedback(
              'Konfirmasi diterima: ${_getFriendlyName(key)} ($_receivedConfirmations/$_totalExpectedConfirmations)',
              Colors.blue,
              showProgress: true,
            );

            _showFeedbackSnackBar(
              'Berhasil: ${_getFriendlyName(key)}',
              Colors.green,
              duration: const Duration(seconds: 1),
            );
          } else {
            logger.warning(
              'GAGAL: Konfirmasi tidak cocok untuk $key. Diharapkan: $expectedValue, Diterima: $receivedValue',
            );
          }
        }
      });

      // Hapus semua kunci yang sudah terkonfirmasi
      for (var key in confirmedKeys) {
        _pendingConfirmations.remove(key);
      }

      // Jika semua konfirmasi sudah diterima
      if (_pendingConfirmations.isEmpty) {
        logger.info('Semua perubahan berhasil dikonfirmasi oleh perangkat.');
        _confirmationTimeoutTimer?.cancel();

        if (mounted && !_isDisposed) {
          setState(() {
            _isApplyingChanges = false;
          });
          _updateLastKnownState();
          _saveSettingsToPreferences();

          _updateFeedback('Semua perubahan berhasil diterapkan!', Colors.green);
          _showFeedbackSnackBar(
            'Semua perubahan berhasil diterapkan! ($_receivedConfirmations/$_totalExpectedConfirmations)',
            Colors.green,
            duration: const Duration(seconds: 4),
          );
        }

        // Reset counters
        _receivedConfirmations = 0;
        _totalExpectedConfirmations = 0;
      } else {
        logger.warning(
          "Masih menunggu konfirmasi untuk: ${_pendingConfirmations.keys}",
        );
      }
    } catch (e, s) {
      logger.severe('Gagal memproses data perangkat: $e\n$s');
      _updateFeedback('Error memproses data perangkat', Colors.red);
    }
  }

  bool _compareValues(
    dynamic expectedValue,
    dynamic receivedValue,
    String key,
  ) {
    if (expectedValue == receivedValue) {
      return true;
    }

    dynamic normalizedExpected = expectedValue;
    dynamic normalizedReceived = receivedValue;

    if (expectedValue is bool) {
      normalizedExpected = expectedValue ? 1 : 0;
    }
    if (receivedValue is bool) {
      normalizedReceived = receivedValue ? 1 : 0;
    }

    if (expectedValue is String && _isNumeric(expectedValue)) {
      normalizedExpected = int.tryParse(expectedValue) ?? expectedValue;
    }
    if (receivedValue is String && _isNumeric(receivedValue)) {
      normalizedReceived = int.tryParse(receivedValue) ?? receivedValue;
    }

    if (normalizedExpected == normalizedReceived) {
      return true;
    }

    if (normalizedExpected.toString() == normalizedReceived.toString()) {
      return true;
    }

    return false;
  }

  bool _isNumeric(String str) {
    return int.tryParse(str) != null || double.tryParse(str) != null;
  }

  String _getFriendlyName(String key) {
    final Map<String, String> friendlyNames = {
      'system_active_l1': 'Sistem Lantai 1',
      'fan_status_l1': 'Kipas Lantai 1',
      'lamp_status_l1': 'Lampu Lantai 1',
      'ac_status_l1': 'AC Lantai 1',
      'dispenser_status_l1': 'Dispenser Lantai 1',
      'system_active_l2': 'Sistem Lantai 2',
      'fan_status_l2': 'Kipas Lantai 2',
      'lamp_status_l2': 'Lampu Lantai 2',
      'ac_status_l2': 'AC Lantai 2',
      'dispenser_status_l2': 'Dispenser Lantai 2',
    };
    return friendlyNames[key] ?? key.replaceAll('_', ' ');
  }

  void _startConfirmationTimeout() {
    _confirmationTimeoutTimer?.cancel();
    _confirmationTimeoutTimer = Timer(_confirmationTimeoutDuration, () {
      if (_pendingConfirmations.isNotEmpty && mounted) {
        logger.warning(
          'Confirmation timeout! Did not receive updates for: ${_pendingConfirmations.keys}',
        );
        final missingItems = _pendingConfirmations.keys
            .map(_getFriendlyName)
            .join(', ');

        _updateFeedback(
          'Timeout: Tidak ada respons dari perangkat',
          Colors.red,
        );
        _showFeedbackSnackBar(
          'Timeout: $missingItems tidak merespons dalam waktu yang ditentukan',
          Colors.orange,
          duration: const Duration(seconds: 5),
        );

        if (mounted && !_isDisposed) {
          setState(() {
            _isApplyingChanges = false;
            _pendingConfirmations.clear();
            _receivedConfirmations = 0;
            _totalExpectedConfirmations = 0;
          });
        }
      }
    });
  }

  // --- Core Logic for Sending Data ---

  Future<void> updateDeviceStatus() async {
    if (_isApplyingChanges || _isSwitchingToAuto) return;
    if (!_hasStateChanged()) {
      logger.info('No state changes detected, skipping update');
      _showFeedbackSnackBar(
        'Tidak ada perubahan untuk diterapkan',
        Colors.blue,
      );
      return;
    }
    if (!_isMqttConnected) {
      _showFeedbackSnackBar(
        'Koneksi Gagal. Mencoba menghubungkan kembali...',
        Colors.orange,
      );
      await _connectMqtt();
      if (!_isMqttConnected) return;
    }

    _changeDebounceTimer?.cancel();
    _pendingConfirmations.clear();
    _receivedConfirmations = 0;

    // Populate a list of what we expect to be confirmed
    if (systemActiveL1 != _lastSystemActiveL1)
      _pendingConfirmations['system_active_l1'] = systemActiveL1 ? 1 : 0;
    if (fanStatusL1 != _lastFanStatusL1)
      _pendingConfirmations['fan_status_l1'] = fanStatusL1 ? 1 : 0;
    if (lampStatusL1 != _lastLampStatusL1)
      _pendingConfirmations['lamp_status_l1'] = lampStatusL1 ? 1 : 0;
    if (acStatusL1 != _lastAcStatusL1)
      _pendingConfirmations['ac_status_l1'] = acStatusL1 ? 1 : 0;
    if (dispenserStatusL1 != _lastDispenserStatusL1)
      _pendingConfirmations['dispenser_status_l1'] = dispenserStatusL1 ? 1 : 0;

    if (systemActiveL2 != _lastSystemActiveL2)
      _pendingConfirmations['system_active_l2'] = systemActiveL2 ? 1 : 0;
    if (fanStatusL2 != _lastFanStatusL2)
      _pendingConfirmations['fan_status_l2'] = fanStatusL2 ? 1 : 0;
    if (lampStatusL2 != _lastLampStatusL2)
      _pendingConfirmations['lamp_status_l2'] = lampStatusL2 ? 1 : 0;
    if (acStatusL2 != _lastAcStatusL2)
      _pendingConfirmations['ac_status_l2'] = acStatusL2 ? 1 : 0;
    if (dispenserStatusL2 != _lastDispenserStatusL2)
      _pendingConfirmations['dispenser_status_l2'] = dispenserStatusL2 ? 1 : 0;

    if (_pendingConfirmations.isEmpty) {
      logger.info("No actionable changes to send.");
      return;
    }

    _totalExpectedConfirmations = _pendingConfirmations.length;
    logger.info("Pending confirmations: $_pendingConfirmations");

    if (mounted && !_isDisposed) {
      setState(() {
        _isApplyingChanges = true;
        _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
      });
    }

    _updateFeedback(
      'Mengirim perubahan... (0/$_totalExpectedConfirmations)',
      Colors.blue,
      showProgress: true,
    );

    _showFeedbackSnackBar(
      'Mengirim $_totalExpectedConfirmations perubahan ke perangkat...',
      Colors.blue,
    );

    try {
      logger.info('Sending multi-floor device status update');
      final contentPayload = {
        "source": "flutter_app",
        "control_command": "1",
        "manual_control": 1,
        "resetOccupancy": 0,
        "system_active_l1": systemActiveL1 ? 1 : 0,
        "fan_status_l1": fanStatusL1 ? 1 : 0,
        "lamp_status_l1": lampStatusL1 ? 1 : 0,
        "ac_status_l1": acStatusL1 ? 1 : 0,
        "dispenser_status_l1": dispenserStatusL1 ? 1 : 0,
        "system_active_l2": systemActiveL2 ? 1 : 0,
        "fan_status_l2": fanStatusL2 ? 1 : 0,
        "lamp_status_l2": lampStatusL2 ? 1 : 0,
        "ac_status_l2": acStatusL2 ? 1 : 0,
        "dispenser_status_l2": dispenserStatusL2 ? 1 : 0,
      };
      final mqttPayload = {
        "m2m:rqp": {
          "fr": _accessKey,
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName/la",
          "op": 1,
          "rqi": _lastRequestId,
          "pc": {
            "m2m:cin": {"cnf": "message", "con": jsonEncode(contentPayload)},
          },
          "ty": 4,
        },
      };

      final builder = MqttClientPayloadBuilder();
      builder.addString(jsonEncode(mqttPayload));

      logger.info('Publishing to topic: $_requestTopic');
      logger.fine('MQTT Payload: ${jsonEncode(mqttPayload)}');
      logger.info('Content Payload: ${jsonEncode(contentPayload)}');

      client?.publishMessage(
        _requestTopic,
        MqttQos.atLeastOnce,
        builder.payload!,
      );

      logger.info('Multi-floor device status update sent successfully');

      // Start confirmation timeout
      _startConfirmationTimeout();

      _updateFeedback(
        'Perubahan terkirim, menunggu konfirmasi... (0/$_totalExpectedConfirmations)',
        Colors.blue,
        showProgress: true,
      );
    } catch (e, s) {
      logger.severe('Failed to send multi-floor device status update: $e\n$s');

      if (mounted && !_isDisposed) {
        setState(() {
          _isApplyingChanges = false;
          _pendingConfirmations.clear();
          _receivedConfirmations = 0;
          _totalExpectedConfirmations = 0;
        });
      }

      _updateFeedback('Gagal mengirim perubahan', Colors.red);
      _showFeedbackSnackBar(
        'Gagal mengirim perubahan: ${e.toString()}',
        Colors.red,
        duration: const Duration(seconds: 5),
      );
    }
  }

  // --- Switch to Auto Mode Logic ---

  Future<void> switchToAutoMode() async {
    if (_isSwitchingToAuto || _isApplyingChanges) return;

    final bool confirm =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Konfirmasi'),
              content: const Text(
                'Apakah Anda yakin ingin beralih ke mode otomatis?\n\n'
                'Ini akan menonaktifkan kontrol manual dan menghapus pengaturan yang tersimpan.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Batal'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Ya, Beralih'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirm) return;

    if (!_isMqttConnected) {
      _showFeedbackSnackBar(
        'Koneksi Gagal. Mencoba menghubungkan kembali...',
        Colors.orange,
      );
      await _connectMqtt();
      if (!_isMqttConnected) return;
    }

    if (mounted && !_isDisposed) {
      setState(() {
        _isSwitchingToAuto = true;
        _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
      });
    }

    _updateFeedback(
      'Beralih ke mode otomatis...',
      Colors.orange,
      showProgress: true,
    );
    _showFeedbackSnackBar(
      'Mengirim perintah untuk beralih ke mode otomatis...',
      Colors.blue,
    );

    try {
      logger.info('Switching to auto mode');

      final contentPayload = {
        "source": "flutter_app",
        "control_command": "0", // 0 = auto mode
        "manual_control": 0,
        "resetOccupancy": 0,
        // Set all systems to inactive when switching to auto
        "system_active_l1": 0,
        "fan_status_l1": 0,
        "lamp_status_l1": 0,
        "ac_status_l1": 0,
        "dispenser_status_l1": 0,
        "system_active_l2": 0,
        "fan_status_l2": 0,
        "lamp_status_l2": 0,
        "ac_status_l2": 0,
        "dispenser_status_l2": 0,
      };

      final mqttPayload = {
        "m2m:rqp": {
          "fr": _accessKey,
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName/la",
          "op": 1,
          "rqi": _lastRequestId,
          "pc": {
            "m2m:cin": {"cnf": "message", "con": jsonEncode(contentPayload)},
          },
          "ty": 4,
        },
      };

      final builder = MqttClientPayloadBuilder();
      builder.addString(jsonEncode(mqttPayload));

      logger.info('Publishing auto mode switch to topic: $_requestTopic');
      logger.fine('Auto Mode MQTT Payload: ${jsonEncode(mqttPayload)}');

      client?.publishMessage(
        _requestTopic,
        MqttQos.atLeastOnce,
        builder.payload!,
      );

      logger.info('Auto mode switch command sent successfully');

      // Clear manual settings
      await _clearManualSettings();

      // Wait a moment for the command to be processed
      await Future.delayed(const Duration(seconds: 2));

      if (mounted && !_isDisposed) {
        setState(() {
          _isSwitchingToAuto = false;
        });

        _updateFeedback('Berhasil beralih ke mode otomatis', Colors.green);
        _showFeedbackSnackBar(
          'Berhasil beralih ke mode otomatis',
          Colors.green,
          duration: const Duration(seconds: 3),
        );

        // Navigate back to previous screen after a short delay
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) {
            Navigator.of(
              context,
            ).pop(true); // Return true to indicate auto mode switch
          }
        });
      }
    } catch (e, s) {
      logger.severe('Failed to switch to auto mode: $e\n$s');

      if (mounted && !_isDisposed) {
        setState(() {
          _isSwitchingToAuto = false;
        });
      }

      _updateFeedback('Gagal beralih ke mode otomatis', Colors.red);
      _showFeedbackSnackBar(
        'Gagal beralih ke mode otomatis: ${e.toString()}',
        Colors.red,
        duration: const Duration(seconds: 5),
      );
    }
  }

  Future<void> _sendResetEspCommand() async {
    if (!_isMqttConnected) {
      _showFeedbackSnackBar(
        'Koneksi Gagal. Tidak dapat mengirim perintah reset.',
        Colors.red,
      );
      return;
    }

    _updateFeedback(
      'Mengirim perintah reset...',
      Colors.blue,
      showProgress: true,
    );

    try {
      final contentPayload = {
        "source": "flutter_app",
        "reset_command": 1, // Kunci ini harus dikenali oleh firmware ESP Anda
      };
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

      logger.info('Perintah reset ESP berhasil dikirim.');
      _updateFeedback('', Colors.transparent);
      _showFeedbackSnackBar(
        'Perintah restart ESP berhasil dikirim ke perangkat.',
        Colors.green,
      );
    } catch (e, s) {
      logger.severe('Gagal mengirim perintah reset ESP: $e\n$s');
      _updateFeedback('Gagal mengirim perintah reset', Colors.red);
      _showFeedbackSnackBar(
        'Gagal mengirim perintah reset: ${e.toString()}',
        Colors.red,
        duration: const Duration(seconds: 4),
      );
    }
  }

  void _showResetConfirmationDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Konfirmasi Restart Perangkat'),
          content: const Text(
            'Apakah Anda yakin ingin merestart perangkat ESP? Tindakan ini akan memulai ulang perangkat dan koneksi mungkin terputus sesaat.',
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
                _sendResetEspCommand(); // Panggil fungsi pengiriman
              },
            ),
          ],
        );
      },
    );
  }

  // --- UI Helper Methods ---

  Widget _buildConnectionStatus() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isMqttConnected ? Colors.green.shade50 : Colors.red.shade50,
        border: Border.all(
          color: _isMqttConnected ? Colors.green : Colors.red,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            // _isMqttConnected ? Icons.cloud_done : Icons.cloud_off,
            color: _isMqttConnected ? Colors.green : Colors.red,
            size: 12,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isMqttConnected ? 'Online' : 'Offline',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color:
                        _isMqttConnected
                            ? Colors.green.shade700
                            : Colors.red.shade700,
                  ),
                ),
                if (_feedbackMessage.isNotEmpty)
                  Text(
                    _feedbackMessage,
                    style: TextStyle(fontSize: 12, color: _feedbackColor),
                  ),
              ],
            ),
          ),
          if (_showProgressIndicator)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(_feedbackColor),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kontrol Manual'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            // Tanyakan konfirmasi jika ada perubahan yang belum disimpan
            if (_hasUnsavedChanges) {
              _showExitConfirmationDialog();
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Connection Status & Feedback
              _buildConnectionStatus(),

              // Floor 1 Controls
              _buildFloorControlSection(
                'Lantai 1',
                systemActiveL1,
                fanStatusL1,
                lampStatusL1,
                acStatusL1,
                dispenserStatusL1,
                (value) {
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
                (value) => setState(() {
                  fanStatusL1 = value;
                  _handleStateChange();
                }),
                (value) => setState(() {
                  lampStatusL1 = value;
                  _handleStateChange();
                }),
                (value) => setState(() {
                  acStatusL1 = value;
                  _handleStateChange();
                }),
                (value) => setState(() {
                  dispenserStatusL1 = value;
                  _handleStateChange();
                }),
              ),

              // Floor 2 Controls
              _buildFloorControlSection(
                'Lantai 2',
                systemActiveL2,
                fanStatusL2,
                lampStatusL2,
                acStatusL2,
                dispenserStatusL2,
                (value) {
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
                (value) => setState(() {
                  fanStatusL2 = value;
                  _handleStateChange();
                }),
                (value) => setState(() {
                  lampStatusL2 = value;
                  _handleStateChange();
                }),
                (value) => setState(() {
                  acStatusL2 = value;
                  _handleStateChange();
                }),
                (value) => setState(() {
                  dispenserStatusL2 = value;
                  _handleStateChange();
                }),
              ),

              // Action Buttons
              _buildActionButtons(),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  // Widget untuk tombol Aksi (Terapkan dan Beralih ke Otomatis)
  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('Simpan Pengaturan'),
            onPressed: _hasUnsavedChanges ? _saveSettingsToPreferences : null,

            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 12),

          ElevatedButton.icon(
            icon:
                _isApplyingChanges
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                    : const Icon(Icons.send), // Icon lebih sesuai
            label: const Text('Terapkan Perubahan'),
            onPressed:
                _isApplyingChanges || !_hasStateChanged()
                    ? null
                    : updateDeviceStatus,
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  _hasStateChanged()
                      ? Theme.of(context).primaryColor
                      : Colors.grey,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon:
                _isSwitchingToAuto
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.autorenew),
            label: const Text('Kembali ke Mode Otomatis'),
            onPressed: _isSwitchingToAuto ? null : switchToAutoMode,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),

          // --- TAMBAHAN: Tombol Reset ESP ---
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.restart_alt),
            label: const Text('Restart Perangkat ESP'),
            onPressed:
                _showResetConfirmationDialog, // Panggil dialog konfirmasi
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: const BorderSide(color: Colors.red),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          // --- AKHIR TAMBAHAN ---
        ],
      ),
    );
  }

  // Dialog konfirmasi saat keluar dengan perubahan yang belum disimpan
  Future<void> _showExitConfirmationDialog() async {
    final bool? shouldExit = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Perubahan Belum Disimpan'),
            content: const Text(
              'Anda memiliki perubahan yang belum diterapkan. Apakah Anda yakin ingin keluar?',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Batal'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Ya, Keluar'),
              ),
            ],
          ),
    );
    if (shouldExit == true) {
      Navigator.of(context).pop();
    }
  }

  Widget _buildFloorControlSection(
    String floorTitle,
    bool systemActive,
    bool fanStatus,
    bool lampStatus,
    bool acStatus,
    bool dispenserStatus,
    Function(bool) onSystemActiveChanged,
    Function(bool) onFanChanged,
    Function(bool) onLampChanged,
    Function(bool) onAcChanged,
    Function(bool) onDispenserChanged,
  ) {
    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              floorTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // System Active Toggle
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    systemActive ? Colors.green.shade50 : Colors.grey.shade50,
                border: Border.all(
                  color: systemActive ? Colors.green : Colors.grey,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    systemActive ? Icons.power : Icons.power_off,
                    color: systemActive ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Sistem ${systemActive ? 'Aktif' : 'Nonaktif'}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color:
                            systemActive
                                ? Colors.green.shade700
                                : Colors.grey.shade700,
                      ),
                    ),
                  ),
                  Switch(
                    value: systemActive,
                    onChanged: onSystemActiveChanged,
                    activeColor: Colors.green,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Device Controls
            Opacity(
              opacity: systemActive ? 1.0 : 0.5,
              child: Column(
                children: [
                  _buildDeviceControl(
                    'Kipas',
                    Icons.air,
                    fanStatus,
                    systemActive ? onFanChanged : null,
                  ),
                  _buildDeviceControl(
                    'Lampu',
                    Icons.lightbulb,
                    lampStatus,
                    systemActive ? onLampChanged : null,
                  ),
                  _buildDeviceControl(
                    'AC',
                    Icons.ac_unit,
                    acStatus,
                    systemActive ? onAcChanged : null,
                  ),
                  _buildDeviceControl(
                    'Dispenser',
                    Icons.local_drink,
                    dispenserStatus,
                    systemActive ? onDispenserChanged : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceControl(
    String deviceName,
    IconData icon,
    bool status,
    Function(bool)? onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: status ? Colors.blue.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: status ? Colors.blue.shade200 : Colors.grey.shade300,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: status ? Colors.blue : Colors.grey),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              deviceName,
              style: TextStyle(
                color: status ? Colors.blue.shade700 : Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Switch(value: status, onChanged: onChanged, activeColor: Colors.blue),
        ],
      ),
    );
  }
}
