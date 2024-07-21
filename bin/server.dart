import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sorcerers_core/game/game.dart';
import 'package:sorcerers_core/online/messages/messages_client.dart';
import 'package:sorcerers_core/online/messages/messages_server.dart';
import 'package:sorcerers_core/utils.dart';
import 'package:uuid/data.dart';
import 'package:uuid/rng.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/adapter_web_socket_channel.dart';

typedef LobbyName = String;
typedef ConnectionId = int;

final lobbies = <LobbyName, ServerLobby>{};

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
    channel.sink.add(jsonEncode(message.toJson()));
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
  ServerLobbyState? state;

  PlayerAdapter({
    required this.playerId,
    required this.reconnectId,
    required this.connection,
  });

  void onMessage(ClientMessage clientMessage) {
    switch (state) {
      case null:
        if (clientMessage is SetName) {
          state = ServerLobbyStateIdle();
          print('Set name: ${clientMessage.playerName}');
        } else {
          print('Must set name first');
          return;
        }

      case ServerLobbyStateIdle():
        switch (clientMessage) {
          case CreateLobby(lobbyName: final lobbyName):
            if (lobbies[lobbyName] == null) {
              final lobby = ServerLobby(lobbyName, this);
              lobbies[lobbyName] = lobby;

              state = ServerLobbyStateInLobby(lobby);
            } else {
              print('Lobby "$lobbyName" already exists');
            }
            break;
          case JoinLobby(lobbyName: final lobbyName):
            final lobby = lobbies[lobbyName];
            if (lobby != null) {
              lobby.add(this);
              state = ServerLobbyStateInLobby(lobby);
            } else {
              print('Lobby "$lobbyName" does not exist');
            }
            break;
          default:
            print('Invalid message for Idle state: $clientMessage');
            break;
        }
      case ServerLobbyStateInLobby(lobby: final lobby):
        switch (clientMessage) {
          case LeaveLobby():
            lobby.leave(this);
            state = ServerLobbyStateIdle();
            break;
          case ReadyToPlay(ready: final ready):
            lobby.readyToPlay(this, ready: ready);
          default:
            print('Invalid message for InLobby state: $clientMessage');
            break;
        }
      case ServerLobbyStateInGame(lobby: final lobby, game: final game):
        switch (clientMessage) {
          case GameMessage(gameMessage: final gameMessage):
            game.onMessage(gameMessage);
            break;
          case LeaveLobby():
            lobby.leave(this);
            state = ServerLobbyStateIdle();
            break;
          default:
            print('Invalid message for InGame state: $clientMessage');
            break;
        }
    }

    sendUpdate();
  }

  void sendUpdate() {
    if (name == null) {
      return;
    }
    connection.send(StateUpdate(state?.toClient(name!)));
  }

  void onDone() {
    switch (state) {
      case ServerLobbyStateInLobby(lobby: final lobby):
      case ServerLobbyStateInGame(lobby: final lobby):
        lobby.leave(this);
        break;
      default:
        break;
    }
  }
}

class ServerLobby {
  final LobbyName lobbyName;
  final Map<PlayerId, ServerPlayerInLobby> players = {};

  ServerLobby(this.lobbyName, PlayerAdapter creator) {
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
    notifyAllInLobby();
  }

  void notifyAllInLobby() {
    for (final playerInLobby in players.values) {
      playerInLobby.player.sendUpdate();
    }
  }

  void close() {
    print('Closing lobby "$lobbyName"');
    lobbies.remove(lobbyName);
  }
}

class ServerPlayerInLobby {
  final PlayerAdapter player;
  bool ready = false;

  ServerPlayerInLobby(this.player);
}

sealed class ServerLobbyState {
  LobbyState toClient(String name) {
    switch (this) {
      case ServerLobbyStateIdle():
        return LobbyStateIdle(lobbies.entries.map((entry) {
          final lobbyName = entry.key;
          final lobby = entry.value;
          return LobbyData(lobbyName, lobby.size);
        }).toList());
      case ServerLobbyStateInLobby(lobby: final lobby):
        return LobbyStateInLobby(
          lobby.lobbyName,
          lobby.players.values.map((p) => PlayerInLobby(name, p.ready)).toList(),
        );
      case ServerLobbyStateInGame(game: final game):
        return LobbyStatePlaying(
          name,
          game.toState((_) {}),
        );
    }
  }
}

class ServerLobbyStateIdle extends ServerLobbyState {
  ServerLobbyStateIdle();
}

class ServerLobbyStateInLobby extends ServerLobbyState {
  final ServerLobby lobby;

  ServerLobbyStateInLobby(this.lobby);
}

class ServerLobbyStateInGame extends ServerLobbyState {
  final ServerLobby lobby;
  final Game game;

  ServerLobbyStateInGame(List<String> playerNames, this.lobby) : game = Game(playerNames);
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
