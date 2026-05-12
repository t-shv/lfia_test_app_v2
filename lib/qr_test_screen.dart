import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'qr_scanner.dart'; // your helper

class QRTestScreen extends StatelessWidget {
  final List<String> ids = ['TS-0001', 'TS-0002', 'TS-0003'];

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text('QR Test')),
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(16),
          children: ids.map((id) {
            final assetPath = 'assets/qr/qr_$id.png';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Image.asset(assetPath, width: 80, height: 80),
                  SizedBox(width: 16),
                  CupertinoButton(
                    child: Text('Scan $id'),
                    onPressed: () async {
                      // 1) Load bytes from assets
                      final data = await rootBundle.load(assetPath);
                      // 2) Write to a temp file
                      final dir = await getTemporaryDirectory();
                      final file = File('${dir.path}/qr_$id.png');
                      await file.writeAsBytes(data.buffer.asUint8List());
                      // 3) Scan it
                      final code = await scanQRCode(file.path);
                      // 4) Show result
                      showCupertinoDialog(
                        context: context,
                        builder: (_) => CupertinoAlertDialog(
                          title: Text('Scanned'),
                          content: Text(code ?? 'None'),
                          actions: [
                            CupertinoDialogAction(
                              child: Text('OK'),
                              onPressed: () => Navigator.pop(context),
                            )
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
