import 'dart:convert';

import 'package:cryptdrive_native/cryptdrive_native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/vault_service.dart';
import 'widgets.dart';

/// Lets the user pick a standard rclone.conf and imports its remotes.
/// Returns the imported remote names, or null when cancelled.
Future<List<String>?> importRcloneConfFlow(BuildContext context, VaultService vault) async {
  final picked = await FilePicker.pickFile(dialogTitle: 'Import rclone.conf');
  if (picked == null) return null;
  final confText = await picked.xFile.readAsString();
  if (!context.mounted) return null;
  return importRcloneConfText(context, vault, confText);
}

Future<List<String>?> importRcloneConfText(BuildContext context, VaultService vault, String confText) async {
  String? password;
  while (true) {
    try {
      final remotes = await vault.importRcloneConf(confText, password: password);
      if (context.mounted) showMessage(context, 'Imported ${remotes.join(', ')}');
      return remotes;
    } on RcloneException catch (error) {
      if (!context.mounted) return null;
      final needsPassword =
          error.message.contains('config password is required') || error.message.contains('wrong config password');
      if (!needsPassword) {
        showMessage(context, describeError(error));
        return null;
      }
      password = await askText(
        context,
        title: password == null ? 'Encrypted rclone.conf' : 'Wrong password, try again',
        label: 'rclone config password',
        obscure: true,
        confirmLabel: 'Decrypt',
      );
      if (password == null || password.isEmpty) return null;
    }
  }
}

/// Writes the current config as a plain rclone.conf the rclone CLI reads as-is.
Future<void> exportRcloneConfFlow(BuildContext context, VaultService vault) async {
  final proceed = await confirm(
    context,
    title: 'Export rclone.conf',
    message:
        'The exported file is a standard, unencrypted rclone.conf. It contains your Google token and '
        'your vault passwords (obscured, not encrypted): anyone with the file can open the vault. '
        'Keep it somewhere safe.',
    confirmLabel: 'Export',
  );
  if (!proceed || !context.mounted) return;
  try {
    final conf = await vault.exportRcloneConf();
    final saved = await FilePicker.saveFile(
      fileName: 'rclone.conf',
      bytes: utf8.encode(conf),
      mimeType: 'text/plain',
      dialogTitle: 'Export rclone.conf',
    );
    if (saved != null && context.mounted) showMessage(context, 'Exported rclone.conf');
  } catch (error) {
    if (context.mounted) showMessage(context, describeError(error));
  }
}
