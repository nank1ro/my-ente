import "package:flutter/material.dart";
import "package:fluttertoast/fluttertoast.dart";
import "package:logging/logging.dart";
import "package:photos/models/file/file.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/home_widget_service.dart";
import "package:shared_preferences/shared_preferences.dart";

class MemoryHomeWidgetService {
  final Logger _logger = Logger((MemoryHomeWidgetService).toString());

  MemoryHomeWidgetService._privateConstructor();

  static final MemoryHomeWidgetService instance =
      MemoryHomeWidgetService._privateConstructor();

  late final SharedPreferences _prefs;

  bool _hasSyncedMemory = false;

  static const memoryChangedKey = "memoryChanged.widget";
  static const totalSet = "totalSet";

  init(SharedPreferences prefs) {
    _prefs = prefs;
  }

  Future<void> _forceMemoryUpdate() async {
    await _lockAndLoadMemories();
    await updateMemoryChanged(false);
  }

  Future<void> _memorySync() async {
    final total = await _getTotal();
    if (total == 0 || total == null) {
      _logger.warning(
        "sync stopped because no memory is cached yet, so nothing to sync",
      );
      return;
    }

    final homeWidgetCount = await HomeWidgetService.instance.countHomeWidgets();
    if (homeWidgetCount == 0) {
      _logger.warning("no home widget active");
      return;
    }

    await _updateWidget(text: "[i] refreshing from same set");
    _logger.info(">>> Refreshing memory from same set");
  }

  Future<void> initMemoryHW(bool? forceFetchNewMemories) async {
    final areMemoriesShown = memoriesCacheService.showAnyMemories;
    if (!areMemoriesShown) {
      _logger.warning("memories not enabled");
      await clearWidget();
      return;
    }

    forceFetchNewMemories ??= await getForceFetchCondition();

    if (forceFetchNewMemories) {
      await _forceMemoryUpdate();
    } else {
      await _memorySync();
    }
  }

  Future<void> clearWidget() async {
    final total = await _getTotal();
    if (total == 0 || total == null) return;

    _logger.info("Clearing SlideshowWidget");

    await _setTotal(null);
    _hasSyncedMemory = false;

    await _updateWidget(text: "[i] SlideshowWidget cleared & updated");
    _logger.info(">>> SlideshowWidget cleared");
  }

  Future<void> updateMemoryChanged(bool value) async {
    _logger.info("Updating memory changed to $value");
    await _prefs.setBool(memoryChangedKey, value);
  }

  Future<bool> getForceFetchCondition() async {
    final memoryChanged = _prefs.getBool(memoryChangedKey);
    final total = await _getTotal();

    final forceFetchNewMemories =
        memoryChanged == true || total == 0 || total == null;
    return forceFetchNewMemories;
  }

  Future<void> checkPendingMemorySync() async {
    await Future.delayed(const Duration(seconds: 5), () {});

    final forceFetchNewMemories = await getForceFetchCondition();

    if (_hasSyncedMemory && !forceFetchNewMemories) {
      _logger.info(">>> Memory already synced");
      return;
    }
    await HomeWidgetService.instance.initHomeWidget();
  }

  Future<Map<String, Iterable<EnteFile>>> _getMemories() async {
    final memories = await memoriesCacheService.getMemories();
    if (memories.isEmpty) {
      return {};
    }

    // flatten the memories to a list of files and take first 50
    final files = memories.take(50).toList().asMap().map(
          (k, v) => MapEntry(
            v.title,
            v.memories.map((e) => e.file),
          ),
        );

    return files;
  }

  Future<void> _updateWidget({String? text}) async {
    await HomeWidgetService.instance.updateWidget(
      androidClass: "SlideshowWidgetProvider",
      iOSClass: "SlideshowWidget",
    );
    if (flagService.internalUser) {
      await Fluttertoast.showToast(
        msg: text ?? "[i] SlideshowWidget updated",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        timeInSecForIosWeb: 1,
        backgroundColor: Colors.black,
        textColor: Colors.white,
        fontSize: 16.0,
      );
    }
    _logger.info(">>> Home Widget updated");
  }

  Future<int?> _getTotal() async {
    return HomeWidgetService.instance.getData<int>(totalSet);
  }

  Future<void> _setTotal(int? total) async =>
      await HomeWidgetService.instance.setData(totalSet, total);

  Future<void> _lockAndLoadMemories() async {
    final files = await _getMemories();

    if (files.isEmpty) {
      _logger.warning("No files found, clearing everything");
      await clearWidget();
      return;
    }

    int index = 0;

    for (final i in files.entries) {
      for (final file in i.value) {
        final value = await HomeWidgetService.instance
            .renderFile(file, "slideshow_$index", i.key)
            .catchError(
          (e, sT) {
            _logger.severe("Error rendering widget", e, sT);
            return null;
          },
        );

        if (value != null) {
          await _setTotal(index);
          if (index == 1) {
            await _updateWidget(
              text: "[i] First memory fetched. updating widget",
            );
          }
          index++;
        }
      }
    }

    if (index == 0) {
      return;
    }

    await _updateWidget();
    _logger.info(">>> Switching to next memory set");
  }

  Future<void> onLaunchFromWidget(int generatedId, BuildContext context) async {
    _hasSyncedMemory = true;
    await _memorySync();

    await memoriesCacheService.goToMemoryFromGeneratedFileID(
      context,
      generatedId,
    );
  }
}
