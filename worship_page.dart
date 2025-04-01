import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:prayershub_app/globals.dart';
import 'package:prayershub_app/models/compilation.dart';
import 'package:prayershub_app/models/live.dart';
import 'package:prayershub_app/models/worship_content.dart';
import 'package:prayershub_app/pages/single_profile.dart';
import 'package:prayershub_app/pages/worship/content/custom.dart';
import 'package:prayershub_app/pages/worship/content/prayer.dart';
import 'package:prayershub_app/pages/worship/content/scripture.dart';
import 'package:prayershub_app/pages/worship/content/song.dart';
import 'package:prayershub_app/pages/worship/countdown.dart';
import 'package:prayershub_app/pages/worship/participants.dart';
import 'package:prayershub_app/services/heroes.dart' as heroes;
import 'package:flutter/material.dart';
import 'package:prayershub_app/models/user.dart';
import 'package:prayershub_app/models/worship.dart';
import 'package:prayershub_app/services/worship.dart';
import 'package:prayershub_app/utils.dart';
import 'package:prayershub_app/utils_internal_server_error_widget.dart';
import 'package:rxdart/rxdart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

typedef CountdownState = ({bool paused, int timeLeft});
typedef PlayingState = ({bool paused, int time});

class WorshipPage extends StatefulWidget {
  const WorshipPage({
    super.key,
    required this.user,
    required this.worship,
  });

  final SafeUser user;
  final Worship worship;

  @override
  State<WorshipPage> createState() => _WorshipPageState();
}

class _WorshipPageState extends State<WorshipPage> {
  bool get isOwner => mainAuth.id == widget.worship.userId;

  late ValueNotifier<String> bannerNotifier =
      ValueNotifier(widget.worship.banner);
  late ValueNotifier<String> titleNotifier =
      ValueNotifier(widget.worship.title);
  late TextEditingController titleController = TextEditingController.fromValue(
    TextEditingValue(text: widget.worship.title),
  );

  final onRetryClick = PublishSubject<bool>();
  late var onDeleteContent = PublishSubject<WorshipContent>();
  late var onAddContent = PublishSubject<WorshipContent>();
  late var onAddSong = PublishSubject<Song>();
  final onSortContent = PublishSubject<({int oldIndex, int newIndex})>();

  final onEditClick = PublishSubject<bool>();
  final onDoneClick = PublishSubject<bool>();

  late var editing = MergeStream([
    onEditClick.map((_) => true),
    onDoneClick.map((_) => false),
  ]).startWith(false).shareReplay(maxSize: 1);

  final onPauseCountdownClick = PublishSubject<bool>();
  final onResumeCountdownClick = PublishSubject<bool>();
  final onAbortCountdownClick = PublishSubject<bool>();
  final onSkipCountdownClick = PublishSubject<bool>();

  final onPlayClick = PublishSubject<bool>();
  final onBroadcastClick = PublishSubject<bool>();
  final onPreviousClick = PublishSubject<bool>();
  final onPauseClick = PublishSubject<bool>();
  final onResumeClick = PublishSubject<bool>();
  final onStopClick = PublishSubject<bool>();
  final onNextClick = PublishSubject<bool>();

  late PublishConnectableStream<void> onAllowedBroadcastClick = onBroadcastClick
      .asyncMap(attemptMakeVisibile)
      .where((success) => success)
      .publish();

  late var contentLoader = MergeStream([onRetryClick, onDoneClick])
      .startWith(true)
      .switchMap((_) =>
          WorshipService.getWorshipContennts(widget.worship.id).asStream())
      .shareReplay(maxSize: 1);

  late var contentIsLoading = MergeStream([
    onRetryClick.map((event) => true),
    onDoneClick.map((event) => true),
    contentLoader.map((event) => false),
  ]).startWith(true).shareReplay(maxSize: 1);

  late ReplayStream<List<WorshipContent>> contents$ = createContentsStream();

  List<BuildContext> expansionContextes = [];

  late Stream<List<Song>> songs =
      contentLoader.map((v) => v.songs).switchMap((songs) {
    return onAddSong
        .scan((acc, song, _) => acc..add(song), <Song>[])
        .map((addedSongs) => [...addedSongs, ...songs])
        .startWith(songs);
  }).shareReplay(maxSize: 1);

  // These are filled when StreamBuilder attached to contentLoader loads
  List<int> timepoints = [];
  List<int> trackLengths = [];
  List<int> timeEnds = [];
  Map<int, String>? soloMap = {};
  final soloAudio = AudioPlayer();

  late var onAudioEnded = audio.processingStateStream
      .where((state) => state == ProcessingState.completed);

  late var audioPos = audio.positionStream.map((pos) => pos.inMilliseconds);

