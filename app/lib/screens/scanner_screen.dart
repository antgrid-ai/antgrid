import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../design/widgets/ab_snack_bar.dart';
import '../models/qr_payload.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanned = false;
  DateTime _lastSnackbar = DateTime(0);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: MobileScanner(controller: _controller, onDetect: _onDetect),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      final qr = QrPayload.parse(raw);
      if (qr != null) {
        _scanned = true;
        Navigator.of(context).pop(qr);
        return;
      }
    }

    // Throttle snackbar to at most once every 3 seconds
    final now = DateTime.now();
    if (capture.barcodes.isNotEmpty &&
        now.difference(_lastSnackbar).inSeconds >= 3) {
      _lastSnackbar = now;
      showAbSnackBar(
        context,
        'Not a valid Antgrid connect code',
        duration: const Duration(seconds: 2),
      );
    }
  }
}
