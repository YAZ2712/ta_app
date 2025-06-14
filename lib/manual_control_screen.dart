import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:logging/logging.dart';

class ManualControlScreen extends StatefulWidget {
  final bool initialFanStatus;
  final bool initialLampStatus;
  final bool initialAcStatus;
  final bool initialDispenserStatus;
  final bool systemActive;

  // Add ESP8266 IP address configuration
  final String espIpAddress;

  const ManualControlScreen({
    super.key,
    this.initialFanStatus = false,
    this.initialLampStatus = false,
    this.initialAcStatus = false,
    this.initialDispenserStatus = false,
    this.systemActive = false,
    this.espIpAddress = '192.168.137.91', // Default empty, should be provided
  });

  @override
  State<ManualControlScreen> createState() => _ManualControlScreenState();
}

class _ManualControlScreenState extends State<ManualControlScreen> {
  late bool fanStatus;
  late bool lampStatus;
  late bool acStatus;
  late bool dispenserStatus;
  late bool isSystemActive;
  late String espIpAddress;
  bool isSending = false; // Flag for API request in progress
  final logger = Logger('ManualControlScreen');

  @override
  void initState() {
    super.initState();
    fanStatus = widget.initialFanStatus;
    lampStatus = widget.initialLampStatus;
    acStatus = widget.initialAcStatus;
    dispenserStatus = widget.initialDispenserStatus;
    isSystemActive = widget.systemActive;
    espIpAddress = widget.espIpAddress;
  }