  late var audioCurrentItemChanged = audioPos
      .map((pos) => max(0, timepoints.lastIndexWhere((t) => t <= pos)))
      .distinct();

  late var running = MergeStream([
    onPlayClick.map((_) => true),
    onSoloPlayClick.map((_) => true),
    onSoloEnd.mapTo(false),
    onStopClick.map((_) => false),
    onAudioEnded.map((_) => false),
    isLive.map((isLive) => isLive),
  ]).startWith(false).shareReplay(maxSize: 1);

  final expansionCallbacked = PublishSubject<(int index, bool expanded)>();

  //#region solo controllers
  final onSoloPlayClick = PublishSubject<int>();
  final onSoloPauseClick = PublishSubject<int>();
  late final onSoloEnd = MergeStream<void>([
    onSoloPlayClick.switchMap((index) {
      var content = contents$.values.first[index];
      if (soloMap != null && soloMap!.containsKey(content.id)) {
        audio.pause();
        var soloSoundtrack = soloMap![content.id]!;

        return soloAudio
            .setAudioSource(AudioSource.uri(Uri.parse(soloSoundtrack)))
            .then((r) {
          soloAudio.play();
          return soloAudio.processingStateStream.firstWhere((element) {
            return element == ProcessingState.completed;
          });
        }).asStream();
      } else {
        soloAudio.pause();
        var seeked = Completer<void>();
        seekAudio(Duration(milliseconds: timepoints[index]), () {
          audio.play();
          seeked.complete();
        });

        return seeked.future.then((_) {
          return audio
              .createPositionStream(
                minPeriod: const Duration(milliseconds: 1),
                maxPeriod: const Duration(milliseconds: 1),
              )
              .firstWhere((pos) => pos.inMilliseconds + 100 >= timeEnds[index]);
        }).asStream();
      }
    }),
    onStopClick,
  ]).publish();

  late final soloing$ = MergeStream<int?>([
    onSoloPlayClick,
    onSoloEnd.map((_) => null),
  ]).publishValueSeeded(null);
  //#endregion

  late var panelOpenIndex = MergeStream([
    onSoloPlayClick.map((index) => index),
    contents$.map((event) => -1),
    audio.playingStream
        .where((p) => p)
        .switchMap((_) => audioCurrentItemChanged)
        .withLatestFrom(running, (a, b) => (index: a, running: b))
        .where((v) => v.running)
        .map((v) => v.index)
        .asBroadcastStream(),
    expansionCallbacked.map((event) {
      if (event.$2 == true) {
        return event.$1;
      } else {
        return -1;
      }
    }),
    onStopClick.map((_) => -1),
    abortSocketMessage.map((_) => -1),
    onAudioEnded.mapTo(-1),
    onSoloEnd.mapTo(-1),
  ]).asBroadcastStream();

  late var socket = WebSocket.connect(
    "$websocketPath/live-worship/${widget.worship.id}",
    headers: {"accesstoken": mainAccessToken},
  ).asStream().shareReplay(maxSize: 1);

  late var socketMessages =
      socket.switchMap((s) => s.map((m) => m.toString())).share();

  late var participantsSocketMessage =
      socketMessages.where((m) => m.startsWith("participants:")).map((event) {
    return (jsonDecode(event.substring("participants:".length)) as List)
        .map((e) => Participant.fromJson(e))
        .toList();
  }).shareReplay(maxSize: 1);

  late Stream<CountdownState> countdownSocketMessage =
      socketMessages.where((m) => m.startsWith("countdown:")).map((m) {
    var args = m.split(":");
    return (
      timeLeft: int.parse(args[1]),
      paused: args.elementAtOrNull(2) == "paused"
    );
  }).share();

  late Stream<PlayingState> playingSocketMessage =
      socketMessages.where((m) => m.startsWith("playing:")).map((message) {
    var args = message.split(":");
    return (
      time: int.parse(args[1]),
      paused: args.elementAtOrNull(2) == "paused"
    );
  }).share();

  late var abortSocketMessage =
      socketMessages.where((p) => p == "abort").map((_) => true).share();

  late var isLive = MergeStream([
    countdownSocketMessage.map((_) => true),
    playingSocketMessage.map((_) => true),
    abortSocketMessage.map((_) => false),
  ]).startWith(false).shareReplay(maxSize: 1);

  final audio = AudioPlayer();
  List<StreamSubscription> subs = [];

