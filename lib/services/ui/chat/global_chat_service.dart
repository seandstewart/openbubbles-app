import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:get/get.dart';

// ignore: library_private_types_in_public_api, non_constant_identifier_names
_GlobalChatService GlobalChatService = Get.isRegistered<_GlobalChatService>() ? Get.find<_GlobalChatService>() : Get.put(_GlobalChatService());

class _GlobalChatService extends GetxService {
  final RxInt _unreadCount = 0.obs;
  final Map<String, RxBool> _unreadCountMap = <String, RxBool>{}.obs;
  final Map<String, RxnString> _muteTypeMap = <String, RxnString>{}.obs;
  final Map<String, Chat> _chatCache = <String, Chat>{};

  RxInt get unreadCount => _unreadCount;

  RxBool unreadState(String chatGuid) {
    final map = _unreadCountMap[chatGuid];
    if (map == null) {
      _unreadCountMap[chatGuid] = false.obs;
      return _unreadCountMap[chatGuid]!;
    }

    return map;
  }

  RxnString muteState(String chatGuid) {
    final map = _muteTypeMap[chatGuid];
    if (map == null) {
      _muteTypeMap[chatGuid] = RxnString();
      return _muteTypeMap[chatGuid]!;
    }

    return map;
  }

  @override
  void onInit() {
    super.onInit();
    watchChats();
  }

  void watchChats() {
    final query = Database.chats.query().watch(triggerImmediately: true);
    query.listen((event) {
      final chats = event.find();
      _onChatUpdate(chats);
    });
  }

  void _onChatUpdate(List<Chat> chats) {
    // On first run, populate cache and process all chats
    if (_chatCache.isEmpty) {
      for (final chat in chats) {
        _chatCache[chat.guid] = chat;
      }
      _evaluateUnreadInfo(chats);
      _evaluateMuteInfo(chats);
      return;
    }

    // Snapshot old keys FIRST to detect deletes before updating cache
    final cachedGuids = _chatCache.keys.toSet();

    // Find changed chats by comparing with cache
    final changedChats = <Chat>[];
    for (final chat in chats) {
      final cached = _chatCache[chat.guid];
      if (cached == null ||
          (cached.hasUnreadMessage ?? false) != (chat.hasUnreadMessage ?? false) ||
          cached.muteType != chat.muteType) {
        changedChats.add(chat);
      }
    }

    // Then update cache with fresh data
    final freshMap = <String, Chat>{...chats.asMap().map((_, chat) => MapEntry(chat.guid, chat))};
    _chatCache.clear();
    _chatCache.addAll(freshMap);

    // Now find deleted chats from snapshot and remove from Rx maps
    final deleted = cachedGuids.difference(freshMap.keys.toSet());
    for (final guid in deleted) {
      _unreadCountMap.remove(guid);
      _muteTypeMap.remove(guid);
    }
    
    // Recalculate unread count after deletions
    if (deleted.isNotEmpty) {
      unreadCount.value = freshMap.values.where((c) => c.hasUnreadMessage ?? false).length;
    }

    // Only update changed chats
    if (changedChats.isNotEmpty) {
      _updateUnread(changedChats);
      _updateMute(changedChats);
    }
  }

  void _evaluateUnreadInfo(List<Chat> chats) {
    unreadCount.value = chats.where((element) => element.hasUnreadMessage ?? false).length;
    _updateUnread(chats);
  }

  void _evaluateMuteInfo(List<Chat> chats) {
    _updateMute(chats);
  }

  void _updateUnread(List<Chat> chats) {
    for (Chat chat in chats) {
      final RxBool? currentUnreadStatus = _unreadCountMap[chat.guid];
      
      // Set the default value
      if (currentUnreadStatus == null) {
        _unreadCountMap[chat.guid] = RxBool(false);
        _unreadCountMap[chat.guid]!.value = chat.hasUnreadMessage ?? false;
      } else if (currentUnreadStatus.value != chat.hasUnreadMessage) {
        Logger.debug("Updating Chat (${chat.guid}) Unread Status from ${currentUnreadStatus.value} to ${chat.hasUnreadMessage}");
        _unreadCountMap[chat.guid]!.value = chat.hasUnreadMessage ?? false;
      }
    }
  }

  void _updateMute(List<Chat> chats) {
    for (Chat chat in chats) {
      final Rx<String?>? currentMuteStatus = _muteTypeMap[chat.guid];

      // Set the default value
      if (currentMuteStatus == null) {
        _muteTypeMap[chat.guid] = RxnString();
        _muteTypeMap[chat.guid]!.value = chat.muteType;
      } else if (currentMuteStatus.value != chat.muteType) {
        Logger.debug("Updating Chat (${chat.guid}) Mute Type from ${currentMuteStatus.value} to ${chat.muteType}");
        _muteTypeMap[chat.guid]!.value = chat.muteType;
      }
    }
  }
}