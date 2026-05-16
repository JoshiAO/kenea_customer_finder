import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/customer.dart';
import '../services/database_service.dart';
import '../services/app_customization_notifier.dart';
import '../services/routing_service.dart';
import '../pages/customer_update_form.dart';
import '../pages/capture_images_flow_page.dart';
import 'branded_app_bar.dart';

LocationSettings buildTrackingLocationSettings() {
  if (kIsWeb) {
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    );
  }

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: true,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Live tracking active',
          notificationText: 'Updating your location while tracking is on.',
          enableWakeLock: true,
        ),
      );
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
      );
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
      );
  }
}

class CustomerInfoModal extends StatefulWidget {
  final Customer customer;

  const CustomerInfoModal({super.key, required this.customer});

  @override
  State<CustomerInfoModal> createState() => _CustomerInfoModalState();
}

class _LocationAccessException implements Exception {
  const _LocationAccessException(
    this.message, {
    this.canOpenAppSettings = false,
    this.canOpenLocationSettings = false,
  });

  final String message;
  final bool canOpenAppSettings;
  final bool canOpenLocationSettings;

  @override
  String toString() => message;
}

class _CustomerInfoModalState extends State<CustomerInfoModal> with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  final RoutingService _routingService = const RoutingService();
  late final AnimationController _markerAnimationController;
  static const double _trackingZoom = 16.5;
  static const Duration _routeRefreshInterval = Duration(seconds: 6);
  static const double _routeRefreshDistanceMeters = 20;
  static const double _offRouteDistanceMeters = 28;
  static const Duration _streamStallThreshold = Duration(seconds: 8);
  static const Duration _streamHealthCheckInterval = Duration(seconds: 4);

  StreamSubscription<Position>? _trackingSubscription;
  Timer? _trackingHealthCheckTimer;
  DateTime? _lastTrackingEventAt;
  bool _isFallbackReadingPosition = false;
  Position? _trackedPosition;
  LatLng? _animatedTrackedLatLng;
  LatLng? _animationStartPoint;
  LatLng? _animationEndPoint;
  bool _isTracking = false;
  bool _isTrackingBusy = false;
  String? _trackingError;
  bool _isRouteLoading = false;
  String? _routeError;
  String? _routeProvider;
  List<LatLng> _routePoints = [];
  double? _routeDistanceMeters;
  double? _routeDurationSeconds;
  Position? _lastRouteOrigin;
  DateTime? _lastRouteFetchAt;

  bool get _hasCustomerLocation => widget.customer.latitude != null && widget.customer.longitude != null;

  LatLng get _customerLatLng => LatLng(widget.customer.latitude!, widget.customer.longitude!);

  void _cancelTrackingResources() {
    _trackingSubscription?.cancel();
    _trackingSubscription = null;
    _trackingHealthCheckTimer?.cancel();
    _trackingHealthCheckTimer = null;
  }

  Future<Position?> _readCurrentPositionFast() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  void _startTrackingHealthCheck() {
    _trackingHealthCheckTimer?.cancel();
    _trackingHealthCheckTimer = Timer.periodic(_streamHealthCheckInterval, (_) async {
      if (!mounted || !_isTracking) return;
      final lastEventAt = _lastTrackingEventAt;
      if (lastEventAt == null) return;
      if (DateTime.now().difference(lastEventAt) < _streamStallThreshold) return;
      if (_isFallbackReadingPosition) return;

      _isFallbackReadingPosition = true;
      try {
        final fallbackPosition = await _readCurrentPositionFast();
        if (!mounted || !_isTracking || fallbackPosition == null) return;

        _lastTrackingEventAt = DateTime.now();
        setState(() {
          _trackedPosition = fallbackPosition;
        });
        _animateToTrackedPosition(fallbackPosition);
        unawaited(_fetchRoadRoute(origin: fallbackPosition));
      } finally {
        _isFallbackReadingPosition = false;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _markerAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..addListener(_onMarkerAnimationTick);
  }

  String _appendEditedField(String field) {
    final current = (widget.customer.editedFields ?? '').trim();
    if (current.isEmpty) return field;
    if (current.split(',').map((e) => e.trim()).contains(field)) return current;
    return '$current, $field';
  }

  Future<void> _showLocationAccessDialog(_LocationAccessException error) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Location Access Needed'),
          content: Text(error.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            if (error.canOpenLocationSettings)
              TextButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await Geolocator.openLocationSettings();
                },
                child: const Text('Enable GPS'),
              ),
            if (error.canOpenAppSettings)
              TextButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await Geolocator.openAppSettings();
                },
                child: const Text('Open Settings'),
              ),
          ],
        );
      },
    );
  }

  Future<Position> _determinePosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw const _LocationAccessException(
        'Location services are disabled. Please enable GPS/location services.',
        canOpenLocationSettings: true,
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw const _LocationAccessException(
          'Location permission was denied. Please allow location access to use live tracking and capture location.',
          canOpenAppSettings: true,
        );
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw const _LocationAccessException(
        'Location permission is permanently denied. Please allow location in app settings.',
        canOpenAppSettings: true,
      );
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } on TimeoutException {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) return lastKnown;
      rethrow;
    }
  }

  void _applyTrackedPosition(Position position, {bool recenter = false, bool forceRoute = false}) {
    if (!mounted) return;

    final nextLatLng = LatLng(position.latitude, position.longitude);
    setState(() {
      _trackedPosition = position;
      _animatedTrackedLatLng ??= nextLatLng;
    });

    _animateToTrackedPosition(position);
    if (recenter) {
      _centerMapOnTrackedPosition();
    }
    unawaited(_fetchRoadRoute(origin: position, force: forceRoute));
  }

  double? get _distanceToCustomerMeters {
    if (!_hasCustomerLocation || _trackedPosition == null) return null;
    return Geolocator.distanceBetween(
      _trackedPosition!.latitude,
      _trackedPosition!.longitude,
      widget.customer.latitude!,
      widget.customer.longitude!,
    );
  }

  double? get _bearingToCustomer {
    if (!_hasCustomerLocation || _trackedPosition == null) return null;
    return Geolocator.bearingBetween(
      _trackedPosition!.latitude,
      _trackedPosition!.longitude,
      widget.customer.latitude!,
      widget.customer.longitude!,
    );
  }

  String _bearingLabel(double degrees) {
    const labels = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final normalized = (degrees % 360 + 360) % 360;
    final index = ((normalized / 45).round()) % labels.length;
    return labels[index];
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(2)} km';
    }
    return '${meters.toStringAsFixed(0)} m';
  }

  Duration _adaptiveRefreshIntervalFor(Position origin) {
    final speedMps = origin.speed < 0 ? 0.0 : origin.speed;
    if (speedMps >= 10) return const Duration(seconds: 3);
    if (speedMps >= 5) return const Duration(seconds: 4);
    return _routeRefreshInterval;
  }

  double _adaptiveRefreshDistanceFor(Position origin) {
    final speedMps = origin.speed < 0 ? 0.0 : origin.speed;
    if (speedMps >= 10) return 12;
    if (speedMps >= 5) return 16;
    return _routeRefreshDistanceMeters;
  }

  double? _distanceToPolylineMeters(LatLng point, List<LatLng> polyline) {
    if (polyline.length < 2) return null;

    double toMetersX(double lng, double refLat) => lng * 111320.0 * math.cos(refLat * math.pi / 180.0);
    double toMetersY(double lat) => lat * 110540.0;

    final px = toMetersX(point.longitude, point.latitude);
    final py = toMetersY(point.latitude);

    double minDistance = double.infinity;

    for (var i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];

      final ax = toMetersX(a.longitude, point.latitude);
      final ay = toMetersY(a.latitude);
      final bx = toMetersX(b.longitude, point.latitude);
      final by = toMetersY(b.latitude);

      final abx = bx - ax;
      final aby = by - ay;
      final apx = px - ax;
      final apy = py - ay;
      final abLenSq = abx * abx + aby * aby;
      if (abLenSq == 0) continue;

      final t = (apx * abx + apy * aby) / abLenSq;
      final clampedT = t.clamp(0.0, 1.0);
      final cx = ax + abx * clampedT;
      final cy = ay + aby * clampedT;

      final dx = px - cx;
      final dy = py - cy;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance < minDistance) {
        minDistance = distance;
      }
    }

    return minDistance.isFinite ? minDistance : null;
  }

  bool _isLikelyOffRoute(Position origin) {
    if (_routePoints.length < 2) return false;
    final distance = _distanceToPolylineMeters(
      LatLng(origin.latitude, origin.longitude),
      _routePoints,
    );
    return distance != null && distance > _offRouteDistanceMeters;
  }

  bool _shouldRefreshRoute(Position origin, {bool isOffRoute = false}) {
    if (_lastRouteOrigin == null || _lastRouteFetchAt == null) return true;
    if (isOffRoute) return true;

    final elapsed = DateTime.now().difference(_lastRouteFetchAt!);
    final refreshInterval = _adaptiveRefreshIntervalFor(origin);
    if (elapsed < refreshInterval) return false;

    final moved = Geolocator.distanceBetween(
      _lastRouteOrigin!.latitude,
      _lastRouteOrigin!.longitude,
      origin.latitude,
      origin.longitude,
    );
    return moved >= _adaptiveRefreshDistanceFor(origin);
  }

  Future<void> _fetchRoadRoute({required Position origin, bool force = false}) async {
    if (!_hasCustomerLocation || _isRouteLoading) return;
    final isOffRoute = _isLikelyOffRoute(origin);
    if (!force && !_shouldRefreshRoute(origin, isOffRoute: isOffRoute)) return;

    if (mounted) {
      setState(() {
        _isRouteLoading = true;
        _routeError = null;
      });
    }

    try {
      final route = await _routingService.getDrivingRoute(
        origin: LatLng(origin.latitude, origin.longitude),
        destination: _customerLatLng,
      );

      if (!mounted) return;
      setState(() {
        _routePoints = route.points;
        _routeDistanceMeters = route.distanceMeters;
        _routeDurationSeconds = route.durationSeconds;
        _routeProvider = route.provider;
        _routeError = null;
      });
      _lastRouteOrigin = origin;
      _lastRouteFetchAt = DateTime.now();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _routeError = e.toString();
        _routeProvider = null;
        _routePoints = [];
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRouteLoading = false;
        });
      }
    }
  }

  void _onMarkerAnimationTick() {
    final from = _animationStartPoint;
    final to = _animationEndPoint;
    if (from == null || to == null || !mounted) return;

    final t = Curves.easeOutCubic.transform(_markerAnimationController.value);
    final lat = from.latitude + (to.latitude - from.latitude) * t;
    final lng = from.longitude + (to.longitude - from.longitude) * t;
    final next = LatLng(lat, lng);

    setState(() {
      _animatedTrackedLatLng = next;
    });

    if (_isTracking) {
      _mapController.move(next, _trackingZoom);
    }
  }

  void _animateToTrackedPosition(Position position) {
    final target = LatLng(position.latitude, position.longitude);
    final start = _animatedTrackedLatLng ?? target;
    final moved = Geolocator.distanceBetween(
      start.latitude,
      start.longitude,
      target.latitude,
      target.longitude,
    );

    if (moved < 0.5) {
      if (!mounted) return;
      setState(() {
        _animatedTrackedLatLng = target;
      });
      return;
    }

    _animationStartPoint = start;
    _animationEndPoint = target;
    _markerAnimationController.forward(from: 0);
  }

  void _centerMapOnTrackedPosition() {
    final point = _animatedTrackedLatLng ??
        (_trackedPosition == null ? null : LatLng(_trackedPosition!.latitude, _trackedPosition!.longitude));
    if (point == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.move(point, _trackingZoom);
    });
  }

  Future<void> _refreshMapView() async {
    if (!_hasCustomerLocation) return;

    if (_trackedPosition != null) {
      _centerMapOnTrackedPosition();
      await _fetchRoadRoute(origin: _trackedPosition!, force: true);
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.move(_customerLatLng, 15.0);
    });
  }

  Future<void> _openFullScreenMap() async {
    if (!_hasCustomerLocation) return;

    final trackedLatLng = _trackedPosition == null
        ? null
        : LatLng(_trackedPosition!.latitude, _trackedPosition!.longitude);
    final distanceToCustomer = _routeDistanceMeters ?? _distanceToCustomerMeters;
    final bearingToCustomer = _bearingToCustomer;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullScreenDirectionMap(
          customerLatLng: _customerLatLng,
          trackedLatLng: trackedLatLng,
          routePoints: List<LatLng>.from(_routePoints),
          isTracking: _isTracking,
          isRouteLoading: _isRouteLoading,
          routeError: _routeError,
          routeProvider: _routeProvider,
          distanceMeters: distanceToCustomer,
          durationSeconds: _routeDurationSeconds,
          bearingDegrees: bearingToCustomer,
        ),
      ),
    );
  }

  Future<void> _stopTracking({bool clearError = false}) async {
    _cancelTrackingResources();
    if (!mounted) return;
    setState(() {
      _isTracking = false;
      _isRouteLoading = false;
      _routeProvider = null;
      if (clearError) {
        _trackingError = null;
        _routeError = null;
      }
    });
  }

  Future<void> _toggleTracking() async {
    if (!_hasCustomerLocation) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tracking is unavailable because this customer has no saved coordinates.')),
      );
      return;
    }

    if (_isTracking) {
      await _stopTracking(clearError: true);
      return;
    }

    setState(() {
      _isTrackingBusy = true;
      _trackingError = null;
    });

    try {
      _trackingSubscription = Geolocator.getPositionStream(
        locationSettings: buildTrackingLocationSettings(),
      ).listen(
        (position) {
          if (!mounted) return;
          _lastTrackingEventAt = DateTime.now();
          _applyTrackedPosition(position);
        },
        onError: (Object error) async {
          if (!mounted) return;
          await _stopTracking();
          if (!mounted) return;
          setState(() {
            _trackingError = error.toString();
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _isTracking = true;
      });

      _startTrackingHealthCheck();

      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && mounted && _isTracking) {
        _lastTrackingEventAt = DateTime.now();
        _applyTrackedPosition(lastKnown, recenter: true, forceRoute: true);
      }

      final initialPosition = await _determinePosition();
      if (!mounted || !_isTracking) return;
      _lastTrackingEventAt = DateTime.now();
      _applyTrackedPosition(initialPosition, recenter: lastKnown == null, forceRoute: true);
    } catch (e) {
      if (!mounted) return;
      await _stopTracking();
      if (!mounted) return;
      setState(() {
        _trackingError = e.toString();
      });
      if (e is _LocationAccessException) {
        await _showLocationAccessDialog(e);
        if (!mounted) return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to start tracking: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isTrackingBusy = false;
        });
      }
    }
  }

  Future<void> _saveCapturedImagesForCustomer(List<File> images) async {
    final appDir = await getApplicationDocumentsDirectory();
    final folderName = DatabaseService.customerImageFolderName(widget.customer);
    final folderPath = p.join(appDir.path, 'captured_images', folderName);
    final targetDir = Directory(folderPath);

    if (await targetDir.exists()) {
      final existing = targetDir
          .listSync()
          .whereType<File>()
          .where((file) => p.basename(file.path).toLowerCase().startsWith('image_'))
          .toList();
      for (final file in existing) {
        await file.delete();
      }
    } else {
      await targetDir.create(recursive: true);
    }

    for (var i = 0; i < images.length; i++) {
      final src = images[i];
      final ext = p.extension(src.path).isEmpty ? '.jpg' : p.extension(src.path);
      final destination = p.join(targetDir.path, 'image_${i + 1}$ext');
      await src.copy(destination);
    }
  }

  @override
  void dispose() {
    _cancelTrackingResources();
    _markerAnimationController.removeListener(_onMarkerAnimationTick);
    _markerAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isJoshiTheme = context.watch<AppCustomizationNotifier>().isJoshiAOTheme;
    final tileUrlTemplate = isJoshiTheme
        ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
        : 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png';
    const labelsUrlTemplate = 'https://{s}.basemaps.cartocdn.com/light_only_labels/{z}/{x}/{y}.png';
    final routeColor = isJoshiTheme
      ? const Color(0xFF47E6FF)
      : Theme.of(context).colorScheme.primary;
    final userMarkerColor = isJoshiTheme
      ? const Color(0xFF00E5FF)
      : Theme.of(context).colorScheme.primary;
    final customerPinColor = isJoshiTheme ? const Color(0xFFFF7A7A) : Colors.red;
    final trackedLatLng = _animatedTrackedLatLng ??
      (_trackedPosition == null ? null : LatLng(_trackedPosition!.latitude, _trackedPosition!.longitude));
    final distanceToCustomer = _routeDistanceMeters ?? _distanceToCustomerMeters;
    final bearingToCustomer = _bearingToCustomer;

    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _cancelTrackingResources();
        }
      },
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
        children: [
          Expanded(
            flex: 2,
            child: _hasCustomerLocation
                ? Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _customerLatLng,
                          initialZoom: 15.0,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: tileUrlTemplate,
                            subdomains: const ['a', 'b', 'c', 'd'],
                            userAgentPackageName: 'com.example.kenea_customers',
                          ),
                          if (isJoshiTheme)
                            TileLayer(
                              urlTemplate: labelsUrlTemplate,
                              subdomains: const ['a', 'b', 'c', 'd'],
                              userAgentPackageName: 'com.example.kenea_customers',
                            ),
                          if (trackedLatLng != null)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: _routePoints.length >= 2 ? _routePoints : [_customerLatLng, trackedLatLng],
                                  strokeWidth: 4,
                                  color: routeColor,
                                ),
                              ],
                            ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: _customerLatLng,
                                rotate: true,
                                child: Icon(
                                  Icons.location_pin,
                                  color: customerPinColor,
                                  size: 40,
                                ),
                              ),
                              if (trackedLatLng != null)
                                Marker(
                                  point: trackedLatLng,
                                  rotate: true,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: userMarkerColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 2),
                                      boxShadow: [
                                        BoxShadow(
                                          color: isJoshiTheme
                                              ? const Color(0x8800E5FF)
                                              : const Color(0x33000000),
                                          blurRadius: isJoshiTheme ? 12 : 8,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: const SizedBox(width: 18, height: 18),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Material(
                          color: Colors.black.withAlpha(145),
                          borderRadius: BorderRadius.circular(8),
                          child: IconButton(
                            onPressed: _refreshMapView,
                            icon: const Icon(Icons.refresh, color: Colors.white),
                            tooltip: 'Refresh Map View',
                          ),
                        ),
                      ),
                      if (_isTracking || _trackingError != null)
                        Positioned(
                          top: 60,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black.withAlpha(150),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: DefaultTextStyle(
                              style: const TextStyle(color: Colors.white, fontSize: 11),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_isTracking ? 'Tracking: ON' : 'Tracking: OFF'),
                                  if (_isRouteLoading)
                                    const Text('Route: updating...'),
                                  if (distanceToCustomer != null)
                                    Text('Distance: ${_formatDistance(distanceToCustomer)}'),
                                  if (_routeDurationSeconds != null)
                                    Text('ETA: ${(_routeDurationSeconds! / 60).toStringAsFixed(0)} min'),
                                  if (_routeProvider != null)
                                    Text('Route source: $_routeProvider'),
                                  if (bearingToCustomer != null)
                                    Text(
                                      'Direction: ${bearingToCustomer.toStringAsFixed(0)}° ${_bearingLabel(bearingToCustomer)}',
                                    ),
                                  if (_routeError != null)
                                    const Text('Route: unavailable, using straight line'),
                                  if (_trackingError != null)
                                    Text('Error: $_trackingError'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(140),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Customer\nLat: ${widget.customer.latitude!.toStringAsFixed(6)}\nLng: ${widget.customer.longitude!.toStringAsFixed(6)}',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontFeatures: []),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Material(
                          color: Colors.black.withAlpha(145),
                          borderRadius: BorderRadius.circular(8),
                          child: IconButton(
                            onPressed: _openFullScreenMap,
                            icon: const Icon(Icons.fullscreen, color: Colors.white),
                            tooltip: 'Open Full Screen Map',
                          ),
                        ),
                      ),
                    ],
                  )
                : Center(child: Text('No Long-Lat Data')),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.35)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Customer Code: ${widget.customer.customerCode}'),
                        Text('Name: ${widget.customer.customerName}'),
                        Text('Phone: ${widget.customer.phone}'),
                        Text('First Name: ${widget.customer.firstName}'),
                        Text('Last Name: ${widget.customer.lastName}'),
                        Text('TIN No: ${widget.customer.tinNo}'),
                        Text('Address: ${widget.customer.address}'),
                        Text('Party Classification: ${widget.customer.partyClassificationDescription}'),
                        Text('Coverage Day: ${widget.customer.coverageDay}'),
                        Text('Wkly Coverage: ${widget.customer.wklyCoverage}'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final buttonWidth = (constraints.maxWidth - 12) / 2;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: buttonWidth,
                            child: ElevatedButton.icon(
                              onPressed: (!_hasCustomerLocation || _isTrackingBusy) ? null : _toggleTracking,
                              icon: Icon(_isTracking ? Icons.location_disabled : Icons.assistant_navigation),
                              label: Text(_isTracking ? 'Stop Tracking' : 'Live Tracking'),
                            ),
                          ),
                          SizedBox(
                            width: buttonWidth,
                            child: ElevatedButton.icon(
                              onPressed: _captureLocation,
                              icon: const Icon(Icons.my_location),
                              label: const Text('Capture Location'),
                            ),
                          ),
                          SizedBox(
                            width: buttonWidth,
                            child: ElevatedButton.icon(
                              onPressed: _updateStatus,
                              icon: const Icon(Icons.toggle_on_outlined),
                              label: const Text('Update Status'),
                            ),
                          ),
                          SizedBox(
                            width: buttonWidth,
                            child: ElevatedButton.icon(
                              onPressed: _updateInfo,
                              icon: const Icon(Icons.edit_note),
                              label: const Text('Update Info'),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  void _captureLocation() async {
    try {
      final images = await Navigator.push<List<File>>(
        context,
        MaterialPageRoute(builder: (_) => const CaptureImagesFlowPage()),
      );

      if (!mounted || images == null || images.length != 3) {
        return;
      }

      final position = await _determinePosition();
      if (!mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Submit Location'),
          content: Text(
            'Images captured: 3/3\n\n'
            'Latitude: ${position.latitude.toStringAsFixed(6)}\n'
            'Longitude: ${position.longitude.toStringAsFixed(6)}\n\n'
            'Proceed to record/upload this location?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Submit Images'),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      await _saveCapturedImagesForCustomer(images);

      final updated = widget.customer.copyWith(
        latitude: position.latitude,
        longitude: position.longitude,
        editedFields: _appendEditedField('location'),
      );
      await DatabaseService().updateCustomer(updated);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Location recorded with Lat ${position.latitude.toStringAsFixed(6)}, '
            'Lng ${position.longitude.toStringAsFixed(6)}.',
          ),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      if (e is _LocationAccessException) {
        await _showLocationAccessDialog(e);
        if (!mounted) return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: $e')),
      );
    }
  }

  void _updateStatus() {
    String currentStatus = widget.customer.status;
    showDialog(
      context: context,
      builder: (dialogContext) {
        final dialogNavigator = Navigator.of(dialogContext);
        final pageNavigator = Navigator.of(context);
        return AlertDialog(
          title: Text('Update Status'),
          content: StatefulBuilder(
            builder: (context, setDialogState) {
              return DropdownButtonFormField<String>(
                initialValue: currentStatus,
                items: ['Active/Approved', 'Blocked/On hold'].map((status) {
                  return DropdownMenuItem(value: status, child: Text(status));
                }).toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setDialogState(() {
                    currentStatus = value;
                  });
                },
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => dialogNavigator.pop(),
              child: Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Customer updated = widget.customer.copyWith(
                  status: currentStatus,
                  editedFields: _appendEditedField('status'),
                );
                await DatabaseService().updateCustomer(updated);
                if (!mounted) return;
                dialogNavigator.pop();
                pageNavigator.pop(true);
              },
              child: Text('Submit'),
            ),
          ],
        );
      },
    );
  }

  void _updateInfo() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CustomerUpdateForm(customer: widget.customer),
      ),
    );
  }
}

