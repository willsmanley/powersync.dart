/// This file needs to be compiled to JavaScript with the command
/// dart compile js -O4 packages/powersync/lib/src/web/sync_worker.worker.dart -o assets/db_worker.js
/// The output should then be included in each project's `web` directory
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:async/async.dart';
import 'package:fetch_client/fetch_client.dart';
import 'package:powersync/powersync.dart';
import 'package:powersync/src/streaming_sync.dart';
import 'package:sqlite_async/web.dart';
import 'package:web/web.dart' hide RequestMode;

import '../bucket_storage.dart';
import '../database/powersync_db_mixin.dart';
import 'sync_worker_protocol.dart';

final _logger = autoLogger;

void main() {
  _SyncWorker().start();
}

class _SyncWorker {
  final SharedWorkerGlobalScope _self;
  final Map<String, _SyncRunner> _requestedSyncTasks = {};

  _SyncWorker() : _self = globalContext as SharedWorkerGlobalScope;

  void start() async {
    // Start listening for connect events, each signifies a client connecting
    // to this worker.
    EventStreamProviders.connectEvent.forTarget(_self).listen((e) {
      final ports = (e as MessageEvent).ports.toDart;
      for (final port in ports) {
        _ConnectedClient(port, this);
      }
    });
  }

  _SyncRunner referenceSyncTask(
      String databaseIdentifier, _ConnectedClient client) {
    return _requestedSyncTasks.putIfAbsent(databaseIdentifier, () {
      return _SyncRunner(databaseIdentifier);
    })
      ..registerClient(client);
  }
}

class _ConnectedClient {
  late WorkerCommunicationChannel channel;
  final _SyncWorker _worker;

  _SyncRunner? _runner;
  StreamSubscription? _logSubscription;

  _ConnectedClient(MessagePort port, this._worker) {
    channel = WorkerCommunicationChannel(
      port: port,
      requestHandler: (type, payload) async {
        switch (type) {
          case SyncWorkerMessageType.startSynchronization:
            final request = payload as StartSynchronization;
            _runner = _worker.referenceSyncTask(request.databaseName, this);
            return (JSObject(), null);
          case SyncWorkerMessageType.abortSynchronization:
            _runner?.unregisterClient(this);
            _runner = null;
            return (JSObject(), null);
          default:
            throw StateError('Unexpected message type $type');
        }
      },
    );

    _logSubscription = _logger.onRecord.listen((record) {
      final msg = StringBuffer(
          '[${record.loggerName}] ${record.level.name}: ${record.time}: ${record.message}');

      if (record.error != null) {
        msg
          ..writeln()
          ..write(record.error);
      }
      if (record.stackTrace != null) {
        msg
          ..writeln()
          ..write(record.stackTrace);
      }

      channel.notify(SyncWorkerMessageType.logEvent, msg.toString().toJS);
    });
  }

  void markClosed() {
    _logSubscription?.cancel();
    _runner?.unregisterClient(this);
    _runner = null;
  }
}

class _SyncRunner {
  final String identifier;

  final StreamGroup<_RunnerEvent> _group = StreamGroup();
  final StreamController<_RunnerEvent> _mainEvents = StreamController();

  StreamingSync? sync;
  _ConnectedClient? databaseHost;
  final connections = <_ConnectedClient>[];

  _SyncRunner(this.identifier) {
    _group.add(_mainEvents.stream);

    Future(() async {
      await for (final event in _group.stream) {
        try {
          switch (event) {
            case _AddConnection(:final client):
              connections.add(client);
              if (sync == null) {
                await _requestDatabase(client);
              }
            case _RemoveConnection(:final client):
              connections.remove(client);
              if (connections.isEmpty) {
                await sync?.abort();
                sync = null;
              }
            case _ActiveDatabaseClosed():
              _logger.info('Remote database closed, finding a new client');
              sync?.abort();
              sync = null;

              // The only reliable notification we get for a client closing is
              // when that client is currently hosting the database. Use the
              // opportunity to check whether secondary clients have also closed
              // in the meantime.
              final newHost = await _collectActiveClients();
              if (newHost == null) {
                _logger.info('No client remains');
              } else {
                await _requestDatabase(newHost);
              }
          }
        } catch (e, s) {
          _logger.warning('Error handling $event', e, s);
        }
      }
    });
  }

  /// Pings all current [connections], removing those that don't answer in 5s
  /// (as they are likely closed tabs as well).
  ///
  /// Returns the first client that responds (without waiting for others).
  Future<_ConnectedClient?> _collectActiveClients() async {
    final candidates = connections.toList();
    if (candidates.isEmpty) {
      return null;
    }

    final firstResponder = Completer<_ConnectedClient?>();
    var pendingRequests = candidates.length;

    for (final candidate in candidates) {
      candidate.channel.ping().then((_) {
        pendingRequests--;
        if (!firstResponder.isCompleted) {
          firstResponder.complete(candidate);
        }
      }).timeout(const Duration(seconds: 5), onTimeout: () {
        pendingRequests--;
        candidate.markClosed();
        if (pendingRequests == 0 && !firstResponder.isCompleted) {
          // All requests have timed out, no connection remains
          firstResponder.complete(null);
        }
      });
    }

    return firstResponder.future;
  }

  Future<void> _requestDatabase(_ConnectedClient client) async {
    _logger.info('Sync setup: Requesting database');

    // This is the first client, ask for a database connection
    final connection = await client.channel.requestDatabase();
    _logger.info('Sync setup: Connecting to endpoint');
    final database = await WebSqliteConnection.connectToEndpoint((
      connectPort: connection.databasePort,
      connectName: connection.databaseName,
      lockName: connection.lockName,
    ));
    _logger.info('Sync setup: Has database, starting sync!');
    databaseHost = client;

    database.closedFuture.then((_) {
      _logger.fine('Detected closed client');
      client.markClosed();

      if (client == databaseHost) {
        _logger
            .info('Tab providing sync database has gone down, reconnecting...');
        _mainEvents.add(const _ActiveDatabaseClosed());
      }
    });

    sync = StreamingSyncImplementation(
      adapter: BucketStorage(database),
      credentialsCallback: client.channel.credentialsCallback,
      invalidCredentialsCallback: client.channel.invalidCredentialsCallback,
      uploadCrud: client.channel.uploadCrud,
      updateStream: powerSyncUpdateNotifications(
          database.updates ?? const Stream.empty()),
      retryDelay: Duration(seconds: 3),
      client: FetchClient(mode: RequestMode.cors),
      identifier: identifier,
    );
    sync!.statusStream.listen((event) {
      _logger.fine('Broadcasting sync event: $event');
      for (final client in connections) {
        client.channel.notify(SyncWorkerMessageType.notifySyncStatus,
            SerializedSyncStatus.from(event));
      }
    });
    sync!.streamingSync();
  }

  void registerClient(_ConnectedClient client) {
    _mainEvents.add(_AddConnection(client));
  }

  void unregisterClient(_ConnectedClient client) {
    _mainEvents.add(_RemoveConnection(client));
  }
}

sealed class _RunnerEvent {}

final class _AddConnection implements _RunnerEvent {
  final _ConnectedClient client;

  _AddConnection(this.client);
}

final class _RemoveConnection implements _RunnerEvent {
  final _ConnectedClient client;

  _RemoveConnection(this.client);
}

final class _ActiveDatabaseClosed implements _RunnerEvent {
  const _ActiveDatabaseClosed();
}