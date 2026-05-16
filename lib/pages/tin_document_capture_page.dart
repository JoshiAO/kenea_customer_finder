import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const double _autoCaptureThreshold = 0.78;
  static const int _requiredStableFrames = 2;
  static const double _guideDocumentAspectRatio = 1034 / 766;
  static const double _guideHorizontalPadding = 0.06;
  static const double _guideTopOffset = 0.12;
  static const double _guideMaxHeightFactor = 0.68;
  static const double _tinZoneLeftFactor = 0.26;
  static const double _tinZoneTopFactor = 0.54;
  static const double _tinZoneWidthFactor = 0.48;
  static const double _tinZoneHeightFactor = 0.14;
  static const double _tinZoneMinOverlap = 0.24;
  static const double _autoTinLockBonus = 0.12;
  static const int _tinConsensusWindow = 8;

  CameraController? _cameraController;
  Timer? _autoDetectTimer;
  bool _isInitializing = true;
  bool _isAnalyzingAutoFrame = false;
  bool _isCapturing = false;
  String? _lastDetectedTin;
  String? _lastQualifiedTin;
  int _stableDetectionFrames = 0;
  double _lastDetectionScore = 0;
  bool _isAlignedInGuide = false;
  bool _isTinZoneAligned = false;
  bool _isAutoTinDetected = false;
  Rect? _autoTinRectNormalized;
  List<String> _lastTopTinCandidates = const [];
  final List<String> _recentTinVotes = <String>[];
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
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await controller.initialize();
      if (!mounted) return;

      _cameraController = controller;
      _startAutoDetectionLoop();

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

  void _startAutoDetectionLoop() {
    _autoDetectTimer?.cancel();
    _autoDetectTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      unawaited(_analyzeAutoFrame());
    });
  }

  Future<void> _analyzeAutoFrame() async {
    final controller = _cameraController;
    if (!mounted || controller == null) return;
    if (!controller.value.isInitialized || _isCapturing || _isAnalyzingAutoFrame) return;

    _isAnalyzingAutoFrame = true;
    XFile? frameCapture;
    try {
      frameCapture = await controller.takePicture();
      final recognized = await _textRecognizer.processImage(InputImage.fromFilePath(frameCapture.path));
      final previewSize = controller.value.previewSize;
      final frameSize = previewSize == null
          ? const Size(1280, 720)
          : Size(previewSize.height, previewSize.width);

      final detection = _evaluateBirTinDocument(recognized, frameSize: frameSize);
      final voteSeedTin = detection.tin ?? (detection.topCandidates.isNotEmpty ? detection.topCandidates.first.value : null);
      final votedTin = _updateTinConsensus(voteSeedTin);
      final tin = votedTin ?? detection.tin;
      _lastDetectionScore = detection.score;
      _isAlignedInGuide = detection.isGuideAligned;
      _isTinZoneAligned = detection.isTinZoneAligned;
      _isAutoTinDetected = detection.hasAutoTinLock;
      _autoTinRectNormalized = detection.autoTinRectNormalized;
      _lastTopTinCandidates = detection.topCandidates
          .map((candidate) => '${candidate.value} (${(candidate.score * 100).toStringAsFixed(0)}%)')
          .toList(growable: false);

      if (tin != null) {
        _lastDetectedTin = tin;
        if (mounted) {
          setState(() {
            _status = detection.isQualified
                ? 'BIR document matched (${(_lastDetectionScore * 100).toStringAsFixed(0)}%). Hold steady...'
                : 'TIN detected but score is low (${(_lastDetectionScore * 100).toStringAsFixed(0)}%). Align inside the guide box.';
          });
        }
      } else if (mounted) {
        _lastDetectedTin = null;
        setState(() {
          _status =
              'Looking for BIR TIN layout... score ${(detection.score * 100).toStringAsFixed(0)}%. Place document inside the guide.';
        });
      }

      if (detection.isQualified && tin != null) {
        if (_lastQualifiedTin == tin) {
          _stableDetectionFrames += 1;
        } else {
          _lastQualifiedTin = tin;
          _stableDetectionFrames = 1;
        }

        if (_stableDetectionFrames >= _requiredStableFrames) {
          if (mounted) {
            setState(() {
              _status =
                  'TIN and BIR layout confirmed (${(_lastDetectionScore * 100).toStringAsFixed(0)}%). Capturing...';
            });
          }
          await _captureAndReturn(tin);
        }
      } else {
        _lastQualifiedTin = null;
        _stableDetectionFrames = 0;
      }
    } catch (_) {
      // Ignore transient OCR frame errors.
    } finally {
      if (frameCapture != null) {
        try {
          final frameFile = File(frameCapture.path);
          if (await frameFile.exists()) {
            await frameFile.delete();
          }
        } catch (_) {}
      }
      _isAnalyzingAutoFrame = false;
    }
  }

  String? _updateTinConsensus(String? candidate) {
    if (candidate == null || candidate.trim().isEmpty) return null;

    _recentTinVotes.add(candidate.trim());
    if (_recentTinVotes.length > _tinConsensusWindow) {
      _recentTinVotes.removeAt(0);
    }

    final counts = <String, int>{};
    for (final value in _recentTinVotes) {
      counts[value] = (counts[value] ?? 0) + 1;
    }

    String best = candidate;
    var bestCount = 0;
    counts.forEach((value, count) {
      if (count > bestCount) {
        best = value;
        bestCount = count;
      }
    });

    if (bestCount >= 2) return best;
    return candidate;
  }

  _BirTinDetection _evaluateBirTinDocument(RecognizedText recognized, {required Size frameSize}) {
    final normalizedFullText = _normalizeText(recognized.text);
    final lineHits = <_OcrLineHit>[];
    Rect? docBounds;

    for (final block in recognized.blocks) {
      final blockRect = block.boundingBox;
      if (docBounds == null) {
        docBounds = blockRect;
      } else {
        docBounds = docBounds.expandToInclude(blockRect);
      }

      for (final line in block.lines) {
        lineHits.add(
          _OcrLineHit(
            text: _normalizeText(line.text),
            bounds: line.boundingBox,
          ),
        );
      }
    }

    final tinSelection = _extractTinCandidatesFromLines(lineHits, normalizedFullText, docBounds);
    final tinCandidate = tinSelection.best;
    final hasBirKeyword = _containsAny(normalizedFullText, const [
      'BIR',
      'BUREAU OF INTERNAL REVENUE',
      'REPUBLIC OF THE PHILIPPINES',
    ]);
    final hasPhilippinesKeyword = _containsAny(normalizedFullText, const [
      'PHILIPPINES',
      'INTERNAL REVENUE',
    ]);
    final hasReceiptInvoiceKeyword = _containsAny(normalizedFullText, const [
      'RECEIPT',
      'INVOICE',
      'ASK FOR RECEIPT',
      'MUST ISSUE',
    ]);
    final hasTinLabel = _containsAny(normalizedFullText, const [
      'TIN',
      'TIN AND BRANCH CODE',
      'TAXPAYER IDENTIFICATION NUMBER',
    ]);

    final topKeywordHits = lineHits.where((line) {
      return _isTopRegion(line.bounds, docBounds) &&
          _containsAny(line.text, const ['RECEIPT', 'INVOICE', 'ASK FOR', 'MUST ISSUE']);
    }).length;

    final lowerTinHits = lineHits.where((line) {
      return _isTinRegion(line.bounds, docBounds) &&
          _containsAny(line.text, const ['TIN', 'BRANCH CODE']);
    }).length;

    final isTinInPrimaryRegion =
        tinCandidate != null && _isTinRegion(tinCandidate.bounds, docBounds);
    final isTinInTiltTolerantRegion = tinCandidate != null &&
        _isTinRegionTiltTolerant(
          tinCandidate.bounds,
          docBounds,
          hasStrongLabelContext: tinCandidate.hasStrongLabelContext,
        );
    final hasTinLabelNearNumber = tinCandidate?.hasLabelContext ?? false;
    final hasStrongTinLabelNearNumber = tinCandidate?.hasStrongLabelContext ?? false;
    final tinContextScore = tinCandidate?.contextScore ?? 0;
    final isGuideAligned = docBounds != null && _isInGuideRegion(docBounds, frameSize);
    final isTinZoneAligned = tinCandidate != null && _isInTinValueRegion(tinCandidate.bounds, frameSize);
    final hasAutoTinLock = tinCandidate != null && isTinZoneAligned;
    final autoTinRectNormalized = hasAutoTinLock ? _toNormalizedRect(tinCandidate?.bounds, frameSize) : null;

    double score = 0;
    if (tinCandidate != null) score += 0.30;
    if (hasTinLabel) score += 0.13;
    if (hasBirKeyword) score += 0.13;
    if (hasPhilippinesKeyword) score += 0.08;
    if (hasReceiptInvoiceKeyword) score += 0.10;
    if (topKeywordHits > 0) score += 0.08;
    if (lowerTinHits > 0) score += 0.07;
    if (isTinInPrimaryRegion) score += 0.12;
    if (!isTinInPrimaryRegion && isTinInTiltTolerantRegion) score += 0.07;
    if (hasTinLabelNearNumber) score += 0.11;
    if (hasStrongTinLabelNearNumber) score += 0.08;
    score += tinContextScore * 0.12;
    if (isGuideAligned) score += 0.08;
    if (isTinZoneAligned) score += 0.10;
    if (hasAutoTinLock) score += _autoTinLockBonus;
    if (score > 1) score = 1;

    final hasRegionEvidence =
      topKeywordHits > 0 || lowerTinHits > 0 || isTinInPrimaryRegion || isTinInTiltTolerantRegion;
    final hasIdentitySignal =
      hasBirKeyword || (hasReceiptInvoiceKeyword && hasPhilippinesKeyword) || topKeywordHits > 0;
    final allowsTiltFallback =
      !isTinInPrimaryRegion && isTinInTiltTolerantRegion && hasStrongTinLabelNearNumber;
    final effectiveThreshold = isGuideAligned ? 0.72 : _autoCaptureThreshold;
    final isQualified = tinCandidate != null &&
      score >= effectiveThreshold &&
      hasIdentitySignal &&
      (hasTinLabelNearNumber || hasTinLabel) &&
      tinContextScore >= 0.20 &&
      hasRegionEvidence &&
      (isTinZoneAligned || hasAutoTinLock) &&
      (isTinInPrimaryRegion || allowsTiltFallback);

    return _BirTinDetection(
      tin: tinCandidate?.value,
      score: score,
      isQualified: isQualified,
      isGuideAligned: isGuideAligned,
      isTinZoneAligned: isTinZoneAligned,
      hasAutoTinLock: hasAutoTinLock,
      autoTinRectNormalized: autoTinRectNormalized,
      topCandidates: tinSelection.ranked.take(3).toList(growable: false),
    );
  }

  Rect? _toNormalizedRect(Rect? rect, Size frameSize) {
    if (rect == null || frameSize.width <= 0 || frameSize.height <= 0) return null;

    double clamp(double value) => value < 0 ? 0 : (value > 1 ? 1 : value);

    final left = clamp(rect.left / frameSize.width);
    final top = clamp(rect.top / frameSize.height);
    final right = clamp(rect.right / frameSize.width);
    final bottom = clamp(rect.bottom / frameSize.height);

    if (right <= left || bottom <= top) return null;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  bool _isInGuideRegion(Rect? bounds, Size frameSize) {
    if (bounds == null || frameSize.width <= 0 || frameSize.height <= 0) return false;

    final guide = _computeGuideRect(frameSize);

    final intersection = bounds.intersect(guide);
    if (intersection.isEmpty) return false;

    final overlapRatio = (intersection.width * intersection.height) / (bounds.width * bounds.height);
    return overlapRatio >= 0.35;
  }

  bool _isInTinValueRegion(Rect? bounds, Size frameSize) {
    if (bounds == null || frameSize.width <= 0 || frameSize.height <= 0) return false;

    final guide = _computeGuideRect(frameSize);
    final tinZone = _computeTinValueZoneRect(guide);

    final centerInside = tinZone.contains(bounds.center);

    final intersection = bounds.intersect(tinZone);
    if (intersection.isEmpty) return false;

    final overlapRatio = (intersection.width * intersection.height) / (bounds.width * bounds.height);
    return centerInside && overlapRatio >= _tinZoneMinOverlap;
  }

  Rect _computeGuideRect(Size size) {
    final maxWidth = size.width * (1 - (_guideHorizontalPadding * 2));
    final maxHeight = size.height * _guideMaxHeightFactor;

    var guideWidth = maxWidth;
    var guideHeight = guideWidth / _guideDocumentAspectRatio;

    if (guideHeight > maxHeight) {
      guideHeight = maxHeight;
      guideWidth = guideHeight * _guideDocumentAspectRatio;
    }

    final left = (size.width - guideWidth) / 2;
    var top = size.height * _guideTopOffset;
    final maxTop = size.height - guideHeight - 12;
    if (top > maxTop) {
      top = maxTop;
    }

    return Rect.fromLTWH(left, top, guideWidth, guideHeight);
  }

  Rect _computeTinValueZoneRect(Rect guideRect) {
    final left = guideRect.left + (guideRect.width * _tinZoneLeftFactor);
    final top = guideRect.top + (guideRect.height * _tinZoneTopFactor);
    final width = guideRect.width * _tinZoneWidthFactor;
    final height = guideRect.height * _tinZoneHeightFactor;
    return Rect.fromLTWH(left, top, width, height);
  }

  _TinSelection _extractTinCandidatesFromLines(List<_OcrLineHit> lines, String fullText, Rect? docBounds) {
    final bestByValue = <String, _TinCandidate>{};
    final labelIndices = <int>[];

    for (var i = 0; i < lines.length; i++) {
      if (_containsAny(lines[i].text, const ['TIN', 'BRANCH', 'CODE', 'TAXPAYER'])) {
        labelIndices.add(i);
      }
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      final values = <String>{
        ..._extractTinMatches(line.text),
      };
      if (i + 1 < lines.length) {
        values.addAll(_extractTinMatches('${line.text} ${lines[i + 1].text}'));
      }
      if (values.isEmpty) continue;

      final contextTexts = <String>[line.text];
      if (i > 0) contextTexts.add(lines[i - 1].text);
      if (i + 1 < lines.length) contextTexts.add(lines[i + 1].text);
      final contextJoined = contextTexts.join(' ');

      final hasLabelContext = _containsAny(contextJoined, const ['TIN', 'BRANCH', 'CODE']);
      final hasStrongLabelContext = _containsAny(
        contextJoined,
        const ['TIN AND BRANCH CODE', 'TAXPAYER IDENTIFICATION NUMBER'],
      );
      final hasReceiptContext = _containsAny(
        contextJoined,
        const ['RECEIPT', 'INVOICE', 'BIR'],
      );

      final nearestLabelDistance = _nearestLineDistance(i, labelIndices);
      final isTinRegion = _isTinRegion(line.bounds, docBounds);
      final isLowerHalf = line.bounds != null && docBounds != null
          ? line.bounds!.center.dy >= docBounds.center.dy
          : false;

      for (final value in values) {
        final parts = value.split('-');
        final branchLength = parts.isEmpty ? 0 : parts.last.length;
        final digitsOnly = value.replaceAll('-', '');
        final isExactTinLength = digitsOnly.length == 12;
        final hasHandwritingShape = digitsOnly.length >= 11 && digitsOnly.length <= 13;

        double contextScore = 0;
        if (hasLabelContext) contextScore += 0.40;
        if (hasStrongLabelContext) contextScore += 0.30;
        if (hasReceiptContext) contextScore += 0.10;
        if (isTinRegion) contextScore += 0.25;
        if (isLowerHalf) contextScore += 0.08;
        if (nearestLabelDistance == 0) {
          contextScore += 0.20;
        } else if (nearestLabelDistance == 1) {
          contextScore += 0.16;
        } else if (nearestLabelDistance == 2) {
          contextScore += 0.10;
        }
        if (branchLength == 4) contextScore += 0.10;
        if (isExactTinLength) contextScore += 0.18;
        if (hasHandwritingShape) contextScore += 0.08;
        if (isTinRegion && isExactTinLength && !hasLabelContext) contextScore += 0.10;
        if (contextScore > 1) contextScore = 1;

        final candidate = _TinCandidate(
          value: value,
          bounds: line.bounds,
          contextScore: contextScore,
          hasLabelContext: hasLabelContext || nearestLabelDistance <= 2 || isTinRegion,
          hasStrongLabelContext: hasStrongLabelContext || nearestLabelDistance <= 1 || (isTinRegion && isExactTinLength),
        );

        final existing = bestByValue[candidate.value];
        if (existing == null || candidate.contextScore > existing.contextScore) {
          bestByValue[candidate.value] = candidate;
        }
      }
    }

    if (bestByValue.isNotEmpty) {
      final rankedCandidates = bestByValue.values.toList()
        ..sort((a, b) => b.contextScore.compareTo(a.contextScore));

      return _TinSelection(
        best: rankedCandidates.first,
        ranked: rankedCandidates
            .map((candidate) => _TinCandidateScore(value: candidate.value, score: candidate.contextScore))
            .toList(growable: false),
      );
    }

    final fallback = _extractTin(fullText);
    if (fallback == null) {
      return const _TinSelection(best: null, ranked: []);
    }
    return _TinSelection(
      best: _TinCandidate(
        value: fallback,
        bounds: null,
        contextScore: 0,
        hasLabelContext: false,
        hasStrongLabelContext: false,
      ),
      ranked: [
        _TinCandidateScore(value: fallback, score: 0),
      ],
    );
  }

  int _nearestLineDistance(int currentIndex, List<int> targetIndices) {
    if (targetIndices.isEmpty) return 99;
    var nearest = 99;
    for (final index in targetIndices) {
      final distance = (currentIndex - index).abs();
      if (distance < nearest) nearest = distance;
      if (nearest == 0) return 0;
    }
    return nearest;
  }

  bool _containsAny(String source, List<String> keywords) {
    for (final keyword in keywords) {
      if (source.contains(keyword)) return true;
    }
    return false;
  }

  String _normalizeText(String value) {
    return value
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9\-\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _isTopRegion(Rect? lineBounds, Rect? docBounds) {
    if (lineBounds == null || docBounds == null || docBounds.height <= 0) return false;
    final relativeY = (lineBounds.center.dy - docBounds.top) / docBounds.height;
    return relativeY <= 0.45;
  }

  bool _isTinRegion(Rect? lineBounds, Rect? docBounds) {
    if (lineBounds == null || docBounds == null || docBounds.height <= 0 || docBounds.width <= 0) {
      return false;
    }
    final relativeY = (lineBounds.center.dy - docBounds.top) / docBounds.height;
    final relativeX = (lineBounds.center.dx - docBounds.left) / docBounds.width;
    return relativeY >= 0.28 && relativeY <= 0.88 && relativeX >= 0.10 && relativeX <= 0.95;
  }

  bool _isTinRegionTiltTolerant(
    Rect? lineBounds,
    Rect? docBounds, {
    required bool hasStrongLabelContext,
  }) {
    if (lineBounds == null || docBounds == null || docBounds.height <= 0 || docBounds.width <= 0) {
      return false;
    }

    if (!hasStrongLabelContext) {
      return false;
    }

    final relativeY = (lineBounds.center.dy - docBounds.top) / docBounds.height;
    final relativeX = (lineBounds.center.dx - docBounds.left) / docBounds.width;

    return relativeY >= 0.22 && relativeY <= 0.94 && relativeX >= 0.04 && relativeX <= 0.98;
  }

  String? _extractTin(String text) {
    final matches = _extractTinMatches(text);
    if (matches.isEmpty) return null;
    return matches.first;
  }

  List<String> _extractTinMatches(String text) {
    final cleaned = _normalizeTinText(text);
    final matches = <String>[];
    final seen = <String>{};

    final groupedPattern = RegExp(r'(\d{2,3})\s*[-—–:]?\s*(\d{3})\s*[-—–:]?\s*(\d{3})\s*[-—–:]?\s*(\d{3,4})');
    for (final match in groupedPattern.allMatches(cleaned)) {
      final g1 = match.group(1);
      final g2 = match.group(2);
      final g3 = match.group(3);
      final g4 = match.group(4);
      if (g1 == null || g2 == null || g3 == null || g4 == null) continue;
      final tin = '$g1-$g2-$g3-$g4';
      if (seen.add(tin)) {
        matches.add(tin);
      }
    }

    // Handles OCR outputs that lose all separators, e.g. 017127810000.
    final compactPattern = RegExp(r'\b\d{11,13}\b');
    for (final compact in compactPattern.allMatches(cleaned)) {
      final value = compact.group(0);
      if (value == null) continue;

      String? tin;
      if (value.length == 12) {
        tin = '${value.substring(0, 2)}-${value.substring(2, 5)}-${value.substring(5, 8)}-${value.substring(8, 12)}';
      } else if (value.length == 11) {
        tin = '${value.substring(0, 2)}-${value.substring(2, 5)}-${value.substring(5, 8)}-${value.substring(8, 11)}';
      } else if (value.length == 13) {
        tin = '${value.substring(0, 3)}-${value.substring(3, 6)}-${value.substring(6, 9)}-${value.substring(9, 13)}';
      }

      if (tin != null && seen.add(tin)) {
        matches.add(tin);
      }
    }

    return matches;
  }

  String _normalizeTinText(String text) {
    final upper = text.toUpperCase().replaceAll('\n', ' ');
    final buffer = StringBuffer();
    final chars = upper.split('');

    bool isDigitLike(String c) => RegExp(r'[0-9]').hasMatch(c);

    for (var i = 0; i < chars.length; i++) {
      final current = chars[i];
      final prev = i > 0 ? chars[i - 1] : '';
      final next = i + 1 < chars.length ? chars[i + 1] : '';
      final nearDigit =
          isDigitLike(prev) || isDigitLike(next) || prev == '-' || next == '-' || prev == ' ' || next == ' ';

      if (nearDigit && (current == 'O' || current == 'Q' || current == 'D')) {
        buffer.write('0');
      } else if (nearDigit && (current == 'I' || current == 'L' || current == '|')) {
        buffer.write('1');
      } else if (nearDigit && current == 'Z') {
        buffer.write('2');
      } else if (nearDigit && current == 'S') {
        buffer.write('5');
      } else if (nearDigit && current == 'G') {
        buffer.write('6');
      } else if (nearDigit && current == 'B') {
        buffer.write('8');
      } else {
        buffer.write(current);
      }
    }

    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _captureAndReturn(String tin) async {
    final controller = _cameraController;
    if (controller == null || _isCapturing) return;

    _isCapturing = true;
    _autoDetectTimer?.cancel();

    try {
      final file = await controller.takePicture();
      final savedPath = await _saveTinImage(File(file.path));

      final recognized = await _textRecognizer.processImage(InputImage.fromFilePath(savedPath));
      final candidates = _extractTinCandidatesForReview(recognized, fallbackTin: tin);

      if (!mounted) return;
      final selectedTin = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => _TinCaptureSummaryPage(
            imagePath: savedPath,
            candidates: candidates,
          ),
        ),
      );

      if (!mounted) return;
      if (selectedTin != null && selectedTin.trim().isNotEmpty) {
        Navigator.pop(
          context,
          TinCaptureResult(detectedTin: selectedTin.trim(), savedFileName: p.basename(savedPath)),
        );
        return;
      }

      setState(() {
        _status = 'Retake: align notice and TIN zone for auto-capture.';
      });
      _isCapturing = false;
      _startAutoDetectionLoop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Auto-capture failed: $e';
      });
      _isCapturing = false;
      _startAutoDetectionLoop();
    }
  }

  Future<void> _manualCapture() async {
    final controller = _cameraController;
    if (controller == null || _isCapturing || _isAnalyzingAutoFrame) return;

    _autoDetectTimer?.cancel();
    setState(() {
      _status = 'Manual capture in progress...';
    });
    _isCapturing = true;

    try {
      final file = await controller.takePicture();
      final savedPath = await _saveTinImage(File(file.path));

      final recognized = await _textRecognizer.processImage(InputImage.fromFilePath(savedPath));
      final fallbackTin = _extractTin(recognized.text) ?? '';
      final candidates = _extractTinCandidatesForReview(recognized, fallbackTin: fallbackTin);

      if (!mounted) return;
      final selectedTin = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => _TinCaptureSummaryPage(
            imagePath: savedPath,
            candidates: candidates,
          ),
        ),
      );

      if (!mounted) return;
      if (selectedTin != null && selectedTin.trim().isNotEmpty) {
        Navigator.pop(
          context,
          TinCaptureResult(detectedTin: selectedTin.trim(), savedFileName: p.basename(savedPath)),
        );
        return;
      }

      setState(() {
        _status = 'Retake: align notice and TIN zone for auto-capture.';
      });
      _isCapturing = false;
      _startAutoDetectionLoop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Manual capture failed: $e';
      });
      _isCapturing = false;
      _startAutoDetectionLoop();
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

  List<_TinCandidateScore> _extractTinCandidatesForReview(
    RecognizedText recognized, {
    required String fallbackTin,
  }) {
    final lines = <_OcrLineHit>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        lines.add(
          _OcrLineHit(
            text: _normalizeText(line.text),
            bounds: line.boundingBox,
          ),
        );
      }
    }

    final selection = _extractTinCandidatesFromLines(lines, _normalizeText(recognized.text), null);
    final ranked = selection.ranked.toList(growable: true);

    if (!ranked.any((candidate) => candidate.value == fallbackTin)) {
      ranked.insert(0, _TinCandidateScore(value: fallbackTin, score: 0.01));
    }

    final seenValues = <String>{};
    final deduped = <_TinCandidateScore>[];
    for (final candidate in ranked) {
      if (candidate.value.trim().isEmpty) continue;
      if (seenValues.add(candidate.value)) {
        deduped.add(candidate);
      }
    }
    return deduped.take(6).toList(growable: false);
  }

  @override
  void dispose() {
    _autoDetectTimer?.cancel();
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
                      child: Stack(
                        children: [
                          Positioned.fill(child: CameraPreview(controller)),
                          Positioned.fill(
                            child: _TinGuideOverlay(
                              documentAspectRatio: _guideDocumentAspectRatio,
                              horizontalPadding: _guideHorizontalPadding,
                              topOffset: _guideTopOffset,
                              maxHeightFactor: _guideMaxHeightFactor,
                              tinZoneLeftFactor: _tinZoneLeftFactor,
                              tinZoneTopFactor: _tinZoneTopFactor,
                              tinZoneWidthFactor: _tinZoneWidthFactor,
                              tinZoneHeightFactor: _tinZoneHeightFactor,
                              isAligned: _isAlignedInGuide,
                              isTinZoneAligned: _isTinZoneAligned,
                              isAutoTinDetected: _isAutoTinDetected,
                              autoTinRectNormalized: _autoTinRectNormalized,
                            ),
                          ),
                          Positioned(
                            right: 14,
                            bottom: 18,
                            child: ElevatedButton.icon(
                              onPressed: _manualCapture,
                              icon: const Icon(Icons.camera_alt_outlined),
                              label: const Text('Manual Capture'),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 160,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              Text(
                                _status,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _lastDetectedTin == null
                                    ? 'Detected: --'
                                    : 'Detected: $_lastDetectedTin • Score: ${(_lastDetectionScore * 100).toStringAsFixed(0)}%',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _isAlignedInGuide
                                    ? 'Document aligned in guide'
                                    : 'Align the whole notice inside the guide box',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: _isAlignedInGuide ? Colors.green.shade700 : Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _isTinZoneAligned
                                    ? 'TIN number is aligned in the inner capture zone'
                                    : 'Move TIN number into the inner TIN zone',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: _isTinZoneAligned ? Colors.green.shade700 : Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _isAutoTinDetected
                                    ? 'Auto-detect lock: TIN line found inside TIN zone'
                                    : 'Auto-detect lock: scanning for TIN line in TIN zone',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: _isAutoTinDetected ? Colors.lightBlue.shade700 : Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _lastTopTinCandidates.isEmpty
                                    ? 'OCR candidates: --'
                                    : 'OCR candidates: ${_lastTopTinCandidates.join(' • ')}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12, color: Colors.black87),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Auto-capture is enabled. Hold steady when both guides turn aligned.',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey.shade800),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _BirTinDetection {
  final String? tin;
  final double score;
  final bool isQualified;
  final bool isGuideAligned;
  final bool isTinZoneAligned;
  final bool hasAutoTinLock;
  final Rect? autoTinRectNormalized;
  final List<_TinCandidateScore> topCandidates;

  const _BirTinDetection({
    required this.tin,
    required this.score,
    required this.isQualified,
    required this.isGuideAligned,
    required this.isTinZoneAligned,
    required this.hasAutoTinLock,
    required this.autoTinRectNormalized,
    required this.topCandidates,
  });
}

class _TinSelection {
  final _TinCandidate? best;
  final List<_TinCandidateScore> ranked;

  const _TinSelection({required this.best, required this.ranked});
}

class _TinCandidateScore {
  final String value;
  final double score;

  const _TinCandidateScore({required this.value, required this.score});
}

class _TinCandidate {
  final String value;
  final Rect? bounds;
  final double contextScore;
  final bool hasLabelContext;
  final bool hasStrongLabelContext;

  const _TinCandidate({
    required this.value,
    required this.bounds,
    required this.contextScore,
    required this.hasLabelContext,
    required this.hasStrongLabelContext,
  });
}

class _OcrLineHit {
  final String text;
  final Rect? bounds;

  const _OcrLineHit({
    required this.text,
    required this.bounds,
  });
}

class _TinGuideOverlay extends StatelessWidget {
  final double documentAspectRatio;
  final double horizontalPadding;
  final double topOffset;
  final double maxHeightFactor;
  final double tinZoneLeftFactor;
  final double tinZoneTopFactor;
  final double tinZoneWidthFactor;
  final double tinZoneHeightFactor;
  final bool isAligned;
  final bool isTinZoneAligned;
  final bool isAutoTinDetected;
  final Rect? autoTinRectNormalized;

  const _TinGuideOverlay({
    required this.documentAspectRatio,
    required this.horizontalPadding,
    required this.topOffset,
    required this.maxHeightFactor,
    required this.tinZoneLeftFactor,
    required this.tinZoneTopFactor,
    required this.tinZoneWidthFactor,
    required this.tinZoneHeightFactor,
    required this.isAligned,
    required this.isTinZoneAligned,
    required this.isAutoTinDetected,
    required this.autoTinRectNormalized,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          final maxWidth = w * (1 - (horizontalPadding * 2));
          final maxHeight = h * maxHeightFactor;
          var boxW = maxWidth;
          var boxH = boxW / documentAspectRatio;

          if (boxH > maxHeight) {
            boxH = maxHeight;
            boxW = boxH * documentAspectRatio;
          }

          final left = (w - boxW) / 2;
          var top = h * topOffset;
          final maxTop = h - boxH - 12;
          if (top > maxTop) {
            top = maxTop;
          }

          final borderColor = isAligned ? Colors.greenAccent : Colors.white;
          final tinZoneLeft = left + (boxW * tinZoneLeftFactor);
          final tinZoneTop = top + (boxH * tinZoneTopFactor);
          final tinZoneW = boxW * tinZoneWidthFactor;
          final tinZoneH = boxH * tinZoneHeightFactor;
          final tinZoneColor = isTinZoneAligned ? Colors.greenAccent : Colors.amberAccent;
          final autoTinColor = isAutoTinDetected ? Colors.lightBlueAccent : Colors.transparent;

          return Stack(
            children: [
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.20)),
              ),
              Positioned(
                left: left,
                top: top,
                width: boxW,
                height: boxH,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: borderColor, width: 3),
                  ),
                ),
              ),
              Positioned(
                left: tinZoneLeft,
                top: tinZoneTop,
                width: tinZoneW,
                height: tinZoneH,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tinZoneColor, width: 2.5),
                  ),
                ),
              ),
              if (autoTinRectNormalized != null)
                Positioned(
                  left: w * autoTinRectNormalized!.left,
                  top: h * autoTinRectNormalized!.top,
                  width: w * autoTinRectNormalized!.width,
                  height: h * autoTinRectNormalized!.height,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: autoTinColor, width: 2),
                    ),
                  ),
                ),
              Positioned(
                left: left,
                top: top - 26,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isAligned ? 'Aligned' : 'Align BIR Notice Here',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              Positioned(
                left: tinZoneLeft,
                top: tinZoneTop - 22,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.50),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    isTinZoneAligned ? 'TIN Zone Aligned' : 'TIN Number Zone',
                    style: TextStyle(
                      color: tinZoneColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              if (autoTinRectNormalized != null)
                Positioned(
                  left: (w * autoTinRectNormalized!.left),
                  top: (h * autoTinRectNormalized!.top) - 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.50),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      isAutoTinDetected ? 'Auto TIN Detected' : 'Auto TIN',
                      style: TextStyle(
                        color: autoTinColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TinCaptureSummaryPage extends StatefulWidget {
  final String imagePath;
  final List<_TinCandidateScore> candidates;

  const _TinCaptureSummaryPage({
    required this.imagePath,
    required this.candidates,
  });

  @override
  State<_TinCaptureSummaryPage> createState() => _TinCaptureSummaryPageState();
}

class _TinCaptureSummaryPageState extends State<_TinCaptureSummaryPage> {
  late final TextEditingController _manualTinController;
  int? _selectedCandidateIndex;

  @override
  void initState() {
    super.initState();
    _manualTinController = TextEditingController(
      text: widget.candidates.isNotEmpty ? widget.candidates.first.value : '',
    );
    if (widget.candidates.isNotEmpty) {
      _selectedCandidateIndex = 0;
    }
  }

  @override
  void dispose() {
    _manualTinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imageFile = File(widget.imagePath);

    return Scaffold(
      appBar: buildBrandedAppBar(
        context: context,
        title: const Text('TIN OCR Summary'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Captured Document',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 260),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: imageFile.existsSync()
                    ? Image.file(imageFile, fit: BoxFit.cover)
                    : Container(
                        color: Colors.grey.shade200,
                        alignment: Alignment.center,
                        child: const Text('Captured image not found.'),
                      ),
              ),
              const SizedBox(height: 14),
              const Text(
                'OCR TIN Candidates',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 6),
              if (widget.candidates.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No OCR candidates found. Type the TIN below.'),
                )
              else
                ...List.generate(widget.candidates.length, (index) {
                  final item = widget.candidates[index];
                  return RadioListTile<int>(
                    value: index,
                    groupValue: _selectedCandidateIndex,
                    contentPadding: EdgeInsets.zero,
                    title: Text(item.value),
                    subtitle: Text('Score: ${(item.score * 100).toStringAsFixed(0)}%'),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _selectedCandidateIndex = value;
                        _manualTinController.text = widget.candidates[value].value;
                      });
                    },
                  );
                }),
              const SizedBox(height: 8),
              TextField(
                controller: _manualTinController,
                keyboardType: TextInputType.text,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9\-\s]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Type TIN Number',
                  hintText: 'e.g. 01-712-781-0000',
                ),
                onChanged: (_) {
                  setState(() {
                    _selectedCandidateIndex = null;
                  });
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retake'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final input = _manualTinController.text.trim();
                        if (input.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please select or type a TIN number.')),
                          );
                          return;
                        }
                        Navigator.pop(context, input);
                      },
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Use This TIN'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