class _FullScreenDirectionMap extends StatefulWidget {
  const _FullScreenDirectionMap({
    required this.customerLatLng,
    required this.trackedLatLng,
    required this.routePoints,
    required this.isTracking,
    required this.isRouteLoading,
    required this.routeError,
    required this.routeProvider,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.bearingDegrees,
  });

  final LatLng customerLatLng;
  final LatLng? trackedLatLng;
  final List<LatLng> routePoints;
  final bool isTracking;
  final bool isRouteLoading;
  final String? routeError;
  final String? routeProvider;
  final double? distanceMeters;
  final double? durationSeconds;
  final double? bearingDegrees;

  @override
  State<_FullScreenDirectionMap> createState() => _FullScreenDirectionMapState();
}

class _FullScreenDirectionMapState extends State<_FullScreenDirectionMap> with SingleTickerProviderStateMixin {
  static const double _trackingZoom = 16.5;
  static const Duration _routeRefreshInterval = Duration(seconds: 6);
  static const double _routeRefreshDistanceMeters = 20;
  static const double _offRouteDistanceMeters = 28;
  static const double _navigationAnchorYOffset = 180;
  static const Duration _streamStallThreshold = Duration(seconds: 8);
  static const Duration _streamHealthCheckInterval = Duration(seconds: 4);

