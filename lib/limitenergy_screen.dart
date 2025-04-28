import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

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
  bool _isConnected = true; // Track HTTP connection status

  // Antares HTTP Configuration
  final String _antaresBaseUrl = 'https://platform.antares.id:8443';
  final String _accessKey = 'b1e8024f40e20d77:9f09d4019f441404';
  final String _projectName = 'TA-YAZ';
  final String _deviceName = 'COUNTER';

  @override
  void initState() {
    super.initState();
    _limitController.text = widget.currentLimit.toStringAsFixed(2);
    _setupLogging();
  }

  @override
  void dispose() {
    logger.info("Disposing LimitenergyScreen");
    _limitController.dispose();
    super.dispose();
  }

  void _setupLogging() {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
  }

  Future<void> _sendEnergyLimit() async {
    // Input validation
    if (_limitController.text.isEmpty) {
      _showSnackBar('Silakan masukkan nilai batas', Colors.red);
      return;
    }

    final newLimit = double.tryParse(_limitController.text);
    if (newLimit == null || newLimit <= 0) {
      _showSnackBar('Batas harus berupa angka positif', Colors.red);
      return;
    }

    setState(() {
      _isLoading = true;
      _isConnected = true; // Reset connection status on new attempt
    });

    try {
      final newLimit90 = (newLimit * 0.9);
      final newLimit80 = (newLimit * 0.8);

      // Prepare the data payload directly as an object without pre-encoding
      final Map<String, dynamic> contentPayload = {
        "energyLimit2": newLimit,
        "limit90": newLimit90,
        "limit80": newLimit80,
      };

      // Endpoint - append "/la" to target latest content instance container
      final url = Uri.parse(
        '$_antaresBaseUrl/~/antares-cse/antares-id/$_projectName/$_deviceName/la',
      );

      // Request identifier helps with debugging
      final requestId = 'req${DateTime.now().millisecondsSinceEpoch}';

      // Prepare headers
      final headers = {
        'X-M2M-Origin': _accessKey,
        'Content-Type': 'application/json;ty=4',
        'Accept': 'application/json',
        'X-M2M-RI': requestId,
      };

      // OneM2M format - try without double encoding
      final requestBody = {
        "m2m:cin": {"cnf": "application/json", "con": contentPayload},
      };

      logger.info('HTTP: Sending request to Antares');
      logger.fine('URL: $url');
      logger.fine('Headers: $headers');
      logger.fine('Payload: ${jsonEncode(requestBody)}');

      final response = await http
          .post(url, headers: headers, body: jsonEncode(requestBody))
          .timeout(const Duration(seconds: 10));

      logger.info('HTTP: Response status code: ${response.statusCode}');
      logger.fine('Response body: ${response.body}');

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _showSnackBar('Batas energi berhasil diatur', Colors.green);
        Navigator.pop(context, {
          'newLimit': newLimit,
          'newLimit90': newLimit90,
          'newLimit80': newLimit80,
        });
      } else if (response.statusCode == 501) {
        // Try to extract more detailed error information
        logger.severe('HTTP 501 Error: ${response.body}');
        try {
          final errorData = jsonDecode(response.body);
          final errorMsg =
              errorData['m2m:error']?['error'] ??
              errorData['error'] ??
              'Unknown server error';
          _showSnackBar('Error: $errorMsg', Colors.orange);
        } catch (e) {
          _showSnackBar('Format request tidak valid (501)', Colors.orange);
        }
      } else {
        _showSnackBar(
          'Gagal mengirim data (Error: ${response.statusCode})',
          Colors.orange,
        );
      }
    } on TimeoutException {
      _showSnackBar('Timeout: Server tidak merespon', Colors.orange);
      setState(() {
        _isConnected = false;
      });
      logger.severe('HTTP Request timeout');
    } catch (e) {
      _showSnackBar('Gagal terhubung ke server: $e', Colors.red);
      setState(() {
        _isConnected = false;
      });
      logger.severe('HTTP Error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // String _parse501Error(String responseBody) {
  //   try {
  //     final jsonResponse = jsonDecode(responseBody);
  //     return jsonResponse['m2m:err']['rsc'] ?? 'Unknown 501 error';
  //   } catch (e) {
  //     return 'Invalid server response format';
  //   }
  // }

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
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
              color: _isConnected ? Colors.greenAccent : Colors.redAccent,
              size: 12,
            ),
            const SizedBox(width: 4),
            Text(
              _isConnected ? 'Online' : 'Offline',
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
                              _isLoading || !_isConnected
                                  ? null
                                  : _sendEnergyLimit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isConnected ? Colors.amber[700] : Colors.grey,
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
