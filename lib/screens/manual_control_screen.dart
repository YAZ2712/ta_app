import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ManualControlScreen extends StatefulWidget {
  final bool initialFanStatus;
  final bool initialLampStatus;
  final bool initialAcStatus;
  final bool initialDispenserStatus;
  final bool systemActive;

  const ManualControlScreen({
    super.key,
    this.initialFanStatus = false,
    this.initialLampStatus = false,
    this.initialAcStatus = false,
    this.initialDispenserStatus = false,
    this.systemActive = false,
  });

  @override
  State<ManualControlScreen> createState() => _ManualControlScreenState();
}

class _ManualControlScreenState extends State<ManualControlScreen> {
  bool fanStatus = false;
  bool lampStatus = false;
  bool acStatus = false;
  bool dispenserStatus = false;
  bool _isDisposed = false;
  bool isSystemActive = false;
  bool _isApplyingChanges = false;
  bool _isSwitchingToAuto = false;
  bool _isMqttConnected = false;
  bool _waitingForConfirmation = false;
  String? _lastRequestId;
  final logger = Logger('ManualControlScreen');

  // State tracking untuk deteksi perubahan
  bool _lastFanStatus = false;
  bool _lastLampStatus = false;
  bool _lastAcStatus = false;
  bool _lastDispenserStatus = false;
  bool _lastSystemActive = false;
  bool _hasUnsavedChanges = false;

  // Timer untuk debouncing
  Timer? _changeDebounceTimer;
  static const Duration _debounceDelay = Duration(seconds: 2);

  // SharedPreferences keys
  static const String _keyFanStatus = 'manual_fan_status';
  static const String _keyLampStatus = 'manual_lamp_status';
  static const String _keyAcStatus = 'manual_ac_status';
  static const String _keyDispenserStatus = 'manual_dispenser_status';
  static const String _keySystemActive = 'manual_system_active';
  static const String _keyHasManualSettings = 'has_manual_settings';

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
      '/oneM2M/resp/fe5c7a15d8c13220:bfd764392a99a094antares-cse/json';
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

    if (hasManualSettings) {
      if (mounted && !_isDisposed) {
        setState(() {
          fanStatus = prefs.getBool(_keyFanStatus) ?? widget.initialFanStatus;
          lampStatus =
              prefs.getBool(_keyLampStatus) ?? widget.initialLampStatus;
          acStatus = prefs.getBool(_keyAcStatus) ?? widget.initialAcStatus;
          dispenserStatus =
              prefs.getBool(_keyDispenserStatus) ??
              widget.initialDispenserStatus;
          isSystemActive =
              prefs.getBool(_keySystemActive) ?? widget.systemActive;
        });
      }
    } else {
      setState(() {
        fanStatus = widget.initialFanStatus;
        lampStatus = widget.initialLampStatus;
        acStatus = widget.initialAcStatus;
        dispenserStatus = widget.initialDispenserStatus;
        isSystemActive = widget.systemActive;
      });
    }