  final MapController _mapController = MapController();
  final RoutingService _routingService = const RoutingService();
  late final AnimationController _markerAnimationController;

  StreamSubscription<Position>? _trackingSubscription;
  Timer? _trackingHealthCheckTimer;
  DateTime? _lastTrackingEventAt;
  bool _isFallbackReadingPosition = false;
  LatLng? _animatedTrackedLatLng;
  LatLng? _animationStartPoint;
  LatLng? _animationEndPoint;
  LatLng? _lastRouteOrigin;
  DateTime? _lastRouteFetchAt;
  String? _trackingError;
  double? _liveDistanceMeters;
  double? _liveBearingDegrees;
  double? _liveDurationSeconds;
  bool _isLiveRouteLoading = false;
  String? _liveRouteError;
  String? _liveRouteProvider;
  List<LatLng> _liveRoutePoints = [];
  List<String> _liveRoadSuggestions = [];
  bool _isCameraFollowEnabled = true;
  bool _isNavigationViewEnabled = false;

  @override
  void initState() {
    super.initState();
    _animatedTrackedLatLng = widget.trackedLatLng;
    _liveDistanceMeters = widget.distanceMeters;
    _liveBearingDegrees = widget.bearingDegrees;
    _liveDurationSeconds = widget.durationSeconds;
    _liveRoutePoints = List<LatLng>.from(widget.routePoints);
    _liveRouteProvider = widget.routeProvider;
    _isCameraFollowEnabled = widget.isTracking;
    _isNavigationViewEnabled = false;

    _markerAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..addListener(_onMarkerAnimationTick);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final trackedLatLng = _animatedTrackedLatLng;
      if (trackedLatLng != null && _isCameraFollowEnabled) {
        _updateFollowCamera(trackedLatLng);
      } else {
        _mapController.move(trackedLatLng ?? widget.customerLatLng, trackedLatLng == null ? 15.0 : 16.5);
      }
    });

    if (widget.isTracking) {
      _startLiveTracking();
    }
  }

  Future<void> _startLiveTracking() async {
    await _trackingSubscription?.cancel();
    _lastTrackingEventAt = DateTime.now();
    _startTrackingHealthCheck();
    _trackingSubscription = Geolocator.getPositionStream(
      locationSettings: buildTrackingLocationSettings(),
    ).listen(
      (position) {
        _lastTrackingEventAt = DateTime.now();
        _trackingError = null;
        _animateTo(LatLng(position.latitude, position.longitude));
        unawaited(_fetchLiveRoute(position));
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _trackingError = error.toString();
        });
      },
    );
  }

  Future<Position?> _readCurrentPositionFast() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  void _startTrackingHealthCheck() {
    _trackingHealthCheckTimer?.cancel();
    _trackingHealthCheckTimer = Timer.periodic(_streamHealthCheckInterval, (_) async {
      if (!mounted || !widget.isTracking) return;
      final lastEventAt = _lastTrackingEventAt;
      if (lastEventAt == null) return;
      if (DateTime.now().difference(lastEventAt) < _streamStallThreshold) return;
      if (_isFallbackReadingPosition) return;

      _isFallbackReadingPosition = true;
      try {
        final fallbackPosition = await _readCurrentPositionFast();
        if (!mounted || !widget.isTracking || fallbackPosition == null) return;

        _lastTrackingEventAt = DateTime.now();
        _trackingError = null;
        _animateTo(LatLng(fallbackPosition.latitude, fallbackPosition.longitude));
        unawaited(_fetchLiveRoute(fallbackPosition));
      } finally {
        _isFallbackReadingPosition = false;
      }
    });
  }

  Duration _adaptiveRefreshIntervalFor(Position origin) {
    final speedMps = origin.speed < 0 ? 0.0 : origin.speed;
    if (speedMps >= 10) return const Duration(seconds: 3);
    if (speedMps >= 5) return const Duration(seconds: 4);
    return _routeRefreshInterval;
  }

  double _adaptiveRefreshDistanceFor(Position origin) {
    final speedMps = origin.speed < 0 ? 0.0 : origin.speed;
    if (speedMps >= 10) return 12;
    if (speedMps >= 5) return 16;
    return _routeRefreshDistanceMeters;
  }

  double? _distanceToPolylineMeters(LatLng point, List<LatLng> polyline) {
    if (polyline.length < 2) return null;

    double toMetersX(double lng, double refLat) => lng * 111320.0 * math.cos(refLat * math.pi / 180.0);
    double toMetersY(double lat) => lat * 110540.0;

    final px = toMetersX(point.longitude, point.latitude);
    final py = toMetersY(point.latitude);

    double minDistance = double.infinity;

    for (var i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];

      final ax = toMetersX(a.longitude, point.latitude);
      final ay = toMetersY(a.latitude);
      final bx = toMetersX(b.longitude, point.latitude);
      final by = toMetersY(b.latitude);

      final abx = bx - ax;
      final aby = by - ay;
      final apx = px - ax;
      final apy = py - ay;
      final abLenSq = abx * abx + aby * aby;
      if (abLenSq == 0) continue;

      final t = (apx * abx + apy * aby) / abLenSq;
      final clampedT = t.clamp(0.0, 1.0);
      final cx = ax + abx * clampedT;
      final cy = ay + aby * clampedT;

      final dx = px - cx;
      final dy = py - cy;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance < minDistance) {
        minDistance = distance;
      }
    }

    return minDistance.isFinite ? minDistance : null;
  }

  bool _isLikelyOffRoute(Position origin) {
    if (_liveRoutePoints.length < 2) return false;
    final distance = _distanceToPolylineMeters(
      LatLng(origin.latitude, origin.longitude),
      _liveRoutePoints,
    );
    return distance != null && distance > _offRouteDistanceMeters;
  }

  bool _shouldRefreshRoute(Position origin, {bool isOffRoute = false}) {
    if (_lastRouteOrigin == null || _lastRouteFetchAt == null) return true;
    if (isOffRoute) return true;

    final elapsed = DateTime.now().difference(_lastRouteFetchAt!);
    final refreshInterval = _adaptiveRefreshIntervalFor(origin);
    if (elapsed < refreshInterval) return false;

    final moved = Geolocator.distanceBetween(
      _lastRouteOrigin!.latitude,
      _lastRouteOrigin!.longitude,
      origin.latitude,
      origin.longitude,
    );
    return moved >= _adaptiveRefreshDistanceFor(origin);
  }

  Future<void> _fetchLiveRoute(Position origin, {bool force = false}) async {
    if (_isLiveRouteLoading) return;
    final isOffRoute = _isLikelyOffRoute(origin);
    if (!force && !_shouldRefreshRoute(origin, isOffRoute: isOffRoute)) return;

    if (mounted) {
      setState(() {
        _isLiveRouteLoading = true;
        _liveRouteError = null;
      });
    }

    try {
      final route = await _routingService.getDrivingRoute(
        origin: LatLng(origin.latitude, origin.longitude),
        destination: widget.customerLatLng,
      );

      if (!mounted) return;
      setState(() {
        _liveRoutePoints = route.points;
        _liveDistanceMeters = route.distanceMeters ?? _liveDistanceMeters;
        _liveDurationSeconds = route.durationSeconds ?? _liveDurationSeconds;
        _liveRouteProvider = route.provider;
        _liveRoadSuggestions = route.suggestions;
        _liveRouteError = null;
      });
      if (_isCameraFollowEnabled && _isNavigationViewEnabled && _animatedTrackedLatLng != null) {
        _updateFollowCamera(_animatedTrackedLatLng!);
      }
      _lastRouteOrigin = LatLng(origin.latitude, origin.longitude);
      _lastRouteFetchAt = DateTime.now();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _liveRouteError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLiveRouteLoading = false;
        });
      }
    }
  }

  void _focusOnUser() {
    final trackedLatLng = _animatedTrackedLatLng;
    if (trackedLatLng == null) return;
    _updateFollowCamera(trackedLatLng);
  }

  void _fitUserAndCustomer() {
    final trackedLatLng = _animatedTrackedLatLng;
    if (trackedLatLng == null) {
      _mapController.move(widget.customerLatLng, 15.0);
      return;
    }

    final bounds = LatLngBounds.fromPoints([trackedLatLng, widget.customerLatLng]);
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(56),
      ),
    );
  }

  Offset _navigationAnchorOffset() => const Offset(0, _navigationAnchorYOffset);

  List<LatLng> _buildDisplayedRoutePoints(LatLng trackedLatLng) {
    final routePoints = _liveRoutePoints;
    if (routePoints.length >= 2) {
      return List<LatLng>.from(routePoints)..[0] = trackedLatLng;
    }
    return [trackedLatLng, widget.customerLatLng];
  }

  LatLng _navigationLookAheadTarget(LatLng trackedLatLng) {
    final displayedPoints = _buildDisplayedRoutePoints(trackedLatLng);
    for (final point in displayedPoints.skip(1)) {
      final distance = Geolocator.distanceBetween(
        trackedLatLng.latitude,
        trackedLatLng.longitude,
        point.latitude,
        point.longitude,
      );
      if (distance >= 20) {
        return point;
      }
    }
    return widget.customerLatLng;
  }

  double _navigationRotation(LatLng trackedLatLng) {
    final target = _navigationLookAheadTarget(trackedLatLng);
    final bearing = Geolocator.bearingBetween(
      trackedLatLng.latitude,
      trackedLatLng.longitude,
      target.latitude,
      target.longitude,
    );
    return (360 - bearing) % 360;
  }

  void _updateFollowCamera(LatLng trackedLatLng) {
    if (!_isCameraFollowEnabled) return;

    if (_isNavigationViewEnabled) {
      final offset = _navigationAnchorOffset();
      final rotation = _navigationRotation(trackedLatLng);
      _mapController.move(trackedLatLng, _trackingZoom, offset: offset);
      _mapController.rotateAroundPoint(rotation, offset: offset);
      return;
    }

    _mapController.moveAndRotate(trackedLatLng, _trackingZoom, 0);
  }

  void _animateTo(LatLng target) {
    final start = _animatedTrackedLatLng ?? target;
    final moved = Geolocator.distanceBetween(
      start.latitude,
      start.longitude,
      target.latitude,
      target.longitude,
    );

    _liveDistanceMeters = Geolocator.distanceBetween(
      target.latitude,
      target.longitude,
      widget.customerLatLng.latitude,
      widget.customerLatLng.longitude,
    );
    _liveBearingDegrees = Geolocator.bearingBetween(
      target.latitude,
      target.longitude,
      widget.customerLatLng.latitude,
      widget.customerLatLng.longitude,
    );

    if (moved < 0.5) {
      if (!mounted) return;
      setState(() {
        _animatedTrackedLatLng = target;
      });
      if (_isCameraFollowEnabled) {
        _updateFollowCamera(target);
      }
      return;
    }

    _animationStartPoint = start;
    _animationEndPoint = target;
    _markerAnimationController.forward(from: 0);
  }

  void _onMarkerAnimationTick() {
    final from = _animationStartPoint;
    final to = _animationEndPoint;
    if (from == null || to == null || !mounted) return;

    final t = Curves.easeOutCubic.transform(_markerAnimationController.value);
    final next = LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );

    setState(() {
      _animatedTrackedLatLng = next;
    });
    if (_isCameraFollowEnabled) {
      _updateFollowCamera(next);
    }
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(2)} km';
    }
    return '${meters.toStringAsFixed(0)} m';
  }

  String _bearingLabel(double degrees) {
    const labels = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final normalized = (degrees % 360 + 360) % 360;
    final index = ((normalized / 45).round()) % labels.length;
    return labels[index];
  }

  @override
  Widget build(BuildContext context) {
    final isJoshiTheme = context.watch<AppCustomizationNotifier>().isJoshiAOTheme;
    final tileUrlTemplate = isJoshiTheme
        ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
        : 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png';
    const labelsUrlTemplate = 'https://{s}.basemaps.cartocdn.com/light_only_labels/{z}/{x}/{y}.png';
    final routeColor = isJoshiTheme
      ? const Color(0xFF47E6FF)
      : Theme.of(context).colorScheme.primary;
    final userMarkerColor = isJoshiTheme
      ? const Color(0xFF00E5FF)
      : Theme.of(context).colorScheme.primary;
    final customerPinColor = isJoshiTheme ? const Color(0xFFFF7A7A) : Colors.red;
    final trackedLatLng = _animatedTrackedLatLng;
    final customerLatLng = widget.customerLatLng;
    final linePoints = trackedLatLng == null
        ? <LatLng>[]
        : _buildDisplayedRoutePoints(trackedLatLng);
    final distanceMeters = _liveDistanceMeters;
    final bearingDegrees = _liveBearingDegrees;
    final durationSeconds = _liveDurationSeconds ?? widget.durationSeconds;
    final routeProvider = _liveRouteProvider ?? widget.routeProvider;
    final routeError = _liveRouteError ?? widget.routeError;
    final interactionFlags = widget.isTracking && _isCameraFollowEnabled
        ? InteractiveFlag.none
        : InteractiveFlag.all;

    return Scaffold(
      appBar: buildBrandedAppBar(
        context: context,
        title: const Text('Direction Map'),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: trackedLatLng ?? customerLatLng,
              initialZoom: trackedLatLng == null ? 15.0 : 16.5,
              interactionOptions: InteractionOptions(flags: interactionFlags),
            ),
            children: [
              TileLayer(
                urlTemplate: tileUrlTemplate,
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.example.kenea_customers',
              ),
              if (isJoshiTheme)
                TileLayer(
                  urlTemplate: labelsUrlTemplate,
                  subdomains: const ['a', 'b', 'c', 'd'],
                  userAgentPackageName: 'com.example.kenea_customers',
                ),
              if (linePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: linePoints,
                      strokeWidth: 5,
                      color: routeColor,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: customerLatLng,
                    rotate: true,
                    child: Icon(
                      Icons.location_pin,
                      color: customerPinColor,
                      size: 40,
                    ),
                  ),
                  if (trackedLatLng != null)
                    Marker(
                      point: trackedLatLng,
                      rotate: true,
                      child: Container(
                        decoration: BoxDecoration(
                          color: userMarkerColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: isJoshiTheme
                                  ? const Color(0x8800E5FF)
                                  : const Color(0x33000000),
                              blurRadius: isJoshiTheme ? 12 : 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const SizedBox(width: 18, height: 18),
                      ),
                    ),
                ],
              ),
            ],
          ),
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(150),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DefaultTextStyle(
                style: const TextStyle(color: Colors.white, fontSize: 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.isTracking ? 'Tracking: ON' : 'Tracking: OFF'),
                    if (_isLiveRouteLoading || widget.isRouteLoading) const Text('Route: updating...'),
                    if (distanceMeters != null) Text('Distance: ${_formatDistance(distanceMeters)}'),
                    if (durationSeconds != null) Text('ETA: ${(durationSeconds / 60).toStringAsFixed(0)} min'),
                    if (routeProvider != null) Text('Route source: $routeProvider'),
                    if (bearingDegrees != null)
                      Text('Direction: ${bearingDegrees.toStringAsFixed(0)}° ${_bearingLabel(bearingDegrees)}'),
                    if (routeError != null) const Text('Route: unavailable, using straight line'),
                    if (_trackingError != null) Text('Error: $_trackingError'),
                  ],
                ),
              ),
            ),
          ),
          if (_liveRoadSuggestions.isNotEmpty)
            Positioned(
              left: 10,
              right: 10,
              bottom: 16,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final suggestion in _liveRoadSuggestions)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Chip(
                          avatar: const Icon(Icons.alt_route, size: 16),
                          label: Text(
                            suggestion,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (widget.isTracking)
            Positioned(
              top: 10,
              right: 10,
              child: Material(
                color: Colors.black.withAlpha(150),
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () {
                    setState(() {
                      _isCameraFollowEnabled = !_isCameraFollowEnabled;
                      if (!_isCameraFollowEnabled) {
                        _isNavigationViewEnabled = false;
                      }
                    });

                    if (_isCameraFollowEnabled && _animatedTrackedLatLng != null) {
                      _updateFollowCamera(_animatedTrackedLatLng!);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isCameraFollowEnabled ? Icons.gps_fixed : Icons.gps_not_fixed,
                          color: Colors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _isCameraFollowEnabled ? 'Follow ON' : 'Follow OFF',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (widget.isTracking)
            Positioned(
              top: 58,
              right: 10,
              child: Material(
                color: _isCameraFollowEnabled
                    ? Colors.black.withAlpha(150)
                    : Colors.black.withAlpha(100),
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: !_isCameraFollowEnabled
                      ? null
                      : () {
                          setState(() {
                            _isNavigationViewEnabled = !_isNavigationViewEnabled;
                          });

                          final trackedLatLng = _animatedTrackedLatLng;
                          if (trackedLatLng != null) {
                            _updateFollowCamera(trackedLatLng);
                          }
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isNavigationViewEnabled ? Icons.navigation : Icons.explore,
                          color: Colors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _isNavigationViewEnabled ? 'Nav View' : 'Center View',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: 10,
            bottom: _liveRoadSuggestions.isNotEmpty ? 74 : 16,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'fs_fit_all',
                  onPressed: _fitUserAndCustomer,
                  tooltip: 'Fit User + Customer',
                  child: const Icon(Icons.fit_screen),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'fs_focus_user',
                  onPressed: () {
                    if (widget.isTracking) {
                      setState(() {
                        _isCameraFollowEnabled = true;
                      });
                    }
                    _focusOnUser();
                  },
                  tooltip: 'Focus User',
                  child: const Icon(Icons.my_location),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _trackingSubscription?.cancel();
    _trackingHealthCheckTimer?.cancel();
    _markerAnimationController.removeListener(_onMarkerAnimationTick);
    _markerAnimationController.dispose();
    super.dispose();
  }
}