import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sorcerers_core/game/game.dart';
import 'package:sorcerers_core/online/messages/game_messages_client.dart';
import 'package:sorcerers_core/online/messages/messages_client.dart';
import 'package:sorcerers_core/online/messages/messages_server.dart';
import 'package:sorcerers_core/utils.dart';
import 'package:uuid/data.dart';
import 'package:uuid/rng.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/adapter_web_socket_channel.dart';

typedef LobbyName = String;
typedef ConnectionId = int;
const minPlayers = 2; // TODO 3

final openLobbies = <LobbyName, ServerLobby>{};
final playingLobbies = <ServerLobby>[];

final clients = <ConnectionId, ClientConnection>{};

int uniqueCounter = 0;

void notifyAll() {
  for (final connection in clients.values) {
    connection.playerAdapter?.sendUpdate();
  }
}

class ClientConnection {
  final ConnectionId id;
  final AdapterWebSocketChannel channel;

  PlayerAdapter? playerAdapter;

  ClientConnection(this.id, this.channel) {
    channel.stream.listen(onMessage, onDone: onDone);
    print('Connected new client $id. Currently ${clients.length} clients connected.');
  }

  final cryptoRNG = CryptoRNG();

  void onMessage(dynamic message) {
    print("[${playerAdapter?.playerId.substring(0, 4) ?? "null"}] >> $message");

    final ClientMessage clientMessage;
    try {
      clientMessage = ClientMessage.fromJson(jsonDecode(message));
    } on Exception catch (e) {
      print('Error parsing message: $e');
      return;
    }

    final adapter = playerAdapter;
    if (adapter == null) {
      switch (clientMessage) {
        case Hello(reconnectId: final reconnectId):
          if (reconnectId == null) {
            createNewPlayerAdapter();
          } else {
            final existingConnection = clients.values.map<ClientConnection?>((c) => c).firstWhere(
                (c) => c?.playerAdapter?.reconnectId == reconnectId,
                orElse: () => null);
            if (existingConnection != null) {
              playerAdapter = existingConnection.playerAdapter;
              existingConnection.playerAdapter = null;
              existingConnection.close();
            } else {
              createNewPlayerAdapter();
            }
          }
          sendHelloResponse();
        default:
          print("Must say hello first");
      }
    } else {
      try {
        adapter.onMessage(clientMessage);
      } on Exception catch (e) {
        print('Error handling message: $e');
        return;
      }
    }
  }

  void createNewPlayerAdapter() {
    playerAdapter = PlayerAdapter(
      playerId: Uuid().v4(),
      reconnectId: Uuid().v4(config: V4Options(null, cryptoRNG)),
      connection: this,
    );
  }

  void sendHelloResponse() {
    send(HelloResponse(playerId: playerAdapter!.playerId, reconnectId: playerAdapter!.reconnectId));
  }

  void send(ServerMessage message) {
    final raw = jsonEncode(message.toJson());
    print("[${playerAdapter?.playerId.substring(0, 4) ?? "null"}] << $raw");
    channel.sink.add(raw);
  }

  void close() {
    channel.sink.close();
  }

  void onDone() {
    playerAdapter?.onDone();
    close();
    clients.remove(id);

    print('Disconnected client $id. Currently ${clients.length} clients connected.');
  }
}

class PlayerAdapter {
  final PlayerId playerId;
  final ReconnectId reconnectId; // Secret

  ClientConnection connection;
  String? name;

  ServerLobby? lobby;

  PlayerAdapter({
    required this.playerId,
    required this.reconnectId,
    required this.connection,
  });

  void onMessage(ClientMessage clientMessage) {
    bool updated = false;

    final lobby = this.lobby;
    if (lobby == null) {
      switch (clientMessage) {
        case SetName(playerName: final name):
          this.name = name;
          print('Set name: ${clientMessage.playerName}');

        case CreateLobby(lobbyName: final lobbyName):
          if (openLobbies[lobbyName] == null) {
            final lobby = ServerLobby(lobbyName, this);
            openLobbies[lobbyName] = lobby;

            this.lobby = lobby;
            notifyAll();
            updated = true;
          } else {
            print('Lobby "$lobbyName" already exists');
          }
          break;
        case JoinLobby(lobbyName: final lobbyName):
          final lobby = openLobbies[lobbyName];
          if (lobby != null) {
            lobby.add(this);
            this.lobby = lobby;
          } else {
            print('Lobby "$lobbyName" does not exist');
          }
          break;
        default:
          print('Invalid message for Idle state: $clientMessage');
          break;
      }
    } else {
      switch (clientMessage) {
        case LeaveLobby():
          lobby.leave(this);
          this.lobby = null;
          break;
        default:
          lobby.onMessage(this, clientMessage);
          lobby.notifyAllInLobby();
          updated = true;
          break;
      }
    }

    if (!updated) {
      sendUpdate();
    }
  }