  // Direct control of relay via ESP8266
  Future<void> _toggleRelay(String relay, bool newState) async {
    if (espIpAddress.isEmpty) {
      _showError('IP ESP8266 belum dikonfigurasi');
      return;
    }

    setState(() {
      isSending = true;
    });

    try {
      final String command = newState ? 'on' : 'off';
      final response = await http
          .get(Uri.parse('http://192.168.137.91/$relay/$command'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        logger.info('Relay toggled successfully: $relay to $command');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$relay ${newState ? 'dinyalakan' : 'dimatikan'}'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        _showError('Gagal mengendalikan relay: ${response.statusCode}');
      }
    } catch (e) {
      logger.severe('Error toggling relay: $e');
      _showError('Terjadi kesalahan koneksi ke ESP8266');
    } finally {
      if (mounted) {
        setState(() {
          isSending = false;
        });
      }
    }
  }

  // Also keep Antares integration as backup or for system-wide updates
  Future<void> updateDeviceStatus() async {
    if (isSending) return;

    setState(() {
      isSending = true;
    });

    try {
      // Create payload for Antares
      final payload = {
        'fan_status': fanStatus,
        'lamp_status': lampStatus,
        'ac_status': acStatus,
        'dispenser_status': dispenserStatus,
        'system_active': isSystemActive,
        'manual_control': true, // Flag to indicate manual control
      };

      // Convert payload to JSON string
      final jsonPayload = jsonEncode({
        'm2m:cin': {'con': jsonEncode(payload)},
      });

      // Send POST request to Antares
      final response = await http
          .post(
            Uri.parse(
              'https://platform.antares.id:8443/~/antares-cse/antares-id/TA-YAZ/COUNTER',
            ),
            headers: {
              'X-M2M-Origin': 'b1e8024f40e20d77:9f09d4019f441404',
              'Content-Type': 'application/json;ty=4',
              'Accept': 'application/json',
            },
            body: jsonPayload,
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        logger.info('Device status updated successfully on Antares');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Status perangkat diperbarui ke Antares'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        _showError(
          'Gagal memperbarui status ke Antares: ${response.statusCode}',
        );
      }
    } catch (e) {
      logger.severe('Error updating device status to Antares: $e');
      _showError('Terjadi kesalahan saat memperbarui status ke Antares');
    } finally {
      if (mounted) {
        setState(() {
          isSending = false;
        });
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  Widget buildRelayControlCard(
    String title,
    String relayId,
    bool status,
    IconData icon,
  ) {
    return Card(
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      icon,
                      size: 28,
                      color: status ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: status,
                  activeColor: Colors.blue,
                  onChanged:
                      isSystemActive
                          ? (value) {
                            setState(() {
                              // Update local state
                              switch (relayId) {
                                case 'relay1':
                                  fanStatus = value;
                                  break;
                                case 'relay2':
                                  lampStatus = value;
                                  break;
                                case 'relay3':
                                  acStatus = value;
                                  break;
                                case 'relay4':
                                  dispenserStatus = value;
                                  break;
                              }
                            });

                            // Control relay directly
                            _toggleRelay(relayId, value);
                          }
                          : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(
                color:
                    status
                        ? Colors.blue.withOpacity(0.1)
                        : Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                status ? 'Aktif' : 'Nonaktif',
                style: TextStyle(
                  color: status ? Colors.blue[700] : Colors.grey[700],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
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
                    setState(() {
                      isSystemActive = value;
                      // If system is being turned off, turn off all devices
                      if (!value) {
                        fanStatus = false;
                        lampStatus = false;
                        acStatus = false;
                        dispenserStatus = false;

                        // Turn off all relays
                        _toggleRelay('relay1', false);
                        _toggleRelay('relay2', false);
                        _toggleRelay('relay3', false);
                        _toggleRelay('relay4', false);
                      }
                    });

                    // Update to Antares
                    updateDeviceStatus();
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

  Widget buildIpConfigSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Konfigurasi ESP8266',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: TextEditingController(text: espIpAddress),
              decoration: const InputDecoration(
                labelText: 'IP Address ESP8266',
                hintText: 'contoh: 192.168.137.91',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.wifi),
              ),
              onChanged: (value) {
                setState(() {
                  espIpAddress = value;
                });
              },
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () async {
                try {
                  final response = await http
                      .get(Uri.parse('http://192.168.137.91/status'))
                      .timeout(const Duration(seconds: 5));

                  if (response.statusCode == 200) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Koneksi ke ESP8266 berhasil'),
                        backgroundColor: Colors.green,
                      ),
                    );

                    // Try to parse status if available
                    try {
                      final data = jsonDecode(response.body);
                      setState(() {
                        fanStatus = data['relay1'] == 1;
                        lampStatus = data['relay2'] == 1;
                        acStatus = data['relay3'] == 1;
                        dispenserStatus = data['relay4'] == 1;
                      });
                    } catch (e) {
                      logger.info('Could not parse relay state: $e');
                    }
                  } else {
                    _showError('Tidak dapat terhubung ke ESP8266');
                  }
                } catch (e) {
                  logger.severe('Error connecting to ESP8266: $e');
                  _showError('Gagal terhubung ke ESP8266: Pastikan IP benar');
                }
              },
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Periksa Koneksi'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
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
        title: const Text('Kontrol Relay Manual'),
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
                              'Pada halaman ini Anda dapat mengendalikan relay secara manual:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 12),
                            Text(
                              '1. Masukkan IP Address ESP8266 dan periksa koneksi',
                            ),
                            Text(
                              '2. Aktifkan "Sistem" untuk menggunakan kontrol manual',
                            ),
                            Text(
                              '3. Gunakan tombol untuk menyalakan/mematikan setiap relay',
                            ),
                            SizedBox(height: 12),
                            Text(
                              'Catatan: Perubahan akan langsung dikirim ke relay dan juga diperbarui ke Antares.',
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
              buildIpConfigSection(),
              const SizedBox(height: 16),
              buildSystemControlSection(),
              const SizedBox(height: 16),
              const Text(
                'Kontrol Relay',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              buildRelayControlCard(
                'Kipas Angin',
                'relay1',
                fanStatus,
                Icons.air,
              ),
              buildRelayControlCard(
                'Lampu',
                'relay2',
                lampStatus,
                Icons.lightbulb,
              ),
              buildRelayControlCard('AC', 'relay3', acStatus, Icons.ac_unit),
              buildRelayControlCard(
                'Dispenser',
                'relay4',
                dispenserStatus,
                Icons.opacity,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed:
                    isSystemActive
                        ? (isSending ? null : updateDeviceStatus)
                        : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child:
                    isSending
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Text(
                          'Perbarui Status ke Antares',
                          style: TextStyle(fontSize: 16),
                        ),
              ),
              const SizedBox(height: 16),
              Card(
                color: Colors.amber[50],
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.amber[800]),
                          const SizedBox(width: 8),
                          const Text(
                            'Informasi Penting',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Pengaturan manual akan mengendalikan relay secara langsung dan juga memperbarui status ke Antares. Untuk kembali ke mode otomatis, nonaktifkan sistem di halaman ini.',
                        style: TextStyle(fontSize: 14),
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
