import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

class SpeakerDevice {
  final String id;
  final String name;
  final String host;
  final int port;
  final String protocol;
  const SpeakerDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.protocol,
  });
}

class SpeakerDiscoveryService {
  SpeakerDiscoveryService._();
  static final SpeakerDiscoveryService instance = SpeakerDiscoveryService._();

  final _controller = StreamController<List<SpeakerDevice>>.broadcast();
  Stream<List<SpeakerDevice>> get devicesStream => _controller.stream;

  final List<SpeakerDevice> _devices = <SpeakerDevice>[];

  Future<List<SpeakerDevice>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final client = MDnsClient(rawDatagramSocketFactory: (dynamic host, int port, {bool reuseAddress = true, bool reusePort = false, int ttl = 255}) {
      return RawDatagramSocket.bind(host, port, reuseAddress: reuseAddress, reusePort: reusePort, ttl: ttl);
    });
    final found = <SpeakerDevice>[];
    try {
      await client.start();
      final services = <String>[
        '_googlecast._tcp.local',
        '_airplay._tcp.local',
        '_raop._tcp.local',
      ];
      for (final service in services) {
        await for (final ptr in client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(service)).timeout(timeout, onTimeout: (sink) => sink.close())) {
          final srvRecords = client.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName),
          );
          await for (final srv in srvRecords.timeout(timeout, onTimeout: (sink) => sink.close())) {
            final item = SpeakerDevice(
              id: '${service}_${srv.target}',
              name: ptr.domainName.replaceAll('.local', ''),
              host: srv.target,
              port: srv.port,
              protocol: service,
            );
            if (!found.any((e) => e.id == item.id)) {
              found.add(item);
            }
          }
        }
      }
      _devices
        ..clear()
        ..addAll(found);
      _controller.add(List<SpeakerDevice>.unmodifiable(_devices));
      return List<SpeakerDevice>.unmodifiable(_devices);
    } finally {
      client.stop();
    }
  }
}
