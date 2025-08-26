// lib/core/services/background_image_service.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service for handling custom background image operations
/// Handles picking, compression, storage, and cleanup of custom background images
class BackgroundImageService {
  static final BackgroundImageService _instance =
      BackgroundImageService._internal();
  factory BackgroundImageService() => _instance;
  BackgroundImageService._internal();

  final ImagePicker _imagePicker = ImagePicker();
  static const String _backgroundsFolder = 'custom_backgrounds';
  static const int _compressionQuality = 85;
  static const int _maxWidth = 1920;
  static const int _maxHeight = 1080;

  /// Pick image from gallery
  Future<BackgroundImageResult> pickFromGallery(String userId) async {
    try {
      print('BACKGROUND_SERVICE: Picking image from gallery for user: $userId');

      // Check photo library permission
      final permissionResult = await _checkPhotoPermission();
      if (!permissionResult.hasPermission) {
        return BackgroundImageResult.failure(
          permissionResult.errorMessage,
          needsSettings: permissionResult.needsSettings,
        );
      }

      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: _maxWidth.toDouble(),
        maxHeight: _maxHeight.toDouble(),
        imageQuality: _compressionQuality,
      );

      if (pickedFile == null) {
        print('BACKGROUND_SERVICE: User cancelled gallery picker');
        return BackgroundImageResult.failure('No image selected');
      }

      return await _processPickedImage(pickedFile, userId, 'gallery');
    } catch (e) {
      print('BACKGROUND_SERVICE: Error picking from gallery: $e');
      return BackgroundImageResult.failure(
        'Failed to pick image from gallery: ${e.toString()}',
      );
    }
  }

  /// Pick image from camera
  Future<BackgroundImageResult> pickFromCamera(String userId) async {
    try {
      print('BACKGROUND_SERVICE: Taking photo with camera for user: $userId');

      // Check camera permission
      final permissionResult = await _checkCameraPermission();
      if (!permissionResult.hasPermission) {
        return BackgroundImageResult.failure(
          permissionResult.errorMessage,
          needsSettings: permissionResult.needsSettings,
        );
      }

      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: _maxWidth.toDouble(),
        maxHeight: _maxHeight.toDouble(),
        imageQuality: _compressionQuality,
      );

      if (pickedFile == null) {
        print('BACKGROUND_SERVICE: User cancelled camera');
        return BackgroundImageResult.failure('No photo taken');
      }

      return await _processPickedImage(pickedFile, userId, 'camera');
    } catch (e) {
      print('BACKGROUND_SERVICE: Error taking photo: $e');
      return BackgroundImageResult.failure(
        'Failed to take photo: ${e.toString()}',
      );
    }
  }

  /// Show image source selection modal
  Future<BackgroundImageResult> showImageSourceSelector({
    required BuildContext context,
    required String userId,
  }) async {
    final String? choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (BuildContext context) => CupertinoActionSheet(
        title: const Text('Add Custom Background'),
        message: const Text(
          'Choose how you\'d like to add your background image',
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'camera'),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.camera, size: 20),
                SizedBox(width: 8),
                Text('Take Photo'),
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'gallery'),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.photo_on_rectangle, size: 20),
                SizedBox(width: 8),
                Text('Choose from Gallery'),
              ],
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
      ),
    );

    // Handle the user's choice
    if (choice == null) {
      return BackgroundImageResult.failure('Cancelled');
    }

    // Execute the chosen action
    if (choice == 'camera') {
      return await pickFromCamera(userId);
    } else if (choice == 'gallery') {
      return await pickFromGallery(userId);
    } else {
      return BackgroundImageResult.failure('Invalid choice');
    }
  }

  /// Process picked image: compress and save
  Future<BackgroundImageResult> _processPickedImage(
    XFile pickedFile,
    String userId,
    String source,
  ) async {
    try {
      print('BACKGROUND_SERVICE: Processing picked image from $source');

      // Read original file
      final originalFile = File(pickedFile.path);
      final originalBytes = await originalFile.readAsBytes();

      print(
        'BACKGROUND_SERVICE: Original image size: ${(originalBytes.length / 1024 / 1024).toStringAsFixed(2)}MB',
      );

      // Compress image
      final compressedBytes = await _compressImage(
        originalBytes,
        pickedFile.path,
      );
      if (compressedBytes == null) {
        return BackgroundImageResult.failure('Failed to compress image');
      }

      print(
        'BACKGROUND_SERVICE: Compressed image size: ${(compressedBytes.length / 1024 / 1024).toStringAsFixed(2)}MB',
      );

      // Generate unique filename
      final filename = _generateFilename(userId);

      // Save compressed image
      final savedPath = await _saveImageToAppDirectory(
        compressedBytes,
        filename,
      );
      if (savedPath == null) {
        return BackgroundImageResult.failure('Failed to save image');
      }

      print('BACKGROUND_SERVICE: ✅ Image saved successfully: $savedPath');
      return BackgroundImageResult.success(savedPath);
    } catch (e) {
      print('BACKGROUND_SERVICE: Error processing image: $e');
      return BackgroundImageResult.failure(
        'Failed to process image: ${e.toString()}',
      );
    }
  }

  /// Compress image to reduce file size
  Future<Uint8List?> _compressImage(
    Uint8List originalBytes,
    String originalPath,
  ) async {
    try {
      final result = await FlutterImageCompress.compressWithList(
        originalBytes,
        quality: _compressionQuality,
        minWidth: 800,
        minHeight: 600,
        format: CompressFormat.jpeg,
      );

      return result;
    } catch (e) {
      print('BACKGROUND_SERVICE: Error compressing image: $e');
      return null;
    }
  }

  /// Save image to app documents directory
  Future<String?> _saveImageToAppDirectory(
    Uint8List imageBytes,
    String filename,
  ) async {
    try {
      // Get app documents directory
      final appDocDir = await getApplicationDocumentsDirectory();
      final backgroundsDir = Directory('${appDocDir.path}/$_backgroundsFolder');

      // Create backgrounds directory if it doesn't exist
      if (!await backgroundsDir.exists()) {
        await backgroundsDir.create(recursive: true);
        print('BACKGROUND_SERVICE: Created backgrounds directory');
      }

      // Save file
      final filePath = '${backgroundsDir.path}/$filename';
      final file = File(filePath);
      await file.writeAsBytes(imageBytes);

      print('BACKGROUND_SERVICE: Image saved to: $filePath');
      return filePath;
    } catch (e) {
      print('BACKGROUND_SERVICE: Error saving image: $e');
      return null;
    }
  }

  /// Generate unique filename for user
  String _generateFilename(String userId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'user_${userId}_bg_$timestamp.jpg';
  }

  /// Delete custom background image
  Future<bool> deleteCustomBackground(String imagePath) async {
    try {
      print('BACKGROUND_SERVICE: Deleting custom background: $imagePath');

      final file = File(imagePath);
      if (await file.exists()) {
        await file.delete();
        print('BACKGROUND_SERVICE: ✅ Custom background deleted');
        return true;
      } else {
        print('BACKGROUND_SERVICE: File does not exist: $imagePath');
        return true; // Consider it successful if file doesn't exist
      }
    } catch (e) {
      print('BACKGROUND_SERVICE: Error deleting custom background: $e');
      return false;
    }
  }

  /// Clean up old custom backgrounds for user (keep only the latest)
  Future<void> cleanupOldBackgrounds(String userId) async {
    try {
      print(
        'BACKGROUND_SERVICE: Cleaning up old backgrounds for user: $userId',
      );

      final appDocDir = await getApplicationDocumentsDirectory();
      final backgroundsDir = Directory('${appDocDir.path}/$_backgroundsFolder');

      if (!await backgroundsDir.exists()) {
        return;
      }

      // Get all user's background files
      final userFiles = await backgroundsDir
          .list()
          .where(
            (entity) => entity is File && entity.path.contains('user_$userId'),
          )
          .cast<File>()
          .toList();

      if (userFiles.length <= 1) {
        return; // Keep at least one file
      }

      // Sort by modification time (newest first)
      userFiles.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );

      // Delete all but the newest
      for (int i = 1; i < userFiles.length; i++) {
        await userFiles[i].delete();
        print(
          'BACKGROUND_SERVICE: Deleted old background: ${userFiles[i].path}',
        );
      }

      print(
        'BACKGROUND_SERVICE: ✅ Cleanup completed, kept ${userFiles.isNotEmpty ? 1 : 0} file(s)',
      );
    } catch (e) {
      print('BACKGROUND_SERVICE: Error during cleanup: $e');
    }
  }

  /// Check if image file exists
  Future<bool> imageExists(String imagePath) async {
    try {
      final file = File(imagePath);
      return await file.exists();
    } catch (e) {
      print('BACKGROUND_SERVICE: Error checking image existence: $e');
      return false;
    }
  }

  /// Check camera permission with detailed status handling
  Future<PermissionResult> _checkCameraPermission() async {
    try {
      final status = await Permission.camera.status;
      print('CAMERA PERMISSION STATUS: $status');

      if (status.isGranted) {
        return PermissionResult.success();
      }

      if (status.isDenied) {
        print(
          'CAMERA PERMISSION: Requesting permission (will show iOS dialog)',
        );
        final result = await Permission.camera.request();
        print('CAMERA PERMISSION RESULT: $result');

        if (result.isGranted) {
          return PermissionResult.success();
        } else if (result.isPermanentlyDenied) {
          return PermissionResult.needsSettings(
            'Camera access is required to take photos. Please enable camera access in Settings.',
          );
        } else {
          return PermissionResult.denied('Camera access denied');
        }
      }

      if (status.isPermanentlyDenied) {
        return PermissionResult.needsSettings(
          'Camera access is required to take photos. Please enable camera access in Settings.',
        );
      }

      if (status.isRestricted) {
        return PermissionResult.denied(
          'Camera access is restricted on this device.',
        );
      }

      print('CAMERA PERMISSION: Unhandled status - $status');
      return PermissionResult.denied('Camera permission status: $status');
    } catch (e) {
      print('BACKGROUND_SERVICE: Error checking camera permission: $e');
      return PermissionResult.denied('Error checking camera permission');
    }
  }

  /// Check photo library permission with detailed status handling
  Future<PermissionResult> _checkPhotoPermission() async {
    try {
      final status = await Permission.photos.status;
      print('PHOTO PERMISSION STATUS: $status');

      if (status.isGranted) {
        return PermissionResult.success();
      }

      if (status.isDenied) {
        print('PHOTO PERMISSION: Requesting permission (will show iOS dialog)');
        final result = await Permission.photos.request();
        print('PHOTO PERMISSION RESULT: $result');

        if (result.isGranted) {
          return PermissionResult.success();
        } else if (result.isPermanentlyDenied) {
          return PermissionResult.needsSettings(
            'Photo library access is required to select images. Please enable photo access in Settings.',
          );
        } else {
          return PermissionResult.denied('Photo library access denied');
        }
      }

      if (status.isPermanentlyDenied) {
        return PermissionResult.needsSettings(
          'Photo library access is required to select images. Please enable photo access in Settings.',
        );
      }

      if (status.isRestricted) {
        return PermissionResult.denied(
          'Photo library access is restricted on this device.',
        );
      }

      print('PHOTO PERMISSION: Unhandled status - $status');
      return PermissionResult.denied('Photo permission status: $status');
    } catch (e) {
      print('BACKGROUND_SERVICE: Error checking photo permission: $e');
      return PermissionResult.denied('Error checking photo permission');
    }
  }
}

/// Result wrapper for background image operations
class BackgroundImageResult {
  final bool isSuccess;
  final String? imagePath;
  final String? error;
  final bool needsSettings;

  BackgroundImageResult.success(this.imagePath)
    : isSuccess = true,
      error = null,
      needsSettings = false;

  BackgroundImageResult.failure(this.error, {this.needsSettings = false})
    : isSuccess = false,
      imagePath = null;
}

/// Result wrapper for permission checks
class PermissionResult {
  final bool hasPermission;
  final String errorMessage;
  final bool needsSettings;

  PermissionResult.success()
    : hasPermission = true,
      errorMessage = '',
      needsSettings = false;

  PermissionResult.denied(this.errorMessage)
    : hasPermission = false,
      needsSettings = false;

  PermissionResult.needsSettings(this.errorMessage)
    : hasPermission = false,
      needsSettings = true;
}