  @override
  void initState() {
    super.initState();

    WakelockPlus.enable();

    var startAudio = MergeStream([onPlayClick, onResumeClick]).listen((_) {
      audio.play();
    });

    var pauseAudio = MergeStream([
      onPauseClick.map((_) => "pause"),
      onSoloPauseClick.map((_) => "pause"),
      onStopClick.map((_) => "stop"),
      onAudioEnded.map((_) => "stop"),
      onSoloEnd.map((_) => "stop")
    ]).listen((cause) {
      audio.pause();
      if (cause == "stop") {
        audio.seek(Duration.zero);
      }
    });

    var nextPrevBtns = MergeStream([
      onNextClick
          .withLatestFrom(audioCurrentItemChanged, (_, b) => b)
          .where((currentItem) => currentItem < timepoints.length - 1)
          .map((currentItem) => timepoints[currentItem + 1]),
      onPreviousClick
          .withLatestFrom(audioCurrentItemChanged, (_, b) => b)
          .map((currentItem) {
        if (currentItem > 0) {
          return timepoints[currentItem - 1];
        } else {
          return 0;
        }
      }),
    ])
        .withLatestFrom(isLive, (a, b) => (data: a, isLive: b))
        .where((event) => !event.isLive)
        .map((event) => event.data)
        .listen((pos) => seekAudio(
              Duration(milliseconds: pos),
              () => audio.play(),
            ));

    var sendSocketMessage = CombineLatestStream.combine2(
      socket,
      isLive,
      (a, b) => (socket: a, isLive: b),
    ).switchMap((v) {
      return MergeStream([
        onAllowedBroadcastClick.map((_) => "start-countdown"),
        onPauseCountdownClick.map((_) => "pause-countdown"),
        onResumeCountdownClick.map((_) => "resume-countdown"),
        onAbortCountdownClick.map((_) => "abort"),
        onSkipCountdownClick.map((_) => "skip-countdown"),
        if (v.isLive) ...[
          onPauseClick.map((_) => "paused"),
          onResumeClick
              .withLatestFrom(playingSocketMessage, (a, b) => b)
              .map((v) => "playing:${v.time}"),
          onPreviousClick
              .withLatestFrom(audioCurrentItemChanged, (_, b) => b)
              .map((currentItem) {
            if (currentItem > 0) {
              return "playing:${timepoints[currentItem - 1]}";
            } else {
              return "playing:0";
            }
          }),
          onNextClick
              .withLatestFrom(audioCurrentItemChanged, (a, b) => b)
              .where((currentItem) => currentItem < timepoints.length - 1)
              .map((currentItem) => "playing:${timepoints[currentItem + 1]}"),
          onPauseClick
              .withLatestFrom(audioCurrentItemChanged, (a, b) => b)
              .where((currentItem) => currentItem > 0)
              .map((currentItem) => "playing:${timepoints[currentItem - 1]}"),
          onStopClick.map((currentItem) => "abort"),
          onAudioEnded.map((currentItem) => "abort"),
        ],
      ]).map((message) => (socket: v.socket, message: message));
    }).listen((event) => event.socket.add(event.message));

    var onPlayMessage = playingSocketMessage.listen((event) {
      seekAudio(Duration(milliseconds: event.time), () {
        if (!event.paused) {
          audio.play();
        } else {
          audio.pause();
        }
      });
    });

    var deleteClick = onDeleteContent.listen((content) {
      WorshipService.removeContent(widget.worship.id, content.id);
    });

    var doneClick = onDoneClick.listen((value) {
      widget.worship.title = titleController.value.text;
      titleNotifier.value = titleController.value.text;
      WorshipService.editWorship(widget.worship.id, {
        "title": titleController.text,
      }).then((value) {
        bannerNotifier.value = value.banner;
      });
    });

    subs.addAll([
      startAudio,
      pauseAudio,
      nextPrevBtns,
      sendSocketMessage,
      onPlayMessage,
      deleteClick,
      doneClick,

      // Note: must listen early in order to capture participants before countdown
      participantsSocketMessage.listen((event) {}),
      onAllowedBroadcastClick.connect(),
      onSoloEnd.connect(),
      soloing$.connect(),
    ]);
  }