  void sendUpdate() {
    if (name == null) {
      return;
    }
    final clientState = lobby == null
        ? LobbyStateIdle(getAllOpenLobbies())
        : lobby!.getClientState(forPlayer: this);
    connection.send(StateUpdate(clientState));
  }

  void onDone() {
    lobby?.leave(this);
  }
}

List<LobbyData> getAllOpenLobbies() {
  return openLobbies.values.map((lobby) => LobbyData(lobby.lobbyName, lobby.size)).toList();
}

class ServerLobby {
  final LobbyName lobbyName;
  final Map<PlayerId, ServerPlayerInLobby> players = {};

  ServerLobbyState state;

  ServerLobby(this.lobbyName, PlayerAdapter creator) : state = ServerLobbyStateInLobby() {
    print('Lobby created "$lobbyName"');
    add(creator);
  }

  int get size => players.length;

  void add(PlayerAdapter player) {
    players[player.playerId] = ServerPlayerInLobby(player);
    print('Player "${player.playerId}" joined lobby "$lobbyName"');

    notifyAll();
  }

  void leave(PlayerAdapter player) {
    players.remove(player.playerId);
    print('Player "${player.playerId}" left lobby "$lobbyName"');
    if (players.isEmpty) {
      close();
    }

    notifyAll();
  }

  void readyToPlay(PlayerAdapter player, {required bool ready}) {
    final playerInLobby = players[player.playerId]!;
    playerInLobby.ready = ready;
    print('Player "${player.playerId}": ready to play in lobby "$lobbyName": $ready');

    if (players.length >= minPlayers && players.values.every((p) => p.ready)) {
      startToPlay();
    }

    notifyAllInLobby();
  }

  void startToPlay() {
    openLobbies.remove(lobbyName);
    playingLobbies.add(this);
    state = ServerLobbyStateInGame(players.values);
  }

  void notifyAllInLobby() {
    for (final playerInLobby in players.values) {
      playerInLobby.player.sendUpdate();
    }
  }

  void close() {
    print('Closing lobby "$lobbyName"');

    openLobbies.remove(lobbyName);
    playingLobbies.remove(this);

    for (final playerInLobby in players.values) {
      playerInLobby.player.lobby = null;
    }
  }

  void onMessage(PlayerAdapter playerAdapter, ClientMessage clientMessage) {
    switch (clientMessage) {
      case ReadyToPlay(ready: final ready):
        readyToPlay(playerAdapter, ready: ready);
      case GameMessage(gameMessage: final gameMessage):
        switch (state) {
          case ServerLobbyStateInLobby():
            print("Error: Received GameMessage, but lobby is not playing yet");
          case ServerLobbyStateInGame(game: final game):
            if (gameMessage is LeaveGame) {
              state = ServerLobbyStateInLobby(
                message: "Player ${playerAdapter.name ?? "unnamed"} has left",
              );
              leave(playerAdapter);
            } else {
              game.onMessage(fromPlayerId: clientMessage.playerId, message: gameMessage);
            }
        }
        break;
      default:
        print("Error: Received invalid message in lobby: $clientMessage");
        break;
    }
  }

  LobbyState getClientState({required PlayerAdapter forPlayer}) {
    switch (state) {
      case ServerLobbyStateInLobby(message: final message):
        return LobbyStateInLobby(
            lobbyName,
            players.values
                .map((p) => PlayerInLobby(
                      p.player.playerId,
                      p.player.name!,
                      p.ready,
                    ))
                .toList(),
            message);
      case ServerLobbyStateInGame(game: final game):
        return LobbyStatePlaying(game.toState(forPlayer.playerId));
    }
  }
}

class ServerPlayerInLobby {
  final PlayerAdapter player;
  bool ready = false;

  ServerPlayerInLobby(this.player);
}

sealed class ServerLobbyState {}

class ServerLobbyStateInLobby extends ServerLobbyState {
  String? message;

  ServerLobbyStateInLobby({this.message});
}

class ServerLobbyStateInGame extends ServerLobbyState {
  final Game game;

  ServerLobbyStateInGame(Iterable<ServerPlayerInLobby> players)
      : game = Game(players.map((p) => Player(p.player.playerId, p.player.name!)).toList());
}

final websocketHandler = webSocketHandler((webSocket) {
  var id = uniqueCounter++;
  clients[id] = ClientConnection(id, webSocket);
});

// Configure routes.
final _router = Router()
  ..get('/', _rootHandler)
  ..get('/ws', (Request request) => websocketHandler(request));

Response _rootHandler(Request req) {
  return Response.ok('Hello!\n');
}

void main(List<String> args) async {
  // Use any available host or container IP (usually `0.0.0.0`).
  final ip = InternetAddress.anyIPv4;

  // Configure a pipeline that logs requests.
  final handler = Pipeline().addMiddleware(logRequests()).addHandler(_router.call);

  // For running in containers, we respect the PORT environment variable.
  final port = int.parse(Platform.environment['PORT'] ?? '7707');
  final server = await serve(handler, ip, port);
  print('Server listening on port ${server.port}');
}
