import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/gen/assets.gen.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

/// System tray integration for Windows and Linux.
///
/// On Linux, `tray_manager` uses libayatana-appindicator, which exposes the icon
/// through the StatusNotifierItem D-Bus protocol. This works on Wayland (KDE natively,
/// GNOME with the AppIndicator extension, wlroots compositors via e.g. waybar).
///
/// The tray icon is only shown when at least one of the tray settings is enabled
/// (or the app was started hidden with `--minimized`), so nothing changes for users
/// who don't opt in.
class TrayService with tray.TrayListener, WindowListener {
  static final _logger = Logger("TrayService");

  static bool get isSupported => Platform.isWindows || Platform.isLinux;

  /// Command-line flag to start with the window hidden in the tray.
  static const startMinimizedFlag = "--minimized";

  /// Whether we are running in a Linux Wayland session. Wayland doesn't tell clients when
  /// they get minimized, so "minimize to tray" can't work there.
  static bool get isWayland =>
      Platform.isLinux &&
      (Platform.environment["WAYLAND_DISPLAY"]?.isNotEmpty ?? false) &&
      Platform.environment["GDK_BACKEND"] != "x11";

  /// Whether the window should stay hidden on startup.
  static bool shouldStartHidden(List<String> args) =>
      isSupported && (args.contains(startMinimizedFlag) || FinampSettingsHelper.finampSettings.startMinimizedToTray);

  TrayService({required bool startedHidden}) : _forceTray = startedHidden, _windowVisible = !startedHidden;

  /// Keep the icon even if all settings are off, otherwise a window started with
  /// `--minimized` would be unreachable.
  bool _forceTray;
  bool _windowVisible;
  bool _trayVisible = false;
  bool _quitting = false;

  bool _isPlaying = false;
  MediaItem? _currentItem;
  String? _lastMenuSignature;

  MusicPlayerBackgroundTask get _audioHandler => GetIt.instance<MusicPlayerBackgroundTask>();

  void init() {
    if (!isSupported) return;

    tray.trayManager.addListener(this);
    windowManager.addListener(this);

    final container = GetIt.instance<ProviderContainer>();
    container.listen(finampSettingsProvider.closeToTray, (_, _) => unawaited(_applySettings()));
    container.listen(finampSettingsProvider.minimizeToTray, (_, _) => unawaited(_applySettings()));
    container.listen(finampSettingsProvider.startMinimizedToTray, (_, _) => unawaited(_applySettings()));
    // Menu labels are localized, rebuild them once the new locale is in effect.
    container.listen(finampSettingsProvider.locale, (_, _) => _refreshMenuAfterFrame());

    _audioHandler.playbackState.map((state) => state.playing).distinct().listen((playing) {
      _isPlaying = playing;
      unawaited(_refreshMenu());
    });
    _audioHandler.mediaItem.distinct().listen((item) {
      _currentItem = item;
      unawaited(_refreshMenu());
    });

    unawaited(_applySettings());
    // Localizations are only fully available once MaterialApp has been built.
    _refreshMenuAfterFrame();
  }

  bool get _trayWanted {
    final settings = FinampSettingsHelper.finampSettings;
    return _forceTray || settings.closeToTray || settings.minimizeToTray || settings.startMinimizedToTray;
  }

  Future<void> _applySettings() async {
    try {
      // Intercept the close button only when we want to hide instead of quitting.
      await windowManager.setPreventClose(FinampSettingsHelper.finampSettings.closeToTray);

      if (_trayWanted && !_trayVisible) {
        await tray.trayManager.setIcon(_iconPath);
        _trayVisible = true;
        _lastMenuSignature = null;
        await _refreshMenu();
      } else if (!_trayWanted && _trayVisible) {
        await tray.trayManager.destroy();
        _trayVisible = false;
      }
    } catch (e, stack) {
      _logger.severe("Failed to update tray icon", e, stack);
    }
  }

  String get _iconPath {
    if (Platform.isWindows) return Assets.tray.trayIconIco;
    // In a sandbox tray_manager passes the value as an icon name, since asset paths
    // aren't visible to the host. Use the app id, which is the name of the exported icon.
    if (Platform.environment.containsKey("FLATPAK_ID") || Platform.environment.containsKey("SNAP")) {
      return "com.unicornsonlsd.finamp";
    }
    return Assets.tray.trayIconPng.path;
  }

