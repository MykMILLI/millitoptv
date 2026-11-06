import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auto_weather.dart';
import '../theme/millitop_visual_theme.dart';

class LiveWeatherCard extends StatefulWidget {
  final int profileId;
  final AutoWeatherController? controller;
  const LiveWeatherCard({super.key, required this.profileId, this.controller});
  @override
  State<LiveWeatherCard> createState() => _LiveWeatherCardState();
}

class _LiveWeatherCardState extends State<LiveWeatherCard>
    with WidgetsBindingObserver {
  late AutoWeatherController weather;
  late bool _ownsController;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  void _attach() {
    _ownsController = widget.controller == null;
    weather =
        widget.controller ?? AutoWeatherController(profileId: widget.profileId);
    weather.addListener(_changed);
    unawaited(weather.initialize());
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  void _detach() {
    weather.removeListener(_changed);
    if (_ownsController) {
      weather.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant LiveWeatherCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profileId != widget.profileId ||
        oldWidget.controller != widget.controller) {
      _detach();
      _attach();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        weather.enabled &&
        !weather.busy) {
      unawaited(weather.refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detach();
    super.dispose();
  }

  Future<void> _settings() async {
    final opened = await weather.openSettings();
    if (!mounted || opened) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Open Windows Settings > Privacy & security > Location. Enable location access for desktop apps, then select Location again.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.millitopTheme.mutedColor;
    final data = weather.hasUsableForecast ? weather.forecast : null;
    final now = DateTime.now();
    final expired = data != null && !data.end.isAfter(now);
    final cached =
        data != null &&
        (weather.problem.isNotEmpty ||
            expired ||
            weather.currentLocation == null);
    final accuracy = weather.currentLocation?.accuracy;
    final fetchedTime = data == null
        ? ''
        : TimeOfDay.fromDateTime(data.fetched.toLocal()).format(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (data?.label ?? (weather.enabled ? 'Your area' : 'Local weather'))
              .toUpperCase(),
          style: TextStyle(fontSize: 14, color: muted),
        ),
        const SizedBox(height: 10),
        Text(
          data?.temperatureText ??
              (weather.busy
                  ? 'Finding local weather...'
                  : weather.enabled
                  ? 'Weather unavailable'
                  : 'Use your location'),
          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w400),
        ),
        if (data != null) ...[
          const SizedBox(height: 8),
          Text(data.condition, style: const TextStyle(fontSize: 20)),
          const SizedBox(height: 8),
          Text(
            expired
                ? 'Cached forecast — forecast period expired'
                : data.start.isAfter(now)
                ? 'Next hourly forecast · not a station observation'
                : 'Hourly forecast · not a station observation',
            style: TextStyle(color: muted),
          ),
          Text(
            '${cached ? 'Last saved forecast' : 'Retrieved'} $fetchedTime',
            style: TextStyle(color: muted),
          ),
        ],
        if (!weather.enabled && !weather.busy) ...[
          const SizedBox(height: 8),
          const Text(
            'Select Location to use this device’s position. Coordinates are used to request your local forecast; no city entry is needed.',
          ),
        ],
        if (weather.busy) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Text(weather.status),
        ],
        if (accuracy != null) ...[
          const SizedBox(height: 6),
          Text(
            'Windows location · reported accuracy approximately ${accuracy.round()} m',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ],
        if (weather.problem.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            weather.problem,
            style: TextStyle(color: Theme.of(context).colorScheme.secondary),
          ),
        ],
        if (weather.persistenceWarning.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(weather.persistenceWarning, style: TextStyle(color: muted)),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton.icon(
              key: const ValueKey('weather-location'),
              onPressed: weather.busy || !weather.initialized
                  ? null
                  : () => weather.useMyLocation(),
              icon: const Icon(Icons.my_location),
              label: Text(weather.busy ? 'Updating...' : 'Location'),
            ),
            TextButton(
              onPressed: weather.busy || !weather.enabled
                  ? null
                  : () => weather.refresh(),
              child: const Text('Refresh'),
            ),
            if (weather.showSettings)
              TextButton(
                onPressed: weather.busy ? null : _settings,
                child: const Text('Windows location settings'),
              ),
            if (weather.enabled)
              TextButton(
                onPressed: weather.busy
                    ? null
                    : () => weather.stopUsingLocation(),
                child: const Text('Stop using location'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Windows determines position; GPS availability depends on this PC. Forecasts refresh every 20 minutes while this widget is open.',
          style: TextStyle(fontSize: 12, color: muted),
        ),
        const SizedBox(height: 4),
        Text(
          'Source: NOAA / National Weather Service · U.S.-focused coverage',
          style: TextStyle(fontSize: 12, color: muted),
        ),
      ],
    );
  }
}