    // Simpan state awal untuk tracking perubahan
    _updateLastKnownState();
  }

  // Update state terakhir yang diketahui
  void _updateLastKnownState() {
    _lastFanStatus = fanStatus;
    _lastLampStatus = lampStatus;
    _lastAcStatus = acStatus;
    _lastDispenserStatus = dispenserStatus;
    _lastSystemActive = isSystemActive;
    _hasUnsavedChanges = false;
  }

  // Cek apakah ada perubahan dari state terakhir
  bool _hasStateChanged() {
    return fanStatus != _lastFanStatus ||
        lampStatus != _lastLampStatus ||
        acStatus != _lastAcStatus ||
        dispenserStatus != _lastDispenserStatus ||
        isSystemActive != _lastSystemActive;
  }

  // Handle perubahan dengan debouncing
  void _handleStateChange() {
    if (_hasStateChanged()) {
      _hasUnsavedChanges = true;

      // Cancel timer sebelumnya jika ada
      _changeDebounceTimer?.cancel();

      // Set timer baru untuk auto-send setelah delay
      _changeDebounceTimer = Timer(_debounceDelay, () {
        if (_hasUnsavedChanges && _hasStateChanged() && isSystemActive) {
          logger.info('Auto-sending changes after debounce delay');
          updateDeviceStatus();
        }
      });

      // Update UI untuk menunjukkan ada perubahan yang belum disimpan
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _saveStatusToPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyFanStatus, fanStatus);
    await prefs.setBool(_keyLampStatus, lampStatus);
    await prefs.setBool(_keyAcStatus, acStatus);
    await prefs.setBool(_keyDispenserStatus, dispenserStatus);
    await prefs.setBool(_keySystemActive, isSystemActive);
    await prefs.setBool(_keyHasManualSettings, true);

    logger.info('Manual control settings saved to preferences');
  }

  Future<void> _clearManualSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFanStatus);
    await prefs.remove(_keyLampStatus);
    await prefs.remove(_keyAcStatus);
    await prefs.remove(_keyDispenserStatus);
    await prefs.remove(_keySystemActive);
    await prefs.setBool(_keyHasManualSettings, false);

    logger.info('Manual control settings cleared from preferences');
  }

  @override
  void dispose() {
    _isDisposed = true;
    _changeDebounceTimer?.cancel();
    logger.info("Disposing ManualControlScreen - Disconnecting MQTT");
    _disconnectMqtt();
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

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (mounted && !_isDisposed) {
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
            // Success - update last known state
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
      } else {
        logger.info("MQTT: Received data doesn't match known response format.");
      }
    } catch (e) {
      logger.severe('MQTT: Error processing MQTT data: $e\nPayload: $payload');
    }
  }

  Future<void> updateDeviceStatus() async {
    if (_isApplyingChanges || _isSwitchingToAuto) return;

    // Cek apakah ada perubahan yang perlu dikirim
    if (!_hasStateChanged()) {
      logger.info('No state changes detected, skipping update');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tidak ada perubahan untuk disimpan'),
          backgroundColor: Colors.blue,
        ),
      );
      return;
    }

    if (!_isMqttConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('MQTT Tidak Terhubung. Tidak dapat mengirim.'),
          backgroundColor: Colors.orange,
        ),
      );
      await _connectMqtt();
      if (!_isMqttConnected) {
        return;
      }
    }

    if (mounted && !_isDisposed) {
      setState(() {
        _isApplyingChanges = true;
        _waitingForConfirmation = true;
        _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
      });
    }

    // Cancel auto-send timer karena sedang manual send
    _changeDebounceTimer?.cancel();

    try {
      logger.info('Sending device status update - Changes detected');

      final contentPayload = {
        "source": "device",
        "control_command": "1",
        'Jumlah Orang Masuk': 0,
        'Jumlah Orang Keluar': 0,
        'manual_control': 1,
        'system_active': isSystemActive ? 1 : 0,
        'fan_status': fanStatus ? 1 : 0,
        'lamp_status': lampStatus ? 1 : 0,
        'ac_status': acStatus ? 1 : 0,
        'dispenser_status': dispenserStatus ? 1 : 0,
        'max_occupancy': 10,
      };

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
      await Future.delayed(const Duration(seconds: 3));

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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengirim via MQTT: $e'),
            backgroundColor: Colors.red,
          ),
        );
        _fallbackToHttpAutoUpdate();
      }
    } finally {
      if (mounted && !_isDisposed) {
        setState(() {
          _isApplyingChanges = false;
        });
      }
    }
  }

  Future<void> _fallbackToHttpAutoUpdate() async {
    try {
      logger.info('Attempting HTTP fallback method');
      final payload = {
        "source": "device",
        "control_command": "1",
        'fan_status': fanStatus,
        'lamp_status': lampStatus,
        'ac_status': acStatus,
        'dispenser_status': dispenserStatus,
        'system_active': isSystemActive,
        'manual_control': true,
        'Jumlah Orang Masuk': 0,
        'Jumlah Orang Keluar': 0,
      };

      final jsonPayload = jsonEncode({
        'm2m:cin': {'con': jsonEncode(payload)},
      });

      final response = await http
          .post(
            Uri.parse(
              'https://platform.antares.id:8443/~/antares-cse/antares-id/TADKT-1/PMM',
            ),
            headers: {
              'X-M2M-Origin': 'fe5c7a15d8c13220:bfd764392a99a094',
              'Content-Type': 'application/json;ty=4',
              'Accept': 'application/json',
            },
            body: jsonPayload,
          )
          .timeout(const Duration(seconds: 10));

      logger.info('HTTP Fallback response status code: ${response.statusCode}');

      if (response.statusCode == 201) {
        logger.info('Device status updated successfully via HTTP');
        _updateLastKnownState();
        await _saveStatusToPreferences();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kontrol berhasil diperbarui (via HTTP)'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        logger.severe(
          'Failed to update device status via HTTP: ${response.statusCode}',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Gagal memperbarui kontrol perangkat'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      logger.severe('Error updating device status via HTTP: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Terjadi kesalahan saat memperbarui status perangkat'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> switchToAutomaticMode() async {
    if (_isApplyingChanges || _isSwitchingToAuto) return;
    if (!_isMqttConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('MQTT Tidak Terhubung. Tidak dapat mengirim.'),
          backgroundColor: Colors.orange,
        ),
      );

      await _connectMqtt();
      if (!_isMqttConnected) {
        return;
      }
    }

    setState(() {
      _isSwitchingToAuto = true;
      _waitingForConfirmation = true;
      _lastRequestId = DateTime.now().millisecondsSinceEpoch.toString();
    });

    try {
      final contentPayload = {
        "source": "device",
        "control_command": "1",
        'Jumlah Orang Masuk': 0,
        'Jumlah Orang Keluar': 0,
        'manual_control': 0,
        'system_active': isSystemActive ? 1 : 0,
        'fan_status': fanStatus ? 1 : 0,
        'lamp_status': lampStatus ? 1 : 0,
        'ac_status': acStatus ? 1 : 0,
        'dispenser_status': dispenserStatus ? 1 : 0,
        'max_occupancy': 10,
      };

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
      logger.info(
        'MQTT: Publishing switch to auto mode to topic: $_requestTopic',
      );

      final builder = MqttClientPayloadBuilder();
      builder.addString(finalPayloadString);

      final payload = builder.payload;
      if (payload != null) {
        client?.publishMessage(
          _requestTopic,
          MqttQos.atLeastOnce,
          payload,
          retain: false,
        );
      } else {
        throw Exception('Failed to build MQTT payload');
      }

      await Future.delayed(const Duration(seconds: 3));
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
      } else {
        await _clearManualSettings();
        Navigator.of(context).pop();
      }
    } catch (e) {
      logger.severe('MQTT: Error switching to automatic mode: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengirim via MQTT: $e'),
            backgroundColor: Colors.red,
          ),
        );
        _fallbackToHttpAutoUpdate();
      }
    } finally {
      if (mounted && !_isDisposed) {
        setState(() {
          _isSwitchingToAuto = false;
        });
      }
    }
  }

  Widget buildControlRow(String title, bool value, Function(bool) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
          Switch(
            value: value,
            onChanged: (newValue) {
              onChanged(newValue);
              _handleStateChange(); // Trigger change detection
            },
            activeColor: Colors.blue,
          ),
        ],
      ),
    );
  }

  Widget buildDeviceControlSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kontrol Perangkat\nLantai 1',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 16),
            buildControlRow('Kipas', fanStatus, (value) {
              setState(() {
                fanStatus = value;
              });
            }),
            const Divider(),
            buildControlRow('Lampu', lampStatus, (value) {
              setState(() {
                lampStatus = value;
              });
            }),
            const Divider(),
            buildControlRow('AC', acStatus, (value) {
              setState(() {
                acStatus = value;
              });
            }),
            const Divider(),
            buildControlRow('Dispenser', dispenserStatus, (value) {
              setState(() {
                dispenserStatus = value;
              });
            }),
          ],
        ),
      ),
    );
  }

  Widget buildSystemControlSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kontrol Sistem',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Aktifkan Sistem',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                ),
                Switch(
                  value: isSystemActive,
                  onChanged: (value) {
                    if (mounted && !_isDisposed) {
                      setState(() {
                        isSystemActive = value;
                        if (!value) {
                          fanStatus = false;
                          lampStatus = false;
                          acStatus = false;
                          dispenserStatus = false;
                        }
                      });
                      _handleStateChange(); // Trigger change detection
                    }
                  },
                  activeColor: Colors.green,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isSystemActive
                  ? 'Sistem aktif - kontrol manual dapat digunakan'
                  : 'Sistem nonaktif - semua perangkat akan dimatikan',
              style: TextStyle(
                fontSize: 14,
                color: isSystemActive ? Colors.green[700] : Colors.red[700],
                fontStyle: FontStyle.italic,
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
            const Text('Kontrol Manual'),
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
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () {
              showDialog(
                context: context,
                builder:
                    (context) => AlertDialog(
                      title: const Text('Bantuan Kontrol Manual'),
                      content: const SingleChildScrollView(
                        child: ListBody(
                          children: [
                            Text(
                              'Pada halaman ini Anda dapat mengendalikan perangkat secara manual:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 12),
                            Text(
                              '1. Aktifkan "Sistem" untuk menggunakan kontrol manual.',
                            ),
                            Text(
                              '2. Gunakan tombol untuk menyalakan/mematikan setiap perangkat.',
                            ),
                            Text(
                              '3. Perubahan akan otomatis dikirim setelah 2 detik atau tekan "Terapkan Perubahan".',
                            ),
                            SizedBox(height: 12),
                            Text(
                              'Catatan: Data hanya akan dikirim jika ada perubahan pada kontrol perangkat untuk menghemat bandwidth.',
                              style: TextStyle(fontStyle: FontStyle.italic),
                            ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Mengerti'),
                        ),
                      ],
                    ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              buildSystemControlSection(),
              const SizedBox(height: 16),
              buildDeviceControlSection(),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed:
                    isSystemActive
                        ? (_isApplyingChanges ? null : updateDeviceStatus)
                        : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor:
                      _hasUnsavedChanges &&
                              _isMqttConnected &&
                              _hasStateChanged()
                          ? Colors.orange
                          : (_isMqttConnected ? Colors.blue : Colors.grey),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child:
                    _isApplyingChanges
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
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
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : const Text(
                          'Kembali ke Mode Otomatis',
                          style: TextStyle(fontSize: 16, color: Colors.white),
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
