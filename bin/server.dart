import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sorcerers_core/game/game.dart';
import 'package:sorcerers_core/online/messages/messages_client.dart';
import 'package:sorcerers_core/online/messages/messages_server.dart';
import 'package:web_socket_channel/adapter_web_socket_channel.dart';

typedef LobbyName = String;
typedef ConnectionId = int;

final lobbies = <LobbyName, ServerLobby>{};

final clients = <ConnectionId, ClientConnection>{};

int uniqueCounter = 0;

class ClientConnection {
  final ConnectionId id;
  final AdapterWebSocketChannel channel;

  ServerLobbyState state = ServerLobbyStateIdle();

  String? name;

  ClientConnection(this.id, this.channel) {
    channel.stream.listen(onMessage, onDone: () {
      clients.remove(id);
    });
    print('Connected new client $id. Currently ${clients.length} clients connected.');
  }

  void onMessage(dynamic message) {
    final ClientMessage clientMessage;
    try {
      clientMessage = ClientMessage.fromJson(message);
    } on Exception catch (e) {
      print('Error parsing message: $e');
      return;
    }

    if (name == null) {
      if (clientMessage is SetName) {
        name = clientMessage.playerName;
        print('Set name: $name');
      } else {
        print('Must set name first');
        return;
      }
    } else {
      switch (state) {
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
    }
    sendUpdate();
  }

  void send(ServerMessage message) {
    channel.sink.add(message.toJson());
  }

  void sendUpdate() {
    send(StateUpdate(state.toClient(this)));
  }

  void close() {
    channel.sink.close();
  }
}

class ServerLobby {
  final LobbyName lobbyName;
  final List<ServerPlayerInLobby> players = [];

  ServerLobby(this.lobbyName, ClientConnection creator) {
    print('Lobby created "$lobbyName"');
    add(creator);
  }

  int get size => players.length;

  void add(ClientConnection player) {
    players.add(ServerPlayerInLobby(player));
    print('Player "${player.id}" joined lobby "$lobbyName"');
  }

  void leave(ClientConnection clientConnection) {
    players.removeWhere((p) => p.client == clientConnection);
    print('Player "${clientConnection.id}" left lobby "$lobbyName"');
  }

  void readyToPlay(ClientConnection clientConnection, {required bool ready}) {
    final player = players.firstWhere((p) => p.client == clientConnection);
    player.ready = ready;
    print('Player "${clientConnection.id}" is ready to play in lobby "$lobbyName"');
  }
}

class ServerPlayerInLobby {
  final ClientConnection client;
  bool ready = false;

  ServerPlayerInLobby(this.client);
}

sealed class ServerLobbyState {
  LobbyState toClient(ClientConnection client) {
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
          lobby.players.map((p) => PlayerInLobby(p.client.name!, p.ready)).toList(),
        );
      case ServerLobbyStateInGame(game: final game):
        return LobbyStatePlaying(game.toState((_) {}));
    }
  }
}

class ServerLobbyStateIdle extends ServerLobbyState {}

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