  seekAudio(Duration duration, void Function() callback) {
    switch (audio.processingState) {
      case ProcessingState.completed || ProcessingState.ready:
        audio.seek(duration);
        callback();
        break;
      default:
        audio.processingStateStream
            .firstWhere((s) => s == ProcessingState.ready)
            .then((_) {
          audio.seek(duration);
          callback();
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    var mainScaffold = Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder(
          valueListenable: titleNotifier,
          builder: (context, value, child) {
            return Text(value);
          },
        ),
        actions: [
          PopupMenuButton(
            itemBuilder: (context) {
              return [
                PopupMenuItem(
                  onTap: () {
                    Share.shareUri(
                      Uri.https(
                        "prayershub.com",
                        "/worship/${widget.worship.slug}",
                      ),
                    );
                  },
                  child: const Row(children: [
                    Icon(Icons.share),
                    SizedBox(width: kMargin / 2),
                    Text("Share"),
                  ]),
                ),
                PopupMenuItem(
                  onTap: () => onDeleteClick(context),
                  child: const Row(children: [
                    Icon(Icons.delete, color: Colors.red),
                    SizedBox(width: kMargin / 2),
                    Text("Delete", style: TextStyle(color: Colors.red)),
                  ]),
                ),
              ];
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: kMargin * 15),
            children: [
              Hero(
                tag: heroes.worshipBanner(widget.worship.id),
                child: AspectRatio(
                  aspectRatio: 16 / 5,
                  child: Container(
                    color: Colors.black12,
                    child: ValueListenableBuilder(
                      valueListenable: bannerNotifier,
                      builder: (_, url, ___) => Image.network(url),
                    ),
                  ),
                ),
              ),
              StreamToWidget(
                editing,
                converter: (editing) {
                  if (!editing) return const SizedBox();

                  return Container(
                    padding: const EdgeInsets.all(kMargin),
                    child: TextFormField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: "Title",
                        border: OutlineInputBorder(),
                        hintText: "Worship title",
                      ),
                    ),
                  );
                },
              ),
              _SubscribeButton(user: widget.user),
              StreamBuilder(
                stream: CombineLatestStream.combine2(
                  contentLoader,
                  contentIsLoading,
                  (a, b) => (contents: a, loading: b),
                ),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const LoadingWidget(
                        padding: EdgeInsets.all(kMargin));
                  } else if (snapshot.hasError || !snapshot.hasData) {
                    if (snapshot.error is SocketException) {
                      return NoConnectionWidget(
                          inScaffold: false,
                          onRetryClick: () => onRetryClick.add(true));
                    } else {
                      return InternalServerErrorWidget(
                          onRetryClick: () => onRetryClick.add(true));
                    }
                  }

                  var (contents: data, :loading) = snapshot.data!;

                  if (loading) {
                    return const LoadingWidget(
                        padding: EdgeInsets.all(kMargin));
                  }

                  Compilation compilation = data.compilation;
                  audio.setUrl(data.compilation.soundtrack);

                  trackLengths = compilation.trackLengths;
                  timepoints = trackLengths.fold(
                    (arr: <int>[], t: 0),
                    (acc, dur) => (arr: acc.arr..add(acc.t), t: acc.t + dur),
                  ).arr;
                  timeEnds = trackLengths.fold(
                    (t: 0, arr: <int>[]),
                    (acc, dur) =>
                        (t: acc.t + dur, arr: acc.arr..add(acc.t + dur)),
                  ).arr;
                  soloMap = data.soloMap;

                  return StreamBuilder(
                      stream: CombineLatestStream.combine4(
                        panelOpenIndex.startWith(-1),
                        editing.startWith(false),
                        contents$.startWith([]),
                        songs.startWith([]),
                        (a, b, c, d) =>
                            (openIndex: a, editing: b, contents: c, songs: d),
                      ),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const SizedBox.shrink();
                        }

                        var (:editing, :openIndex, :contents, :songs) =
                            snapshot.requireData;

                        if (contents.isEmpty) {
                          var textStyle = const TextStyle(
                            color: Colors.black,
                            fontSize: 18,
                          );

                          return Container(
                            padding: const EdgeInsets.all(kMargin),
                            child: RichText(
                              textAlign: TextAlign.center,
                              text: TextSpan(
                                children: [
                                  TextSpan(
                                    text: "Your worship is empty, press the ",
                                    style: textStyle,
                                  ),
                                  const WidgetSpan(
                                    child: Icon(Icons.edit, size: 20),
                                  ),
                                  TextSpan(
                                    text: " to add songs, psalms, and prayers.",
                                    style: textStyle,
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        if (!editing) {
                          return contentList(contents, songs, openIndex);
                        } else {
                          return editContentList(contents, songs, openIndex);
                        }
                      });
                },
              ),
              const SizedBox(height: kMargin * 5),
            ],
          ),
          StreamToWidget(editing, converter: (editing) {
            if (!editing) {
              return const SizedBox.shrink();
            }

            return Positioned(
              bottom: kMargin * 2,
              right: kMargin,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        useSafeArea: true,
                        showDragHandle: true,
                        isScrollControlled: true,
                        builder: (context) => Scaffold(
                          body: _showAdder(context),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: kMargin, vertical: kMargin / 2),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.add, color: Colors.white),
                        SizedBox(width: kMargin / 2),
                        Text("Add content"),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () => onDoneClick.add(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: kMargin,
                        vertical: kMargin / 2,
                      ),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.done, color: Colors.white),
                        SizedBox(width: kMargin / 2),
                        Text("Done"),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
      floatingActionButton: StreamToWidget(
        CombineLatestStream.combine2(
          editing,
          running,
          (a, b) => (editing: a, running: b),
        ),
        converter: (state) {
          if (state.editing || state.running || !isOwner) {
            return const SizedBox.shrink();
          }

          return FloatingActionButton(
            onPressed: () => onEditClick.add(true),
            child: const Icon(Icons.edit),
          );
        },
      ),
      bottomNavigationBar: StreamBuilder(
        stream: CombineLatestStream.combine5(
          contents$,
          running,
          audio.playingStream,
          editing,
          soloing$.map((index) => index != null),
          (a, b, c, d, e) =>
              (contents: a, running: b, playing: c, editing: d, soloing: e),
        ),
        initialData: (
          contents: [],
          running: false,
          playing: false,
          editing: false,
          soloing: false,
        ),
        builder: (context, snapshot) {
          var (:contents, :running, :playing, :editing, :soloing) =
              snapshot.requireData;
          if (contents.isEmpty || editing) {
            return const SizedBox.shrink();
          }

          return ContainerRow(
            color: Theme.of(context).primaryColor,
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              if (!running)
                TextButton(
                  onPressed: () => onPlayClick.add(true),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow),
                      Text("Play"),
                    ],
                  ),
                ),
              if (!running && isOwner)
                TextButton(
                  onPressed: () => onBroadcastClick.add(true),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_tethering),
                      Text("Broadcast"),
                    ],
                  ),
                ),
              if (running)
                TextButton(
                  onPressed: soloing ? null : () => onPreviousClick.add(true),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.skip_previous),
                      Text("Previous"),
                    ],
                  ),
                ),
              if (running && playing)
                TextButton(
                  onPressed: () => onPauseClick.add(true),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.pause),
                      Text("Pause"),
                    ],
                  ),
                ),
              if (running && !playing)
                TextButton(
                  onPressed: () => onResumeClick.add(true),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow),
                      Text("Resume"),
                    ],
                  ),
                ),
              if (running)
                TextButton(
                  onPressed: () => onStopClick.add(true),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.stop_circle),
                      Text("Stop"),
                    ],
                  ),
                ),
              if (running)
                TextButton(
                  onPressed: soloing ? null : () => onNextClick.add(true),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.skip_next),
                      Text("Next"),
                    ],
                  ),
                ),
              StreamToWidget(
                participantsSocketMessage.startWith([]),
                converter: (participants) {
                  return TextButton(
                    onPressed: () => navigate(
                      context,
                      WorshipParticipants(
                        participants: participantsSocketMessage,
                      ),
                    ),
                    // onPressed: () => showParticipants.value = true,
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.group_outlined),
                        Text(participants.length.toString()),
                      ],
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );

    var showCountdown = MergeStream([
      countdownSocketMessage.map((event) => true),
      playingSocketMessage.map((event) => false),
      abortSocketMessage.map((event) => false),
    ]).startWith(false).shareReplay(maxSize: 1);

    return Stack(
      fit: StackFit.expand,
      children: [
        mainScaffold,
        StreamBuilder(
          stream: CombineLatestStream.combine3(
            contents$,
            countdownSocketMessage,
            showCountdown,
            (a, b, c) => (contents: a, state: b, show: c),
          ),
          builder: (context, snapshot) {
            if (snapshot.data == null) {
              return const SizedBox.shrink();
            }

            final (:contents, :state, :show) = snapshot.requireData;
            if (!show) {
              return const SizedBox.shrink();
            }

            return DefaultTabController(
              length: 3,
              child: Scaffold(
                appBar: AppBar(
                  titleSpacing: 0,
                  title: Text("Countdown: ${widget.worship.title}"),
                  bottom: const TabBar.secondary(
                    tabs: [
                      Tab(text: "Countdown"),
                      Tab(text: "Contents"),
                    ],
                  ),
                ),
                body: TabBarView(
                  children: [
                    Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(kMargin),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: Colors.black12),
                            ),
                          ),
                          child: Counter(state: state),
                        ),
                        Expanded(
                          child: Worshippers(
                            participants: participantsSocketMessage,
                          ),
                        ),
                      ],
                    ),
                    ContentList(contents: contents),
                  ],
                ),
                bottomNavigationBar:
                    isOwner ? _countdownActions(context, state) : null,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _countdownActions(BuildContext context, CountdownState state) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.red,
            disabledForegroundColor: Colors.grey,
          ),
          onPressed: isOwner ? () => onAbortCountdownClick.add(true) : null,
          child: const Text("Abort"),
        ),
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: Colors.transparent,
            foregroundColor: Theme.of(context).primaryColor,
            disabledForegroundColor: Colors.grey,
          ),
          onPressed: isOwner && !state.paused
              ? () => onPauseCountdownClick.add(true)
              : null,
          child: const Text("Pause"),
        ),
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: Colors.transparent,
            foregroundColor: Theme.of(context).primaryColor,
            disabledBackgroundColor: Colors.transparent,
            disabledForegroundColor: Colors.grey,
          ),
          onPressed: isOwner && state.paused
              ? () => onResumeCountdownClick.add(true)
              : null,
          child: const Text("Resume"),
        ),
        TextButton(
          onPressed: isOwner ? () => onSkipCountdownClick.add(true) : null,
          child: const Text("Skip Countdown"),
        ),
      ],
    );
  }

  ReplayStream<List<WorshipContent>> createContentsStream() {
    BehaviorSubject<List<WorshipContent>> contents = BehaviorSubject.seeded([]);

    var sub1 = contentLoader.listen((event) {
      contents.add(event.contents);
    });

    var sub2 = onDeleteContent.listen((content) {
      contents.add(contents.value..remove(content));
      WorshipService.removeContent(widget.worship.id, content.id);
    });

    var sub3 = onSortContent.listen((event) {
      var newIndex = event.newIndex;
      var oldIndex = event.oldIndex;
      if (oldIndex < newIndex) {
        newIndex -= 1;
      }

      WorshipContent old = contents.value[oldIndex];
      contents.add(
        contents.value
          ..removeAt(event.oldIndex)
          ..insert(newIndex, old),
      );

      WorshipService.order(
        widget.worship.id,
        contents.value.map((c) => c.id).toList(),
      );
    });

    var sub4 = onAddContent.listen((content) {
      contents.add(contents.value..add(content));
    });

    return contents.doOnCancel(() {
      sub1.cancel();
      sub2.cancel();
      sub3.cancel();
      sub4.cancel();
    }).shareReplay(maxSize: 1);
  }

  Widget contentList(
    List<WorshipContent> contents,
    List<Song> songs,
    int openIndex,
  ) {
    List<BuildContext> panelContextes = [];

    Future.delayed(
      const Duration(milliseconds: 500),
      () {
        try {
          Scrollable.ensureVisible(
            panelContextes[openIndex],
            alignment: 0,
            duration: const Duration(milliseconds: 500),
          );
        } catch (e) {
          // yeet
        }
      },
    );

    return ExpansionPanelList(
      expandedHeaderPadding: EdgeInsets.zero,
      animationDuration: const Duration(milliseconds: 400),
      expansionCallback: (panelIndex, isExpanded) {
        expansionCallbacked.add((panelIndex, isExpanded));
      },
      children: contents.mapIndexed((index, content) {
        return ExpansionPanel(
          canTapOnHeader: true,
          isExpanded: openIndex == index,
          headerBuilder: (context, isExpanded) {
            // HACK: this is to assign a context for scrolling
            return Builder(builder: (context) {
              panelContextes.add(context);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: kMargin),
                child: Row(
                  children: [
                    const SizedBox(width: kMargin / 2),
                    StreamToWidget(
                      Rx.combineLatest4(
                        running,
                        soloing$,
                        audio.playingStream,
                        soloAudio.playingStream,
                        (running, soloing, playing, soloAudioPlaying) {
                          return (
                            running: running,
                            soloing: soloing,
                            playing: playing,
                            soloAudioPlaying: soloAudioPlaying,
                          );
                        },
                      ),
                      converter: (data) {
                        bool isActive = data.soloing == index;
                        bool isPaused = isActive && !data.playing;

                        if (soloMap != null && soloMap![content.id] != null) {
                          isPaused = isActive && !data.soloAudioPlaying;
                        }

                        if (data.running && data.soloing == null) {
                          return const SizedBox();
                        }

                        return FloatingActionButton.small(
                            shape: const RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.all(Radius.circular(5)),
                            ),
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            onPressed: () {
                              if (!isActive) {
                                onSoloPlayClick.add(index);
                              } else if (isPaused) {
                                audio.play();
                              } else {
                                onSoloPauseClick.add(index);
                              }
                            },
                            child: Icon(
                              isActive && !isPaused
                                  ? Icons.pause
                                  : Icons.play_arrow,
                            ));
                      },
                    ),
                    const SizedBox(width: kMargin / 2),
                    Icon(convertTypeToIcon(content.type), size: 16),
                    const SizedBox(width: kMargin),
                    Expanded(
                      child: Text(
                        content.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            });
          },
          body: buildContentBody(
            context,
            content,
            index,
            songs,
            trackLengths,
          ),
        );
      }).toList(),
    );
  }

  Widget editContentList(
    List<WorshipContent> contents,
    List<Song> songs,
    int openIndex,
  ) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: contents.length,
      onReorder: (oldIndex, newIndex) =>
          onSortContent.add((oldIndex: oldIndex, newIndex: newIndex)),
      itemBuilder: (context, index) {
        var content = contents[index];

        return Padding(
          key: ValueKey(content),
          padding: const EdgeInsets.symmetric(vertical: kMargin / 3),
          child: Row(
            children: [
              IconButton(
                onPressed: () => onDeleteContent.add(content),
                icon: const Icon(Icons.delete, color: Colors.red),
              ),
              Icon(convertTypeToIcon(content.type), size: 16),
              const SizedBox(width: kMargin),
              Expanded(
                child: Text(
                  content.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: kMargin),
              if (content.type == "song")
                IconButton(
                  onPressed: () =>
                      onChangeInstrumentClick(context, content, songs),
                  icon: const Icon(Icons.piano),
                ),
              ReorderableDragStartListener(
                index: index,
                child: IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.drag_indicator),
                ),
              )
            ],
          ),
        );
      },
    );
  }

  Widget buildContentBody(
    BuildContext context,
    WorshipContent content,
    int index,
    List<Song> songs,
    List<int> trackLengths,
  ) {
    var isOnSoloMap = soloMap != null && soloMap![content.id] != null;

    var active = soloing$.switchMap((soloIndex) {
      if (isOnSoloMap && soloIndex == index) {
        return Stream.value(true).shareReplay(maxSize: 1);
      } else {
        return audioPos
            .map((t) => t > timepoints[index] && t < timeEnds[index])
            .distinct();
      }
    });
    var currentTime = soloing$.switchMap((soloIndex) {
      if (isOnSoloMap && soloIndex == index) {
        return soloAudio.positionStream.map((pos) => pos.inMilliseconds);
      } else {
        return audioPos.map(
            (pos) => (pos - timepoints[index]).clamp(0, trackLengths[index]));
      }
    });

    if (content.type == "song") {
      int songId = (content.data as SongData).songId;
      Song? song = songs.firstWhereOrNull((s) => s.id == songId);
      if (song == null) {
        return Text(
            "Could not find song: $songId, please report to info@prayershub.com");
      }

      return SongContent(
        soundtrack:
            song.getSoundtrack((content.data as SongData).instrument).main,
        lyrics: song.lyrics,
        duration: trackLengths.elementAtOrNull(index) ?? 0,
        introDuration: song.introDuration,
        running: running,
        currentTime: currentTime,
        active: active,
      );
    } else if (content.type == "scripture") {
      return ScriptureContent(
        content: content,
        scripture: content.data as Scripture,
        running: running,
        duration: trackLengths.elementAtOrNull(index) ?? 0,
        time: currentTime,
        active: active,
      );
    } else if (content.type == "prayer") {
      return PrayerContent(
        prayer: content.data as Prayer,
        running: running,
      );
    } else if (content.type == "custom") {
      return CustomContent(
        custom: content.data as Custom,
        running: running,
      );
    } else {
      return Text("unknown type: ${content.type} (${content.id})");
    }
  }

  Widget _showAdder(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        const TabBar(tabs: [
          Tab(text: "Songs"),
          Tab(text: "Scripture"),
          Tab(text: "Prayers"),
          // TODO: remove youtube
          // Tab(text: "Youtube"),
        ]),
        Expanded(
          child: Center(
            child: TabBarView(children: [
              SongTabView(
                onSongSelected: createSong,
              ),
              ScriptureTabView(
                addScripture: createScripture,
              ),
              PrayerTabView(
                addPrayer: createPrayer,
                addPrayerListing: createPrayerListing,
              ),
              // TODO: remove youtube
              // CustomTabView(
              //   addYoutubeVideo: createYoutubeAudio,
              // ),
            ]),
          ),
        ),
      ]),
    );
  }

  Future<bool> createSong(Song song, Soundtrack track) async {
    var res = await WorshipService.addSong(
      widget.worship.id,
      song.id,
      track.name,
    );
    if (res == null) {
      return false;
    }
    onAddSong.add(res.$1);
    onAddContent.add(res.$2);
    return true;
  }

  Future<bool> createScripture(TempScriptureData data) async {
    WorshipContent? res = await WorshipService.addScripture(
      widget.worship.slug,
      data,
    );
    if (res == null) {
      return false;
    }

    onAddContent.add(res);
    return true;
  }

  Future<bool> createPrayer(language, title, content) async {
    WorshipContent? res = await WorshipService.addPrayer(
      widget.worship.id,
      language,
      title,
      content,
    );
    if (res == null) {
      return false;
    }

    onAddContent.add(res);
    return true;
  }

  Future<bool> createPrayerListing(context, listing) async {
    WorshipContent? res = await WorshipService.addPrayerListing(
      widget.worship.id,
      listing.id,
    );
    if (res == null) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Internal Server Error, please try again later"),
      ));
      return false;
    }

    onAddContent.add(res);
    return true;
  }

  Future<bool> createYoutubeAudio(context, url, lyrics) async {
    try {
      WorshipContent content = await WorshipService.addYoutubeVideo(
          widget.worship.slug, url, lyrics);

      onAddContent.add(content);

      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Success! \"${content.title}\" added"),
      ));
      return true;
    } on AddYoutubeVideoException catch (ex) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ex.error),
      ));
      return false;
    } catch (e) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Unknown error, please try again later."),
      ));
      return false;
    }
  }

  Future<bool> attemptMakeVisibile(_) async {
    if (widget.worship.visibility != "private") return true;

    bool confirmToMakePublic = await confirm(
      context,
      title: ContainerColumn(children: [
        FaIcon(
          FontAwesomeIcons.earthAmericas,
          size: 32,
          color: Colors.grey[600],
        ),
        const SizedBox(height: kMargin),
        Text(
          "Worship is private",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600]),
        ),
      ]),
      textOK: const Text("Make Public"),
      canPop: true,
      showContent: false,
    );

    if (!confirmToMakePublic) {
      return false;
    }

    await WorshipService.editWorship(widget.worship.id, {
      "visibility": "public",
    });

    widget.worship.visibility = "public";
    return true;
  }

  Future<void> onDeleteClick(BuildContext context) async {
    bool confirmed = await confirmV2(
      context,
      title: const Text("Delete worship"),
      content: const Text("Are you sure you want to delete this worship?"),
      textOK: const Text("Yes, Delete"),
      textCancel: const Text("Cancel"),
    );
    if (!confirmed) return;

    confirmed = await confirmV2(
      context,
      title: const Text("Delete worship"),
      content: const Text("Please confirm again"),
      textOK: const Text("Yes, delete worship"),
      textCancel: const Text("Nevermind"),
    );
    if (!confirmed) return;

    var success = await WorshipService.delete(
      widget.worship.slug,
    );
    if (!context.mounted) return;

    if (success) {
      worshipDeletedSignal.add(null);
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Failed to delete worship"),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> onChangeInstrumentClick(
    BuildContext context,
    WorshipContent content,
    List<Song> songs,
  ) async {
    var data = content.data as SongData;
    var song = songs.firstWhere((s) => s.id == data.songId);

    var track =
        await showSoundtrackPicker(context, song.soundtracks, data.instrument);
    if (track == null) return;

    bool ok = await WorshipService.changeSongTrack(
      widget.worship.slug,
      content.id,
      track.name,
    );

    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Failed to change track"),
      ));
    }
  }

  @override
  void dispose() {
    socket.listen((ws) => ws.close());
    WakelockPlus.disable();
    for (var sub in subs) {
      sub.cancel();
    }
    audio.dispose();
    soloAudio.dispose();
    super.dispose();
  }
}

