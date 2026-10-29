import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final inDir = Directory('screenshots_in');
  final outDir = Directory('screenshots_out_ipad')..createSync(recursive: true);

  for (final file in inDir.listSync().whereType<File>()) {
    if (!file.path.toLowerCase().endsWith('.png')) continue;
    final original = img.decodeImage(file.readAsBytesSync());
    if (original == null) continue;

    // 아이패드 33cm 필수 규격: 2048 x 2732 (알파 채널 제거)
    final resized = img.copyResize(original, width: 2048, height: 2732);
    final rgb = resized.convert(numChannels: 3);

    final name = file.uri.pathSegments.last;
    File('${outDir.path}/ipad_$name').writeAsBytesSync(img.encodePng(rgb));
    stdout.writeln('✅ 아이패드용 변환 완료: ipad_$name');
  }
}
