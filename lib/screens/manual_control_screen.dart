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
  bool fanStatusL1 = false;
  bool lampStatusL1 = false;
  bool acStatusL1 = false;
  bool dispenserStatusL1 = false;
  bool systemActiveL1 = false;
  // Floor 2
  bool fanStatusL2 = false;
  bool lampStatusL2 = false;
  bool acStatusL2 = false;
  bool dispenserStatusL2 = false;
  bool systemActiveL2 = false;

  // --- State Tracking for Unsaved Changes ---
  // Floor 1
  bool _lastFanStatusL1 = false;
  bool _lastLampStatusL1 = false;
  bool _lastAcStatusL1 = false;
  bool _lastDispenserStatusL1 = false;
  bool _lastSystemActiveL1 = false;
  // Floor 2
  bool _lastFanStatusL2 = false;
  bool _lastLampStatusL2 = false;
  bool _lastAcStatusL2 = false;
  bool _lastDispenserStatusL2 = false;
  bool _lastSystemActiveL2 = false;

  bool _hasUnsavedChanges = false;
  bool _isDisposed = false;
  bool _isApplyingChanges = false;
  bool _isSwitchingToAuto = false;
  bool _isMqttConnected = false;
  String? _lastRequestId;
  Timer? _changeDebounceTimer;

  final Map<String, bool> _deviceStatusConfirmed = {};
  final Map<String, String> _deviceFeedbackMessages = {};
  String _feedbackMessage = '';
  Color _feedbackColor = Colors.blue;
  bool _showProgressIndicator = false;

  final logger = Logger('ManualControlScreen');
  static const Duration _confirmationTimeoutDuration = Duration(seconds: 15);
  Timer? _confirmationTimeoutTimer;

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
    // --- [DIUBAH] Inisialisasi sinkron terlebih dahulu ---
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

    // Simpan state awal untuk tracking perubahan
    _updateLastKnownState();

    // --- [DIUBAH] Panggil fungsi async untuk memuat data dari memori ---
    // Fungsi ini akan mengupdate state jika ada data tersimpan.
    _loadSavedSettings();

    // Panggilan lain tetap sama
    _setupLogging();
    _connectMqtt();
  }

  Future<void> _loadSavedSettings() async {
    // Fungsi ini sekarang hanya bertugas memuat dan menerapkan
    // pengaturan yang tersimpan, tidak melakukan inisialisasi awal.
    final prefs = await SharedPreferences.getInstance();
    if (!_isDisposed && mounted) {
      final hasManualSettings = prefs.getBool(_keyHasManualSettings) ?? false;

      if (hasManualSettings) {
        setState(() {
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

          // Setelah memuat, update lagi state terakhir agar tidak dianggap 'unsaved'
          _updateLastKnownState();
        });
      }
    }
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
    // Reset status perubahan jika state awal sama dengan yang dimuat
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
    } else {
      if (mounted) {
        setState(() {
          _hasUnsavedChanges = false;
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

  void _updateDeviceFeedback(String deviceKey, String message, bool confirmed) {
    if (mounted && !_isDisposed) {
      setState(() {
        _deviceFeedbackMessages[deviceKey] = message;
        _deviceStatusConfirmed[deviceKey] = confirmed;
      });
    }
  }

  void _showFeedbackSnackBar(
    String message,
    Color backgroundColor, {
    Duration? duration,
    bool showAction = false,
    VoidCallback? actionCallback,
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
          duration: duration ?? const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          action:
              showAction
                  ? SnackBarAction(
                    label: 'Detail',
                    textColor: Colors.white,
                    onPressed: actionCallback ?? () {},
                  )
                  : null,
        ),
      );
    }
  }

  void _showDetailedStatusDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Status Detail Perangkat'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ..._deviceFeedbackMessages.entries.map(
                    (entry) => ListTile(
                      leading: Icon(
                        _deviceStatusConfirmed[entry.key] == true
                            ? Icons.check_circle
                            : Icons.pending,
                        color:
                            _deviceStatusConfirmed[entry.key] == true
                                ? Colors.green
                                : Colors.orange,
                      ),
                      title: Text(_getFriendlyDeviceName(entry.key)),
                      subtitle: Text(entry.value),
                      dense: true,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Tutup'),
              ),
            ],
          ),
    );
  }

  String _getFriendlyDeviceName(String deviceKey) {
    final Map<String, String> deviceNames = {
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
    return deviceNames[deviceKey] ?? deviceKey;
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
        .withWillQos(MqttQos.atLeastOnce);
    client!.connectionMessage = connMessage;
    try {
      logger.info('MQTT: Attempting connection to $_mqttBroker...');
      await client!.connect(); // Antares needs username/password
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

  void _processDeviceData(String payload) async {
    if (!_isApplyingChanges) {
      logger.info("Ignoring incoming data as we are not applying changes.");
      return;
    }

    logger.info("--- Processing Confirmation Message from Device ---");
    logger.fine("Raw Payload: $payload");

    try {
      final notification = jsonDecode(payload);
      final cin = notification['m2m:sgn']?['nev']?['rep']?['m2m:cin'];
      if (cin == null) {
        logger.warning("Invalid payload structure, 'm2m:cin' not found.");
        return;
      }

      final String? contentString = cin['con'];
      if (contentString == null || contentString.isEmpty) {
        logger.warning("Payload 'cin' has no content ('con').");
        return;
      }

      final Map<String, dynamic> deviceState = jsonDecode(contentString);
      logger.info("Received Device Status Data: $deviceState");

      if (deviceState['source'] != 'device') {
        logger.info(
          "Message received, but not from 'device'. Ignoring as confirmation.",
        );
        return;
      }

      logger.info("VALID CONFIRMATION RECEIVED. Processing final status.");
      _confirmationTimeoutTimer?.cancel();

      _deviceFeedbackMessages.clear();
      _deviceStatusConfirmed.clear();

      final Map<String, dynamic> expectedValues = {
        'system_active_l1': systemActiveL1 ? 1 : 0,
        'fan_status_l1': fanStatusL1 ? 1 : 0,
        'lamp_status_l1': lampStatusL1 ? 1 : 0,
        'ac_status_l1': acStatusL1 ? 1 : 0,
        'dispenser_status_l1': dispenserStatusL1 ? 1 : 0,
        'system_active_l2': systemActiveL2 ? 1 : 0,
        'fan_status_l2': fanStatusL2 ? 1 : 0,
        'lamp_status_l2': lampStatusL2 ? 1 : 0,
        'ac_status_l2': acStatusL2 ? 1 : 0,
        'dispenser_status_l2': dispenserStatusL2 ? 1 : 0,
      };

      List<String> successDevices = [];
      List<String> failedDevices = [];

      expectedValues.forEach((deviceKey, expectedValue) {
        final actualValue = deviceState[deviceKey] ?? 0;
        final deviceName = _getFriendlyDeviceName(deviceKey);
        final isOn = actualValue == 1;
        final expectedOn = expectedValue == 1;

        if (actualValue == expectedValue) {
          successDevices.add(deviceName);
          _updateDeviceFeedback(
            deviceKey,
            isOn ? 'Berhasil dinyalakan' : 'Berhasil dimatikan',
            true,
          );
        } else {
          failedDevices.add(deviceName);
          _updateDeviceFeedback(
            deviceKey,
            'Gagal ${expectedOn ? 'menyalakan' : 'mematikan'} (status: ${isOn ? 'hidup' : 'mati'})',
            false,
          );
        }
      });

      setState(() {
        systemActiveL1 = (deviceState['system_active_l1'] ?? 0) == 1;
        fanStatusL1 = (deviceState['fan_status_l1'] ?? 0) == 1;
        lampStatusL1 = (deviceState['lamp_status_l1'] ?? 0) == 1;
        acStatusL1 = (deviceState['ac_status_l1'] ?? 0) == 1;
        dispenserStatusL1 = (deviceState['dispenser_status_l1'] ?? 0) == 1;

        systemActiveL2 = (deviceState['system_active_l2'] ?? 0) == 1;
        fanStatusL2 = (deviceState['fan_status_l2'] ?? 0) == 1;
        lampStatusL2 = (deviceState['lamp_status_l2'] ?? 0) == 1;
        acStatusL2 = (deviceState['ac_status_l2'] ?? 0) == 1;
        dispenserStatusL2 = (deviceState['dispenser_status_l2'] ?? 0) == 1;

        _isApplyingChanges = false;
      });

      _updateLastKnownState();
      await _saveSettingsToPreferences();

      if (failedDevices.isEmpty) {
        _updateFeedback('Semua perubahan berhasil diterapkan!', Colors.green);
        _showFeedbackSnackBar(
          'Berhasil memperbarui ${successDevices.length} perangkat!',
          Colors.green,
          duration: const Duration(seconds: 4),
          showAction: true,
          actionCallback: _showDetailedStatusDialog,
        );
      } else {
        _updateFeedback(
          '${successDevices.length} berhasil, ${failedDevices.length} gagal',
          Colors.orange,
        );
        _showFeedbackSnackBar(
          'Sebagian berhasil: ${successDevices.length} berhasil, ${failedDevices.length} gagal',
          Colors.orange,
          duration: const Duration(seconds: 5),
          showAction: true,
          actionCallback: _showDetailedStatusDialog,
        );
      }
    } catch (e, s) {
      logger.severe('Failed to process device data: $e\n$s');
      _updateFeedback('Error memproses data konfirmasi', Colors.red);
      setState(() {
        _isApplyingChanges = false;
      });
    }
  }

  void _startConfirmationTimeout() {
    _confirmationTimeoutTimer?.cancel();
    _confirmationTimeoutTimer = Timer(_confirmationTimeoutDuration, () {
      if (_isApplyingChanges && mounted) {
        logger.warning('Confirmation timeout! No response from device.');

        _updateFeedback('Timeout: Perangkat tidak merespons', Colors.red);
        _showFeedbackSnackBar(
          'Timeout: Tidak ada konfirmasi dari perangkat dalam 15 detik. Periksa koneksi perangkat.',
          Colors.red,
          duration: const Duration(seconds: 6),
        );

        if (mounted && !_isDisposed) {
          setState(() {
            _isApplyingChanges = false;
          });
        }
      }
    });
  }

  // --- Core Logic for Sending Data ---
  Future<void> updateDeviceStatus() async {
    if (_isApplyingChanges || _isSwitchingToAuto) return;
    if (!_hasStateChanged()) {
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
    _deviceFeedbackMessages.clear();
    _deviceStatusConfirmed.clear();

    // Hitung jumlah perubahan untuk feedback yang lebih baik
    int changeCount = 0;
    if (systemActiveL1 != _lastSystemActiveL1) changeCount++;
    if (fanStatusL1 != _lastFanStatusL1) changeCount++;
    if (lampStatusL1 != _lastLampStatusL1) changeCount++;
    if (acStatusL1 != _lastAcStatusL1) changeCount++;
    if (dispenserStatusL1 != _lastDispenserStatusL1) changeCount++;
    if (systemActiveL2 != _lastSystemActiveL2) changeCount++;
    if (fanStatusL2 != _lastFanStatusL2) changeCount++;
    if (lampStatusL2 != _lastLampStatusL2) changeCount++;
    if (acStatusL2 != _lastAcStatusL2) changeCount++;
    if (dispenserStatusL2 != _lastDispenserStatusL2) changeCount++;

    // Set state untuk memulai proses pengiriman
    if (mounted) {
      setState(() {
        _isApplyingChanges = true;
        _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
      });
    }

    _updateFeedback(
      'Menerapkan $changeCount perubahan...',
      Colors.blue,
      showProgress: true,
    );
    _showFeedbackSnackBar('Mengirim perubahan ke perangkat...', Colors.blue);

    // Mulai timer timeout untuk menunggu konfirmasi dari perangkat
    _startConfirmationTimeout();

    try {
      // 1. Siapkan payload konten dengan status semua perangkat
      final contentPayload = {
        "source": "flutter_app",
        "control_command": "1", // 1 untuk mode kontrol manual
        "manual_control": 1,
        // Lantai 1 (konversi boolean ke integer 0 atau 1)
        "system_active_l1": systemActiveL1 ? 1 : 0,
        "fan_status_l1": fanStatusL1 ? 1 : 0,
        "lamp_status_l1": lampStatusL1 ? 1 : 0,
        "ac_status_l1": acStatusL1 ? 1 : 0,
        "dispenser_status_l1": dispenserStatusL1 ? 1 : 0,
        // Lantai 2
        "system_active_l2": systemActiveL2 ? 1 : 0,
        "fan_status_l2": fanStatusL2 ? 1 : 0,
        "lamp_status_l2": lampStatusL2 ? 1 : 0,
        "ac_status_l2": acStatusL2 ? 1 : 0,
        "dispenser_status_l2": dispenserStatusL2 ? 1 : 0,
      };

      // 2. Bungkus payload konten ke dalam format request Antares (m2m:rqp)
      final mqttPayload = {
        "m2m:rqp": {
          "fr": _accessKey,
          "to":
              "/antares-cse/antares-id/$_projectName/$_deviceName", // Kirim ke device
          "op": 1, // Create
          "rqi": _lastRequestId,
          "pc": {
            "m2m:cin": {
              "cnf": "text/plain:0",
              "con": jsonEncode(contentPayload),
            },
          },
          "ty": 4, // ContentInstance
        },
      };

      // 3. Kirim payload melalui MQTT
      final builder = MqttClientPayloadBuilder();
      builder.addString(jsonEncode(mqttPayload));

      logger.info('Publishing manual control update to topic: $_requestTopic');
      logger.fine('Manual Control MQTT Payload: ${jsonEncode(mqttPayload)}');

      client?.publishMessage(
        _requestTopic,
        MqttQos.atLeastOnce,
        builder.payload!,
      );

      logger.info(
        'Perintah kontrol manual terkirim. Menunggu konfirmasi perangkat...',
      );
    } catch (e, s) {
      logger.severe('Gagal mengirim pembaruan status perangkat: $e\n$s');
      _confirmationTimeoutTimer?.cancel(); // Hentikan timer jika terjadi error
      if (mounted && !_isDisposed) {
        setState(() {
          _isApplyingChanges = false;
        });
      }
      _updateFeedback('Gagal mengirim perintah', Colors.red);
      _showFeedbackSnackBar(
        'Gagal mengirim perubahan: ${e.toString()}',
        Colors.red,
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
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName",
          "op": 1,
          "rqi": _lastRequestId,
          "pc": {
            "m2m:cin": {
              "cnf": "text/plain:0",
              "con": jsonEncode(contentPayload),
            },
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

  // --- [BARU] --- Fungsi untuk mengirim perintah reset occupancy
  Future<void> _sendResetOccupancyCommand() async {
    if (!_isMqttConnected) {
      _showFeedbackSnackBar(
        'Koneksi Gagal. Tidak dapat mengirim perintah reset.',
        Colors.red,
      );
      return;
    }

    _updateFeedback(
      'Mengirim perintah reset occupancy...',
      Colors.blue,
      showProgress: true,
    );

    try {
      // Sesuai dengan kode ESP, payload-nya adalah {"resetOccupancy": 1}
      final contentPayload = {
        "source": "flutter_app",
        "resetOccupancy": 1, // Kunci ini harus dikenali oleh firmware ESP Anda
      };
      final requestId = 'reset_occ_${DateTime.now().millisecondsSinceEpoch}';

      final mqttPayload = {
        "m2m:rqp": {
          "fr": _accessKey,
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName",
          "op": 1,
          "rqi": requestId,
          "pc": {
            "m2m:cin": {
              "cnf": "text/plain:0",
              "con": jsonEncode(contentPayload),
            },
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

      logger.info('Perintah reset occupancy berhasil dikirim.');
      _updateFeedback('', Colors.transparent);
      _showFeedbackSnackBar(
        'Perintah reset occupancy berhasil dikirim ke perangkat.',
        Colors.green,
      );
    } catch (e, s) {
      logger.severe('Gagal mengirim perintah reset occupancy: $e\n$s');
      _updateFeedback('Gagal mengirim perintah reset', Colors.red);
      _showFeedbackSnackBar(
        'Gagal mengirim perintah reset: ${e.toString()}',
        Colors.red,
        duration: const Duration(seconds: 4),
      );
    }
  }

  // --- [BARU] --- Dialog konfirmasi untuk reset occupancy
  void _showResetOccupancyConfirmationDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Konfirmasi Reset Occupancy'),
          content: const Text(
            'Apakah Anda yakin ingin mereset data jumlah orang (occupancy) di kedua lantai ke nol? Tindakan ini tidak dapat dibatalkan.',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Batal'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.orange),
              child: const Text('Ya, Reset'),
              onPressed: () {
                Navigator.of(context).pop();
                _sendResetOccupancyCommand(); // Panggil fungsi yang baru dibuat
              },
            ),
          ],
        );
      },
    );
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
          "to": "/antares-cse/antares-id/$_projectName/$_deviceName",
          "op": 1,
          "rqi": requestId,
          "pc": {
            "m2m:cin": {
              "cnf": "text/plain:0",
              "con": jsonEncode(contentPayload),
            },
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
                _sendResetEspCommand();
              },
            ),
          ],
        );
      },
    );
  }

  // --- UI Helper Methods ---
  void _showUsageInstructionsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.info_outline, color: Colors.indigo),
              SizedBox(width: 10),
              Text('Petunjuk Penggunaan'),
            ],
          ),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                _buildInstructionStep(
                  '1',
                  'Ubah Status Perangkat',
                  'Gunakan saklar (toggle) untuk mengaktifkan atau menonaktifkan setiap perangkat seperti Kipas, Lampu, AC, dan lainnya.',
                ),
                _buildInstructionStep(
                  '2',
                  'Terapkan Perubahan',
                  'Setelah selesai mengatur, tekan tombol "Terapkan Perubahan". Tombol ini akan mengirimkan semua pengaturan Anda ke perangkat fisik (ESP).',
                ),
                _buildInstructionStep(
                  '3',
                  'Simpan Pengaturan (Opsional)',
                  'Tombol "Simpan Pengaturan" akan menyimpan status saklar saat ini di memori HP. Jadi, saat Anda membuka halaman ini lagi, pengaturannya akan sama seperti yang terakhir disimpan.',
                ),
                _buildInstructionStep(
                  '4',
                  'Kembali ke Mode Otomatis',
                  'Gunakan tombol ini untuk mengembalikan sistem ke kontrol otomatis. Semua pengaturan manual akan dinonaktifkan.',
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Mengerti'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildInstructionStep(
    String stepNumber,
    String title,
    String description,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Colors.indigo,
            child: Text(
              stepNumber,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
    return WillPopScope(
      onWillPop: () async {
        if (_hasUnsavedChanges) {
          _showExitConfirmationDialog();
          return false; // Mencegah pop otomatis
        }
        return true; // Izinkan pop
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Kontrol Manual'),
          backgroundColor: Colors.indigo.shade400,
          foregroundColor: Colors.grey.shade50,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (_hasUnsavedChanges) {
                _showExitConfirmationDialog();
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.help_outline),
              tooltip: 'Petunjuk Penggunaan',
              onPressed: _showUsageInstructionsDialog,
            ),
          ],
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.indigo.shade400, Colors.grey.shade50],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildConnectionStatus(),
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
                  _buildActionButtons(),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- [MODIFIKASI] --- Widget ini diubah untuk menampung dua tombol reset
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
                    : const Icon(Icons.send),
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
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          // --- [MODIFIKASI] --- Menggunakan Row untuk dua tombol
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.replay_circle_filled_outlined),
                  label: const Text('Reset Occupancy'),
                  onPressed: _showResetOccupancyConfirmationDialog,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange.shade700,
                    side: BorderSide(color: Colors.orange.shade700),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Restart ESP'),
                  onPressed: _showResetConfirmationDialog,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showExitConfirmationDialog() async {
    final bool? shouldExit = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Perubahan Belum Disimpan'),
            content: const Text(
              'Anda memiliki perubahan yang belum diterapkan atau disimpan. Apakah Anda yakin ingin keluar?',
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
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              floorTitle,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    systemActive ? Colors.green.shade50 : Colors.grey.shade200,
                border: Border.all(
                  color: systemActive ? Colors.green : Colors.grey,
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    systemActive ? Icons.power : Icons.power_off,
                    color: systemActive ? Colors.green : Colors.grey.shade700,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Sistem ${systemActive ? 'Aktif' : 'Nonaktif'}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color:
                            systemActive
                                ? Colors.green.shade800
                                : Colors.grey.shade800,
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
            Opacity(
              opacity: systemActive ? 1.0 : 0.5,
              child: AbsorbPointer(
                absorbing: !systemActive,
                child: Column(
                  children: [
                    _buildDeviceControl(
                      'Kipas',
                      Icons.air,
                      fanStatus,
                      onFanChanged,
                    ),
                    _buildDeviceControl(
                      'Lampu',
                      Icons.lightbulb_outline,
                      lampStatus,
                      onLampChanged,
                    ),
                    _buildDeviceControl(
                      'AC',
                      Icons.ac_unit,
                      acStatus,
                      onAcChanged,
                    ),
                    _buildDeviceControl(
                      'Dispenser',
                      Icons.local_drink,
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

  Widget _buildDeviceControl(
    String deviceName,
    IconData icon,
    bool status,
    Function(bool)? onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: status ? Colors.blue.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: status ? Colors.blue.shade200 : Colors.grey.shade300,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: status ? Colors.blue : Colors.grey.shade600),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              deviceName,
              style: TextStyle(
                color: status ? Colors.blue.shade800 : Colors.grey.shade700,
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
