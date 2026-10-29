import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

void main() {
  const int size = 1024;
  final rgba = Uint8List(size * size * 4);

  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final idx = (y * size + x) * 4;
      final t = (x + y) / (2.0 * size);

      // 1. Pingo 브랜드 시그니처 그라데이션 배경 (#5B34FF -> #EC4899)
      int r = (91 + (236 - 91) * t).round().clamp(0, 255);
      int g = (52 + (72 - 52) * t).round().clamp(0, 255);
      int b = (255 + (153 - 255) * t).round().clamp(0, 255);

      final cx = size * 0.5;
      final cy = size * 0.44;
      final dx = x - cx;
      final dy = y - cy;
      final dist = math.sqrt(dx * dx + dy * dy);

      // 2. 은은한 LIVE 레이더 파동 링
      if ((dist > 340 && dist < 354) || (dist > 410 && dist < 420)) {
        r = ((r * 0.78) + (255 * 0.22)).round();
        g = ((g * 0.78) + (255 * 0.22)).round();
        b = ((b * 0.78) + (255 * 0.22)).round();
      }

      // 3. 중앙 화이트 위치 핀 (헤드 원형 + 하단 역삼각형 꼬리)
      final bool inPinHead = dist <= 220;
      final bool inPinTail =
          dy > 110 &&
          dy <= 370 &&
          dx.abs() <= (220 * (1.0 - (dy - 110) / 285.0)).clamp(0.0, 220.0);

      if (inPinHead || inPinTail) {
        r = 255;
        g = 255;
        b = 255;

        // 4. 핀 내부의 퍼플 코어 도트
        if (dist <= 92) {
          r = 108;
          g = 71;
          b = 255;
        }
      }

      rgba[idx] = r;
      rgba[idx + 1] = g;
      rgba[idx + 2] = b;
      rgba[idx + 3] = 255; // Apple 심사 필수: 투명도 0% (완전 불투명)
    }
  }

  final pngBytes = _encodePng(size, size, rgba);
  final outDir = Directory('assets/icon');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final outFile = File('assets/icon/pingo_icon.png');
  outFile.writeAsBytesSync(pngBytes);
  stdout.writeln('✅ Pingo 1024x1024 고해상도 아이콘 생성 완료: ${outFile.path}');
}

Uint8List _encodePng(int width, int height, Uint8List rgba) {
  final raw = BytesBuilder();
  for (int y = 0; y < height; y++) {
    raw.addByte(0);
    final rowStart = y * width * 4;
    raw.add(rgba.sublist(rowStart, rowStart + width * 4));
  }
  final compressed = zlib.encode(raw.toBytes());

  final out = BytesBuilder();
  out.add([137, 80, 78, 71, 13, 10, 26, 10]);

  final ihdr = BytesBuilder();
  ihdr.add(_u32(width));
  ihdr.add(_u32(height));
  ihdr.add([8, 6, 0, 0, 0]);
  _writeChunk(out, 'IHDR', ihdr.toBytes());
  _writeChunk(out, 'IDAT', compressed);
  _writeChunk(out, 'IEND', []);
  return out.toBytes();
}

void _writeChunk(BytesBuilder out, String type, List<int> data) {
  out.add(_u32(data.length));
  final typeBytes = type.codeUnits;
  out.add(typeBytes);
  out.add(data);
  final crcInput = BytesBuilder()
    ..add(typeBytes)
    ..add(data);
  out.add(_u32(_crc32(crcInput.toBytes())));
}

List<int> _u32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

int _crc32(List<int> bytes) {
  int c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
