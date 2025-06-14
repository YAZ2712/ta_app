import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttManager {
  static Future<MqttServerClient?> connect() async {
    final String accessKey = 'fe5c7a15d8c13220:bfd764392a99a094';
    final String clientIdentifier =
        'client_${DateTime.now().millisecondsSinceEpoch}';

    final MqttServerClient client = MqttServerClient(
      'mqtt.antares.id',
      clientIdentifier,
    );

    client.port = 1883;
    client.keepAlivePeriod = 60;
    client.logging(on: true);

    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientIdentifier)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

    print(
      'MQTT_MANAGER: Mencoba konek dengan clientID: $clientIdentifier dan user: $accessKey',
    );

    try {
      await client.connect(accessKey, '');
    } catch (e) {
      print('MQTT_MANAGER: Koneksi GAGAL: $e');
      client.disconnect();
      return null;
    }

    if (client.connectionStatus!.state == MqttConnectionState.connected) {
      print('MQTT_MANAGER: Koneksi BERHASIL!');
      final topic = '/oneM2M/resp/antares-cse/$accessKey/json';
      client.subscribe(topic, MqttQos.atLeastOnce);
      return client;
    } else {
      print(
        'MQTT_MANAGER: Gagal terhubung, status: ${client.connectionStatus}',
      );
      client.disconnect();
      return null;
    }
  }
}
