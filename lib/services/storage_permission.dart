import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 안드로이드 "모든 파일 관리" 권한 (안드로이드 11+).
/// 네이티브 쪽은 tool/patch_android.py 가 MainActivity 에 넣는다.
const _ch = MethodChannel('mediashelf/storage');

Future<bool> _granted() async {
  try {
    return await _ch.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  } catch (_) {
    return true; // 채널이 없으면(다른 플랫폼) 막지 않는다
  }
}

/// 폴더 안의 책/만화/영상 파일을 읽을 수 있는지 확인하고, 없으면 설정 화면으로 안내
Future<bool> ensureStorageAccess(BuildContext context) async {
  if (!Platform.isAndroid) return true;
  if (await _granted()) return true;
  if (!context.mounted) return false;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.folder_open),
      title: const Text('파일 접근 권한이 필요합니다'),
      content: const Text(
        '등록한 폴더 안의 책·만화·영상 파일을 읽으려면 "모든 파일 관리" 권한이 필요합니다.\n\n'
        '다음 화면에서 MediaShelf 의 "모든 파일 관리 허용"을 켠 뒤 뒤로 돌아오세요.\n'
        '파일은 이 기기 안에서만 읽고, 어디로도 보내지 않습니다.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('나중에')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('설정 열기')),
      ],
    ),
  );
  if (go != true) return false;
  try {
    // 설정 화면을 열고, 사용자가 돌아오면 결과를 받는다
    await _ch.invokeMethod('requestAllFilesAccess');
  } catch (_) {}
  final ok = await _granted();
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('권한이 없어 폴더를 읽을 수 없습니다. 설정 → 앱 → MediaShelf → 권한에서 켜 주세요.')),
    );
  }
  return ok;
}
