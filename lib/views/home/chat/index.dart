// Dart imports:
import 'dart:async';
import 'dart:io';

// Flutter imports:
import 'package:emoji_picker/emoji_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:equatable/equatable.dart';
import 'package:flutter_redux/flutter_redux.dart';
import 'package:flutter_svg/svg.dart';
import 'package:redux/redux.dart';
import 'package:syphon/global/algos.dart';
import 'package:syphon/global/assets.dart';

// Project imports:
import 'package:syphon/global/colours.dart';
import 'package:syphon/global/dimensions.dart';
import 'package:syphon/global/print.dart';
import 'package:syphon/global/strings.dart';
import 'package:syphon/global/themes.dart';
import 'package:syphon/store/crypto/actions.dart';
import 'package:syphon/store/events/messages/actions.dart';
import 'package:syphon/store/events/reactions/actions.dart';
import 'package:syphon/store/index.dart';
import 'package:syphon/store/rooms/actions.dart';
import 'package:syphon/store/events/actions.dart';
import 'package:syphon/global/libs/matrix/constants.dart';
import 'package:syphon/store/events/messages/model.dart';
import 'package:syphon/store/events/selectors.dart';
import 'package:syphon/store/rooms/room/model.dart';
import 'package:syphon/store/rooms/selectors.dart';
import 'package:syphon/store/user/model.dart';
import 'package:syphon/views/home/chat/chat-input.dart';
import 'package:syphon/views/home/chat/dialog-encryption.dart';
import 'package:syphon/views/home/chat/dialog-invite.dart';
import 'package:syphon/views/widgets/appbars/appbar-chat.dart';
import 'package:syphon/views/widgets/appbars/appbar-options-message.dart';
import 'package:syphon/views/widgets/loader/index.dart';
import 'package:syphon/views/widgets/messages/message-typing.dart';
import 'package:syphon/views/widgets/messages/message.dart';
import 'package:syphon/views/widgets/modals/modal-user-details.dart';

class ChatViewArguements {
  final String roomId;
  final String title;

  // Improve loading times
  ChatViewArguements({
    this.roomId,
    this.title,
  });
}

class ChatView extends StatefulWidget {
  const ChatView({Key key}) : super(key: key);

  @override
  ChatViewState createState() => ChatViewState();
}

class ChatViewState extends State<ChatView> {
  bool sendable = false;
  Message selectedMessage;
  Timer typingNotifier;
  Timer typingNotifierTimeout;
  FocusNode inputFieldNode;
  Map<String, Color> senderColors;

  double overshoot = 0;
  bool loadMore = false;
  String mediumType = MediumType.plaintext;

  final editorController = TextEditingController();
  final messagesController = ScrollController();
  final listViewController = ScrollController();

  @override
  void initState() {
    super.initState();
    inputFieldNode = FocusNode();
    inputFieldNode.addListener(() {
      if (!inputFieldNode.hasFocus && this.typingNotifier != null) {
        this.typingNotifier.cancel();
        this.setState(() {
          typingNotifier = null;
        });
      }
    });

    // NOTE: still needed to have navigator context in dialogs
    SchedulerBinding.instance.addPostFrameCallback((_) {
      onMounted();
    });
  }