// ------------------- UTILS
class _SubscribeButton extends StatelessWidget {
  const _SubscribeButton({
    required this.user,
  });

  final SafeUser user;

  @override
  Widget build(BuildContext context) {
    return MyContentsButton(
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SingleProfilePage(userId: user.id),
        ),
      ),
      children: [
        CircleAvatar(
          radius: 20,
          foregroundImage: NetworkImage(user.avatar),
        ),
        const SizedBox(width: kMargin),
        Text(user.name),
        const Expanded(child: SizedBox.shrink()),
        TextButton(
          onPressed: () {
            showDialog(
              context: context,
              builder: (_) => const AlertDialog.adaptive(
                content: Text("Not available yet"),
              ),
            );
          },
          child: const Text("Subscribe"),
        ),
      ],
    );
  }
}

Future<Soundtrack?> showSoundtrackPicker(
  BuildContext context,
  List<Soundtrack> soundtracks,
  String currentTrack,
) async {
  var soundtrack = await showModalBottomSheet<Soundtrack>(
    context: context,
    builder: (context) {
      return Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: kMargin),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey[400]!, width: 1),
              ),
            ),
            child: const Text(
              "Select Instrument",
              style: TextStyle(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
          for (var track in soundtracks)
            ListTile(
              title: Row(
                children: [
                  Text(track.name),
                  if (track.name == currentTrack)
                    const Padding(
                      padding: EdgeInsets.only(left: kMargin),
                      child: Icon(Icons.check_circle),
                    ),
                ],
              ),
              enabled: true,
              onTap: () => Navigator.pop(context, track),
            ),
        ],
      );
    },
  );

  return soundtrack;
}
