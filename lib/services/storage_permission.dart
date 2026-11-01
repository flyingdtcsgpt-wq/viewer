import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// 안드로이드에서 폴더 안의 책/만화/영상 파일을 읽으려면
/// "모든 파일 관리" 권한(안드로이드 11 이상) 또는 저장소 권한(10 이하)이 필요하다.
/// PC/아이폰은 바로 true.
Future<bool> ensureStorageAccess(BuildContext context) async {
  if (!Platform.isAndroid) return true;

  if (await Permission.manageExternalStorage.isGranted) return true;
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

  // 안드로이드 11+ : 시스템 설정 화면이 열리고, 돌아오면 결과가 온다
  var status = await Permission.manageExternalStorage.request();
  if (status.isGranted) return true;
  // 안드로이드 10 이하 : 일반 저장소 권한
  status = await Permission.storage.request();
  if (status.isGranted) return true;

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('권한이 없어 폴더를 읽을 수 없습니다'),
      action: SnackBarAction(label: '앱 설정', onPressed: openAppSettings),
    ));
  }
  return false;
}