  @protected
  void onMounted() async {
    final arguements =
        ModalRoute.of(context).settings.arguments as ChatViewArguements;
    final store = StoreProvider.of<AppState>(context, listen: false);
    final props = _Props.mapStateToProps(store, arguements.roomId);
    final draft = props.room.draft;

    // only marked if read receipts are enabled
    props.onMarkRead();

    if (props.room.invite) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => DialogInvite(
          onAccept: props.onAcceptInvite,
          onCancel: () {
            Navigator.popUntil(context, (route) => route.isFirst);
          },
        ),
      );
    }

    if (props.room.encryptionEnabled) {
      props.onUpdateDeviceKeys();
      this.setState(() {
        mediumType = MediumType.encryption;
      });
    }

    if (props.messages.length < 10) {
      props.onLoadFirstBatch();
    }

    if (draft != null && draft.type == MessageTypes.TEXT) {
      final text = draft.body;
      this.setState(() {
        sendable = text != null && text.isNotEmpty;
      });

      editorController.value = TextEditingValue(
        text: text,
        selection: TextSelection.fromPosition(
          TextPosition(offset: text.length),
        ),
      );
    }

    messagesController.addListener(() {
      final extentBefore = messagesController.position.extentBefore;
      final max = messagesController.position.maxScrollExtent;

      final limit = max - extentBefore;
      final atLimit = Platform.isAndroid ? limit < 1 : limit < -32;

      if (atLimit && !loadMore) {
        this.setState(() {
          loadMore = true;
        });
        props.onLoadMoreMessages();
      } else if (!atLimit && loadMore && !props.loading) {
        this.setState(() {
          loadMore = false;
        });
      }
    });
  }

  @protected
  onDidChange(_Props props) {
    if (props.room.encryptionEnabled && mediumType != MediumType.encryption) {
      this.setState(() {
        mediumType = MediumType.encryption;
      });
      props.onUpdateDeviceKeys();
    }
  }

  @override
  void dispose() {
    inputFieldNode.dispose();
    messagesController.dispose();
    super.dispose();
    if (this.typingNotifier != null) {
      this.typingNotifier.cancel();
    }

    if (this.typingNotifierTimeout != null) {
      this.typingNotifierTimeout.cancel();
    }
  }

  onUpdateMessage(String text, _Props props) {
    this.setState(() {
      sendable = text != null && text.trim().isNotEmpty;
    });

    // start an interval for updating typing status
    if (inputFieldNode.hasFocus && this.typingNotifier == null) {
      props.onSendTyping(typing: true, roomId: props.room.id);
      this.setState(() {
        typingNotifier = Timer.periodic(
          Duration(milliseconds: 4000),
          (timer) => props.onSendTyping(typing: true, roomId: props.room.id),
        );
      });
    }

    // Handle a timeout of the interval if the user idles with input focused
    if (inputFieldNode.hasFocus) {
      if (typingNotifierTimeout != null) {
        this.typingNotifierTimeout.cancel();
      }
      this.setState(() {
        typingNotifierTimeout = Timer(Duration(milliseconds: 4000), () {
          if (typingNotifier != null) {
            this.typingNotifier.cancel();
            this.setState(() {
              typingNotifier = null;
              typingNotifierTimeout = null;
            });
            // run after to avoid flickering
            props.onSendTyping(typing: false, roomId: props.room.id);
          }
        });
      });
    }
  }

  onChangeMediumType({String newMediumType, _Props props}) {
    // noop
    if (mediumType == newMediumType) {
      return;
    }

    if (newMediumType == MediumType.encryption) {
      // if the room has not enabled encryption
      // confirm with the user first before
      // attempting it
      if (!props.room.encryptionEnabled) {
        return showDialog(
          context: context,
          barrierDismissible: false,
          child: DialogEncryption(
            onAccept: () {
              props.onToggleEncryption();

              setState(() {
                mediumType = newMediumType;
              });
            },
          ),
        );
      }

      // Otherwise, only toggle the medium type
      setState(() {
        mediumType = newMediumType;
      });
    } else {
      // allow other mediums for messages
      // unless they've encrypted the room
      if (!props.room.encryptionEnabled) {
        setState(() {
          mediumType = newMediumType;
        });
      }
    }
  }

  onToggleMessageOptions({Message message}) {
    this.setState(() {
      selectedMessage = message;
    });
  }

  onInputReaction({Message message, _Props props}) async {
    final height = MediaQuery.of(context).size.height;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: height / 2.2,
        padding: EdgeInsets.symmetric(
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
          ),
        ),
        child: EmojiPicker(
            rows: 7,
            columns: 9,
            indicatorColor: Theme.of(context).accentColor,
            bgColor: Theme.of(context).scaffoldBackgroundColor,
            numRecommended: 10,
            categoryIcons: CategoryIcons(
              smileyIcon: CategoryIcon(icon: Icons.tag_faces_rounded),
              objectIcon: CategoryIcon(icon: Icons.lightbulb),
              travelIcon: CategoryIcon(icon: Icons.flight),
              activityIcon: CategoryIcon(icon: Icons.sports_soccer),
              symbolIcon: CategoryIcon(icon: Icons.tag),
            ),
            onEmojiSelected: (emoji, category) {
              props.onToggleReaction(
                emoji: emoji.emoji,
                message: message,
              );

              Navigator.pop(context, false);
              this.setState(() {
                selectedMessage = null;
              });
            }),
      ),
    );
  }

  onDismissMessageOptions() {
    this.setState(() {
      selectedMessage = null;
    });
  }

  onViewUserDetails({Message message, String userId}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModalUserDetails(
        userId: userId ?? message.sender,
      ),
    );
  }

  onSubmitMessage(_Props props) async {
    props.onSendMessage(
      body: editorController.text,
      type: MessageTypes.TEXT,
    );
    editorController.clear();
    FocusScope.of(context).unfocus();
    this.setState(() {
      sendable = false;
    });
  }

  @protected
  onShowMediumMenu(context, _Props props) async {
    double width = MediaQuery.of(context).size.width;
    double height = MediaQuery.of(context).size.height;

    showMenu(
      elevation: 4.0,
      context: context,
      position: RelativeRect.fromLTRB(
        width,
        // input height and padding
        height - Dimensions.inputSizeMin,
        0.0,
        0.0,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      items: [
        PopupMenuItem<String>(
          enabled: !props.room.encryptionEnabled,
          child: GestureDetector(
            onTap: () {
              Navigator.pop(context);
              this.onChangeMediumType(
                newMediumType: MediumType.plaintext,
                props: props,
              );
            },
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.only(right: 8),
                    child: CircleAvatar(
                      backgroundColor: const Color(Colours.greyDisabled),
                      child: SvgPicture.asset(
                        Assets.iconSendUnlockBeing,
                        color: Colors.white,
                        semanticsLabel: Strings.semanticsSendUnencrypted,
                      ),
                    ),
                  ),
                  Text('Unencrypted'),
                ],
              ),
            ),
          ),
        ),
        PopupMenuItem<String>(
          enabled: props.room.direct,
          child: GestureDetector(
            onTap: !props.room.direct
                ? null
                : () {
                    Navigator.pop(context);
                    this.onChangeMediumType(
                      newMediumType: MediumType.encryption,
                      props: props,
                    );
                  },
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.only(right: 8),
                    child: CircleAvatar(
                      backgroundColor: Theme.of(context).primaryColor,
                      child: SvgPicture.asset(
                        Assets.iconSendLockSolidBeing,
                        color: Colors.white,
                        semanticsLabel: Strings.semanticsSendUnencrypted,
                      ),
                    ),
                  ),
                  Text('Encrypted'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @protected
  Widget buildMessageList(BuildContext context, _Props props) =>
      GestureDetector(
        onTap: onDismissMessageOptions,
        child: Container(
          child: ListView(
            reverse: true,
            padding: EdgeInsets.only(bottom: 12),
            physics: selectedMessage != null
                ? const NeverScrollableScrollPhysics()
                : null,
            controller: messagesController,
            children: [
              MessageTypingWidget(
                roomUsers: props.users,
                typing: props.room.userTyping,
                usersTyping: props.room.usersTyping,
                selectedMessageId: this.selectedMessage != null
                    ? this.selectedMessage.id
                    : null,
                onPressAvatar: onViewUserDetails,
              ),
              ListView.builder(
                reverse: true,
                shrinkWrap: true,
                padding: EdgeInsets.only(bottom: 4),
                addRepaintBoundaries: true,
                addAutomaticKeepAlives: true,
                itemCount: props.messages.length,
                scrollDirection: Axis.vertical,
                physics: const NeverScrollableScrollPhysics(),
                itemBuilder: (BuildContext context, int index) {
                  final message = props.messages[index];
                  final lastMessage =
                      index != 0 ? props.messages[index - 1] : null;
                  final nextMessage = index + 1 < props.messages.length
                      ? props.messages[index + 1]
                      : null;

                  final isLastSender = lastMessage != null &&
                      lastMessage.sender == message.sender;
                  final isNextSender = nextMessage != null &&
                      nextMessage.sender == message.sender;
                  final isUserSent = props.userId == message.sender;
                  final selectedMessageId = this.selectedMessage != null
                      ? this.selectedMessage.id
                      : null;

                  final avatarUri = props.users[message.sender]?.avatarUri;

                  return MessageWidget(
                    message: message,
                    isUserSent: isUserSent,
                    isLastSender: isLastSender,
                    isNextSender: isNextSender,
                    lastRead: props.room.lastRead,
                    selectedMessageId: selectedMessageId,
                    avatarUri: avatarUri,
                    theme: props.theme,
                    fontSize: 14,
                    timeFormat: props.timeFormat24Enabled ? '24hr' : '12hr',
                    onSwipe: props.onSelectReply,
                    onPressAvatar: onViewUserDetails,
                    onLongPress: onToggleMessageOptions,
                    onInputReaction: () => onInputReaction(
                      message: message,
                      props: props,
                    ),
                    onToggleReaction: (emoji) => props.onToggleReaction(
                      emoji: emoji,
                      message: message,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => StoreConnector<AppState, _Props>(
        distinct: true,
        onDidChange: onDidChange,
        converter: (Store<AppState> store) => _Props.mapStateToProps(
          store,
          (ModalRoute.of(context).settings.arguments as ChatViewArguements)
              .roomId,
        ),
        builder: (context, props) {
          double height = MediaQuery.of(context).size.height;

          final closedInputPadding = !inputFieldNode.hasFocus &&
              Platform.isIOS &&
              Dimensions.buttonlessHeightiOS < height;

          final isScrolling =
              messagesController.hasClients && messagesController.offset != 0;

          Color inputContainerColor = Colors.white;

          if (Theme.of(context).brightness == Brightness.dark) {
            inputContainerColor = Theme.of(context).scaffoldBackgroundColor;
          }

          Widget appBar = AppBarChat(
            room: props.room,
            color: props.roomPrimaryColor,
            badgesEnabled: props.roomTypeBadgesEnabled,
            onDebug: () {
              props.onCheatCode();
            },
            onBack: () {
              if (editorController.text != null &&
                  0 < editorController.text.length) {
                props.onSaveDraftMessage(
                  body: editorController.text,
                  type: MessageTypes.TEXT,
                );
              } else if (props.room.draft != null) {
                props.onClearDraftMessage();
              }

              Navigator.pop(context, false);
            },
          );

          if (this.selectedMessage != null) {
            appBar = AppBarMessageOptions(
              room: props.room,
              message: selectedMessage,
              onDismiss: () => this.setState(() {
                selectedMessage = null;
              }),
              onDelete: () => props.onDeleteMessage(
                message: this.selectedMessage,
              ),
            );
          }

          return Scaffold(
            appBar: appBar,
            backgroundColor: selectedMessage != null
                ? Theme.of(context).scaffoldBackgroundColor.withAlpha(64)
                : Theme.of(context).scaffoldBackgroundColor,
            body: Align(
              alignment: Alignment.topRight,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        // Disimiss keyboard if they click outside the text input
                        inputFieldNode.unfocus();
                        FocusScope.of(context).unfocus();
                      },
                      child: Stack(
                        children: [
                          buildMessageList(
                            context,
                            props,
                          ),
                          Positioned(
                            child: Loader(
                              loading: props.loading,
                            ),
                          ),
                          Positioned(
                            child: Visibility(
                              maintainSize: false,
                              maintainAnimation: false,
                              maintainState: false,
                              visible: props.room.lastHash == null,
                              child: GestureDetector(
                                onTap: () => props.onLoadMoreMessages(),
                                child: Container(
                                  height: Dimensions.buttonHeightMin,
                                  color: Theme.of(context).secondaryHeaderColor,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: <Widget>[
                                      Text(
                                        'Load more messages',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyText2,
                                      )
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.only(
                      left: 8,
                      right: 8,
                      top: 12,
                      bottom: 12,
                    ),
                    decoration: BoxDecoration(
                      color: inputContainerColor,
                      boxShadow: isScrolling
                          ? [
                              BoxShadow(
                                  blurRadius: 6,
                                  offset: Offset(0, -4),
                                  color: Colors.black12)
                            ]
                          : [],
                    ),
                    child: AnimatedPadding(
                      duration: Duration(
                          milliseconds: inputFieldNode.hasFocus ? 225 : 0),
                      padding: EdgeInsets.only(
                        bottom: closedInputPadding ? 16 : 0,
                      ),
                      child: ChatInput(
                        sendable: sendable,
                        mediumType: mediumType,
                        focusNode: inputFieldNode,
                        enterSend: props.enterSend,
                        controller: editorController,
                        quotable: props.room.reply,
                        onCancelReply: () => props.onSelectReply(null),
                        onChangeMethod: () => onShowMediumMenu(context, props),
                        onChangeMessage: (text) => onUpdateMessage(text, props),
                        onSubmitMessage: () => this.onSubmitMessage(props),
                        onSubmittedMessage: (text) =>
                            this.onSubmitMessage(props),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
}

class _Props extends Equatable {
  final Room room;
  final String userId;
  final bool loading;
  final bool enterSend;
  final ThemeType theme;
  final Map<String, User> users;
  final List<Message> messages;
  final int redactions;
  final Color roomPrimaryColor;
  final bool timeFormat24Enabled;
  final bool roomTypeBadgesEnabled;

  final Function onSendTyping;
  final Function onSendMessage;
  final Function onDeleteMessage;
  final Function onUpdateDeviceKeys;
  final Function onSaveDraftMessage;
  final Function onClearDraftMessage;
  final Function onLoadMoreMessages;
  final Function onLoadFirstBatch;
  final Function onAcceptInvite;
  final Function onToggleEncryption;
  final Function onToggleReaction;
  final Function onCheatCode;
  final Function onMarkRead;
  final Function onSelectReply;

  _Props({
    @required this.room,
    @required this.theme,
    @required this.userId,
    @required this.users,
    @required this.messages,
    @required this.redactions,
    @required this.loading,
    @required this.enterSend,
    @required this.roomPrimaryColor,
    @required this.timeFormat24Enabled,
    @required this.roomTypeBadgesEnabled,
    @required this.onUpdateDeviceKeys,
    @required this.onSendTyping,
    @required this.onSendMessage,
    @required this.onDeleteMessage,
    @required this.onSaveDraftMessage,
    @required this.onClearDraftMessage,
    @required this.onLoadMoreMessages,
    @required this.onLoadFirstBatch,
    @required this.onAcceptInvite,
    @required this.onToggleEncryption,
    @required this.onToggleReaction,
    @required this.onCheatCode,
    @required this.onMarkRead,
    @required this.onSelectReply,
  });

  @override
  List<Object> get props => [
        room,
        users,
        userId,
        messages,
        redactions,
        loading,
        enterSend,
        roomPrimaryColor,
      ];

  static _Props mapStateToProps(Store<AppState> store, String roomId) => _Props(
      userId: store.state.authStore.user.userId,
      theme: store.state.settingsStore.theme,
      roomTypeBadgesEnabled:
          store.state.settingsStore.roomTypeBadgesEnabled ?? true,
      timeFormat24Enabled:
          store.state.settingsStore.timeFormat24Enabled ?? false,
      loading: (store.state.roomStore.rooms[roomId] ?? Room()).syncing,
      room: selectRoom(id: roomId, state: store.state),
      users: store.state.userStore.users,
      enterSend: store.state.settingsStore.enterSend,
      redactions: store.state.eventStore.redactions.length,
      messages: latestMessages(
        appendRelated(
          filterMessages(
            combineOutbox(
              messages: roomMessages(store.state, roomId).toList(),
              outbox: selectRoom(id: roomId, state: store.state).outbox,
            ),
            store.state,
          ),
          store.state,
        ),
      ),
      onSelectReply: (Message message) {
        store.dispatch(selectReply(roomId: roomId, message: message));
      },
      roomPrimaryColor: () {
        final customChatSettings =
            store.state.settingsStore.customChatSettings ?? Map();

        if (customChatSettings[roomId] != null) {
          return Color(customChatSettings[roomId].primaryColor);
        }

        return Colours.hashedColor(roomId);
      }(),
      onUpdateDeviceKeys: () async {
        final room = store.state.roomStore.rooms[roomId];

        final usersDeviceKeys = await store.dispatch(
          fetchDeviceKeys(userIds: room.userIds),
        );

        store.dispatch(setDeviceKeys(usersDeviceKeys));
      },
      onSaveDraftMessage: ({
        String body,
        String type,
      }) {
        store.dispatch(saveDraft(
          body: body,
          type: type,
          room: store.state.roomStore.rooms[roomId],
        ));
      },
      onClearDraftMessage: ({
        String body,
        String type,
      }) {
        store.dispatch(clearDraft(
          room: store.state.roomStore.rooms[roomId],
        ));
      },
      onSendMessage: ({String body, String type}) async {
        final room = store.state.roomStore.rooms[roomId];

        final message = Message(
          body: body,
          type: type,
        );

        if (room.encryptionEnabled) {
          return store.dispatch(sendMessageEncrypted(
            room: room,
            message: message,
          ));
        }

        return store.dispatch(sendMessage(
          room: room,
          message: message,
        ));
      },
      onDeleteMessage: ({
        Message message,
      }) {
        if (message != null) {
          store.dispatch(deleteMessage(message: message));
        }
      },
      onAcceptInvite: () {
        store.dispatch(acceptRoom(room: Room(id: roomId)));
      },
      onSendTyping: ({typing, roomId}) => store.dispatch(
            sendTyping(typing: typing, roomId: roomId),
          ),
      onMarkRead: () {
        store.dispatch(markRoomRead(roomId: roomId));
      },
      onLoadFirstBatch: () {
        final room = selectRoom(id: roomId, state: store.state);
        printDebug('[onLoadFirstBatch] ${room.id}');
        store.dispatch(
          fetchMessageEvents(
            room: room,
            from: room.nextHash,
            limit: 25,
          ),
        );
      },
      onToggleReaction: ({Message message, String emoji}) {
        final room = selectRoom(id: roomId, state: store.state);

        store.dispatch(
          toggleReaction(room: room, message: message, emoji: emoji),
        );
      },
      onToggleEncryption: () {
        final room = selectRoom(id: roomId, state: store.state);
        store.dispatch(
          toggleRoomEncryption(room: room),
        );
      },
      onLoadMoreMessages: () {
        final room = store.state.roomStore.rooms[roomId] ?? Room();

        // load message from cold storage
        // TODO: paginate cold storage messages
        // final messages = roomMessages(store.state, roomId);
        // if (messages.length < room.messageIds.length) {
        //   printDebug(
        //       '[onLoadMoreMessages] loading from cold storage ${messages.length} ${room.messageIds.length}');
        //   return store.dispatch(
        //     loadMessageEvents(
        //       room: room,
        //       offset: messages.length,
        //     ),
        //   );
        // }

        // fetch messages beyond the oldest known message - lastHash
        return store.dispatch(fetchMessageEvents(
          room: room,
          from: room.lastHash,
          oldest: true,
        ));
      },
      onCheatCode: () async {
        // await store.dispatch(store.dispatch(generateDeviceId(
        //   salt: store.state.authStore.username,
        // )));

        final room = store.state.roomStore.rooms[roomId] ?? Room();

        store.dispatch(updateKeySessions(room: room));

        final usersDeviceKeys = await store.dispatch(
          fetchDeviceKeys(userIds: room.userIds),
        );

        printJson(usersDeviceKeys);
      });
}
