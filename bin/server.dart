import 'dart:convert';
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

  ServerLobbyState? state;

  ClientConnection(this.id, this.channel) {
    channel.stream.listen(onMessage, onDone: onDone);
    print('Connected new client $id. Currently ${clients.length} clients connected.');
    sendUpdate();
  }

  void onMessage(dynamic message) {
    final ClientMessage clientMessage;
    try {
      clientMessage = ClientMessage.fromJson(jsonDecode(message));
    } on Exception catch (e) {
      print('Error parsing message: $e');
      return;
    }

    switch (state) {
      case null:
        if (clientMessage is SetName) {
          state = ServerLobbyStateIdle(clientMessage.playerName);
          print('Set name: ${clientMessage.playerName}');
        } else {
          print('Must set name first');
          return;
        }

      case ServerLobbyStateIdle(name: final name):
        switch (clientMessage) {
          case CreateLobby(lobbyName: final lobbyName):
            if (lobbies[lobbyName] == null) {
              final lobby = ServerLobby(lobbyName, this);
              lobbies[lobbyName] = lobby;

              state = ServerLobbyStateInLobby(name, lobby);
            } else {
              print('Lobby "$lobbyName" already exists');
            }
            break;
          case JoinLobby(lobbyName: final lobbyName):
            final lobby = lobbies[lobbyName];
            if (lobby != null) {
              lobby.add(this);
              state = ServerLobbyStateInLobby(name, lobby);
            } else {
              print('Lobby "$lobbyName" does not exist');
            }
            break;
          default:
            print('Invalid message for Idle state: $clientMessage');
            break;
        }
      case ServerLobbyStateInLobby(name: final name, lobby: final lobby):
        switch (clientMessage) {
          case LeaveLobby():
            lobby.leave(this);
            state = ServerLobbyStateIdle(name);
            break;
          case ReadyToPlay(ready: final ready):
            lobby.readyToPlay(this, ready: ready);
          default:
            print('Invalid message for InLobby state: $clientMessage');
            break;
        }
      case ServerLobbyStateInGame(name: final name, lobby: final lobby, game: final game):
        switch (clientMessage) {
          case GameMessage(gameMessage: final gameMessage):
            game.onMessage(gameMessage);
            break;
          case LeaveLobby():
            lobby.leave(this);
            state = ServerLobbyStateIdle(name);
            break;
          default:
            print('Invalid message for InGame state: $clientMessage');
            break;
        }
    }

    sendUpdate();
  }

  void send(ServerMessage message) {
    channel.sink.add(jsonEncode(message.toJson()));
  }

  void sendUpdate() {
    send(StateUpdate(state?.toClient(this)));
  }

  void close() {
    channel.sink.close();
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

    close();
    clients.remove(id);

    print('Disconnected client $id. Currently ${clients.length} clients connected.');
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

  void add(ClientConnection connection) {
    players.add(ServerPlayerInLobby(connection));
    print('Player "${connection.id}" joined lobby "$lobbyName"');
    notifyAll();
  }

  void leave(ClientConnection clientConnection) {
    players.removeWhere((p) => p.connection == clientConnection);
    print('Player "${clientConnection.id}" left lobby "$lobbyName"');
    notifyAll();
  }

  void readyToPlay(ClientConnection clientConnection, {required bool ready}) {
    final player = players.firstWhere((p) => p.connection == clientConnection);
    player.ready = ready;
    print('Player "${clientConnection.id}": ready to play in lobby "$lobbyName": $ready');
    notifyAll();
  }

  void notifyAll() {
    for (final player in players) {
      player.connection.sendUpdate();
    }
  }
}

class ServerPlayerInLobby {
  final ClientConnection connection;
  bool ready = false;

  ServerPlayerInLobby(this.connection);
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
      case ServerLobbyStateInLobby(name: final name, lobby: final lobby):
        return LobbyStateInLobby(
          name,
          lobby.lobbyName,
          lobby.players.map((p) => PlayerInLobby(name, p.ready)).toList(),
        );
      case ServerLobbyStateInGame(name: final name, game: final game):
        return LobbyStatePlaying(
          name,
          game.toState((_) {}),
        );
    }
  }
}

class ServerLobbyStateIdle extends ServerLobbyState {
  final String name;

  ServerLobbyStateIdle(this.name);
}

class ServerLobbyStateInLobby extends ServerLobbyState {
  final String name;
  final ServerLobby lobby;

  ServerLobbyStateInLobby(this.name, this.lobby);
}

class ServerLobbyStateInGame extends ServerLobbyState {
  final String name;
  final ServerLobby lobby;
  final Game game;

  ServerLobbyStateInGame(this.name, List<String> playerNames, this.lobby)
      : game = Game(playerNames);
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