  String? get _nowPlayingText {
    final item = _currentItem;
    if (item == null) return null;
    final artist = item.artist;
    return (artist != null && artist.isNotEmpty) ? "$artist - ${item.title}" : item.title;
  }

  void _refreshMenuAfterFrame() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _lastMenuSignature = null;
      unawaited(_refreshMenu());
    });
  }

  Future<void> _refreshMenu() async {
    if (!_trayVisible) return;
    final l10n = GlobalSnackbar.requireL10n;
    final nowPlaying = _nowPlayingText;
    final hasTrack = _currentItem != null;

    // Avoid needlessly rebuilding the native menu.
    final signature = "${l10n.localeName}|$_windowVisible|$_isPlaying|$nowPlaying";
    if (signature == _lastMenuSignature) return;
    _lastMenuSignature = signature;

    final menu = tray.Menu(
      items: [
        tray.MenuItem(label: nowPlaying ?? l10n.trayNothingPlaying, disabled: true),
        tray.MenuItem.separator(),
        tray.MenuItem(
          label: _windowVisible ? l10n.trayHideWindow : l10n.trayShowWindow,
          onClick: (_) => unawaited(toggleWindow()),
        ),
        tray.MenuItem.separator(),
        tray.MenuItem(
          label: _isPlaying ? l10n.trayPause : l10n.trayPlay,
          disabled: !hasTrack,
          onClick: (_) => unawaited(_audioHandler.togglePlayback()),
        ),
        tray.MenuItem(
          label: l10n.trayPrevious,
          disabled: !hasTrack,
          onClick: (_) => unawaited(_audioHandler.skipToPrevious()),
        ),
        tray.MenuItem(label: l10n.trayNext, disabled: !hasTrack, onClick: (_) => unawaited(_audioHandler.skipToNext())),
        tray.MenuItem.separator(),
        tray.MenuItem(label: l10n.trayQuit, onClick: (_) => unawaited(quit())),
      ],
    );

    try {
      await tray.trayManager.setContextMenu(menu);
      // Tooltips aren't implemented by tray_manager on Linux (appindicator has none),
      // the now-playing entry at the top of the menu covers that case.
      if (Platform.isWindows) {
        await tray.trayManager.setToolTip(nowPlaying != null ? "$nowPlaying - Finamp" : "Finamp");
      }
    } catch (e, stack) {
      _logger.warning("Failed to update tray menu", e, stack);
    }
  }

  Future<void> hideWindow() async {
    // Make sure the user can get the window back.
    if (!_trayVisible) {
      _forceTray = true;
      await _applySettings();
    }
    await windowManager.hide();
    _setWindowVisible(false);
  }

  Future<void> showWindow() async {
    await windowManager.show();
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
    _setWindowVisible(true);
  }

  Future<void> toggleWindow() async {
    if (await windowManager.isVisible()) {
      await hideWindow();
    } else {
      await showWindow();
    }
  }

  /// Fully quits the app, bypassing close-to-tray.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    _logger.info("Quitting from tray");
    try {
      await tray.trayManager.destroy();
    } catch (_) {}
    // Let the regular close path run (which also disposes the player).
    // Don't use windowManager.destroy(), it freezes Windows release builds.
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  void _setWindowVisible(bool visible) {
    if (_windowVisible == visible) return;
    _windowVisible = visible;
    unawaited(_refreshMenu());
  }

  // ---- TrayListener ----

  @override
  void onTrayIconMouseDown() {
    // Only fires on Windows: appindicator always opens the menu on click.
    unawaited(toggleWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(tray.trayManager.popUpContextMenu());
  }

  // ---- WindowListener ----

  @override
  void onWindowClose() {
    if (_quitting || !FinampSettingsHelper.finampSettings.closeToTray) return;
    unawaited(hideWindow());
  }

  @override
  void onWindowMinimize() {
    if (!FinampSettingsHelper.finampSettings.minimizeToTray) return;
    unawaited(hideWindow());
  }

  @override
  void onWindowEvent(String eventName) {
    // Keep the Show/Hide entry accurate when the window is shown by other means,
    // e.g. by launching Finamp again.
    if (eventName == "show" || eventName == "focus" || eventName == "restore") {
      _setWindowVisible(true);
    } else if (eventName == "hide") {
      _setWindowVisible(false);
    }
  }
}
