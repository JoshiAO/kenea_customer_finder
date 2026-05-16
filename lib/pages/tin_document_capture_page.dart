import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/customer.dart';
import '../services/database_service.dart';
import '../widgets/branded_app_bar.dart';

class TinCaptureResult {
  final String detectedTin;
  final String savedFileName;

  const TinCaptureResult({
    required this.detectedTin,
    required this.savedFileName,
  });
}

class TinDocumentCapturePage extends StatefulWidget {
  final Customer customer;

  const TinDocumentCapturePage({super.key, required this.customer});

  @override
  State<TinDocumentCapturePage> createState() => _TinDocumentCapturePageState();
}

class _TinDocumentCapturePageState extends State<TinDocumentCapturePage> {
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  CameraController? _cameraController;
  bool _isInitializing = true;
  bool _isProcessingFrame = false;
  bool _isCapturing = false;
  int _frameCounter = 0;
  String? _lastDetectedTin;
  String _status = 'Point camera to TIN document...';

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await controller.initialize();
      if (!mounted) return;

      _cameraController = controller;
      await _cameraController!.startImageStream(_handleCameraFrame);

      if (!mounted) return;
      setState(() {
        _isInitializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Camera init failed: $e';
        _isInitializing = false;
      });
    }
  }

  Future<void> _handleCameraFrame(CameraImage image) async {
    if (_isProcessingFrame || _isCapturing || !mounted) return;

    _frameCounter++;
    if (_frameCounter % 5 != 0) {
      return;
    }

    _isProcessingFrame = true;
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      final recognized = await _textRecognizer.processImage(inputImage);
      final joinedText = recognized.text;
      final tin = _extractTin(joinedText);
      final looksLikeTinDocument = _looksLikeTinDocument(joinedText);

      if (tin != null) {
        _lastDetectedTin = tin;
        if (mounted) {
          setState(() {
            _status = looksLikeTinDocument
                ? 'TIN detected: $tin. Capturing image...'
                : 'TIN-like number detected: $tin';
          });
        }
      }

      if (tin != null && looksLikeTinDocument) {
        await _captureAndReturn(tin);
      }
    } catch (_) {
      // Ignore transient OCR frame errors.
    } finally {
      _isProcessingFrame = false;
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final controller = _cameraController;
    if (controller == null) return null;

    final bytes = _concatenatePlanes(image.planes);
    final rotation = _rotationFromSensor(controller.description.sensorOrientation);
    final format = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final builder = BytesBuilder();
    for (final plane in planes) {
      builder.add(plane.bytes);
    }
    return builder.toBytes();
  }

  InputImageRotation _rotationFromSensor(int sensorOrientation) {
    return InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation0deg;
  }

  bool _looksLikeTinDocument(String text) {
    final upper = text.toUpperCase();
    return upper.contains('TIN') ||
        upper.contains('BIR') ||
        upper.contains('RECEIPT') ||
        upper.contains('INVOICE');
  }

  String? _extractTin(String text) {
    final cleaned = text.replaceAll('\n', ' ');
    final pattern = RegExp(r'(\d{2,3})\D*(\d{3})\D*(\d{3})\D*(\d{3,4})');
    final match = pattern.firstMatch(cleaned);
    if (match == null) return null;

    final g1 = match.group(1);
    final g2 = match.group(2);
    final g3 = match.group(3);
    final g4 = match.group(4);
    if (g1 == null || g2 == null || g3 == null || g4 == null) return null;

    return '$g1-$g2-$g3-$g4';
  }

  Future<void> _manualCapture() async {
    final controller = _cameraController;
    if (controller == null || _isCapturing) return;

    setState(() {
      _status = 'Capturing manually...';
    });

    try {
      _isCapturing = true;
      await controller.stopImageStream();
      final file = await controller.takePicture();

      final recognized = await _textRecognizer.processImage(InputImage.fromFilePath(file.path));
      final tin = _extractTin(recognized.text);

      if (tin == null) {
        if (!mounted) return;
        setState(() {
          _status = 'TIN not detected. Try again with better framing.';
        });
        await controller.startImageStream(_handleCameraFrame);
        _isCapturing = false;
        return;
      }

      final savedPath = await _saveTinImage(File(file.path));
      if (!mounted) return;
      Navigator.pop(
        context,
        TinCaptureResult(detectedTin: tin, savedFileName: p.basename(savedPath)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Manual capture failed: $e';
      });
      try {
        await controller.startImageStream(_handleCameraFrame);
      } catch (_) {}
      _isCapturing = false;
    }
  }

  Future<void> _captureAndReturn(String tin) async {
    final controller = _cameraController;
    if (controller == null || _isCapturing) return;

    _isCapturing = true;

    try {
      await controller.stopImageStream();
      final file = await controller.takePicture();
      final savedPath = await _saveTinImage(File(file.path));

      if (!mounted) return;
      Navigator.pop(
        context,
        TinCaptureResult(detectedTin: tin, savedFileName: p.basename(savedPath)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Auto-capture failed: $e';
      });
      try {
        await controller.startImageStream(_handleCameraFrame);
      } catch (_) {}
      _isCapturing = false;
    }
  }

  Future<String> _saveTinImage(File source) async {
    final appDir = await getApplicationDocumentsDirectory();
    final folderName = DatabaseService.customerImageFolderName(widget.customer);
    final folder = Directory(p.join(appDir.path, 'captured_images', folderName));

    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final fileName =
        'tin_document_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}.jpg';
    final destination = p.join(folder.path, fileName);

    await source.copy(destination);
    return destination;
  }

  @override
  void dispose() {
    unawaited(_cameraController?.dispose());
    unawaited(_textRecognizer.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;

    return Scaffold(
      appBar: buildBrandedAppBar(
        context: context,
        title: const Text('Capture TIN Document'),
      ),
      body: _isInitializing
          ? const Center(child: CircularProgressIndicator())
          : controller == null || !controller.value.isInitialized
              ? Center(child: Text(_status))
              : Column(
                  children: [
                    Expanded(
                      child: CameraPreview(controller),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      child: Text(
                        _status,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (_lastDetectedTin != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'Detected: $_lastDetectedTin',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _manualCapture,
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('Manual Capture'),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
