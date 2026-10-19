import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A scripted SMTP server on the loopback interface, for tests of what
/// happens when a submission goes wrong at a particular point.
class FakeSmtpServer {
  FakeSmtpServer._(
    this._server, {
    required this.size,
    required this.authReply,
    required this.mailReply,
    required this.rcptReply,
    required this.dataReply,
    required this.finalReply,
    required this.dropBeforeData,
    required this.dropAfterData,
    required this.hangAfterData,
    required this.advertiseStartTls,
  }) {
    _server.listen(_serve);
  }

  static Future<FakeSmtpServer> start({
    int? size,
    String authReply = '235 2.7.0 Authentication successful',
    String mailReply = '250 2.1.0 Ok',
    String rcptReply = '250 2.1.5 Ok',
    String dataReply = '354 End data with <CR><LF>.<CR><LF>',
    String finalReply = '250 2.0.0 Ok: queued as ABC123',
    bool dropBeforeData = false,
    bool dropAfterData = false,
    bool hangAfterData = false,
    bool advertiseStartTls = false,
  }) async => FakeSmtpServer._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    size: size,
    authReply: authReply,
    mailReply: mailReply,
    rcptReply: rcptReply,
    dataReply: dataReply,
    finalReply: finalReply,
    dropBeforeData: dropBeforeData,
    dropAfterData: dropAfterData,
    hangAfterData: hangAfterData,
    advertiseStartTls: advertiseStartTls,
  );

  final ServerSocket _server;
  final int? size;
  final String authReply;
  final String mailReply;
  final String rcptReply;
  final String dataReply;
  final String finalReply;
  final bool dropBeforeData;
  final bool dropAfterData;
  final bool hangAfterData;
  final bool advertiseStartTls;

  int get port => _server.port;

  /// Every command line received, across connections.
  final List<String> commands = [];

  /// Every message body received (up to the end-of-data line).
  final List<String> messages = [];
  int connections = 0;

  Future<void> close() => _server.close();

  void _serve(Socket socket) {
    connections++;
    socket.write('220 fake.example ESMTP ready\r\n');
    var inData = false;
    final data = StringBuffer();
    var buffer = '';
    socket.listen((chunk) {
      buffer += latin1.decode(chunk);
      while (true) {
        if (inData) {
          final end = buffer.indexOf('\r\n.\r\n');
          if (end < 0) {
            return;
          }
          data.write(buffer.substring(0, end));
          buffer = buffer.substring(end + 5);
          inData = false;
          messages.add(data.toString());
          data.clear();
          if (dropAfterData) {
            socket.destroy();
            return;
          }
          if (hangAfterData) return;
          socket.write('$finalReply\r\n');
          continue;
        }
        final eol = buffer.indexOf('\r\n');
        if (eol < 0) return;
        final line = buffer.substring(0, eol);
        buffer = buffer.substring(eol + 2);
        commands.add(line);
        final upper = line.toUpperCase();
        if (upper.startsWith('EHLO')) {
          socket.write(
            '250-fake.example\r\n'
            '${size == null ? '' : '250-SIZE $size\r\n'}'
            '${advertiseStartTls ? '250-STARTTLS\r\n' : ''}'
            '250 AUTH PLAIN LOGIN\r\n',
          );
        } else if (upper.startsWith('AUTH')) {
          socket.write('$authReply\r\n');
        } else if (upper.startsWith('MAIL FROM')) {
          socket.write('$mailReply\r\n');
        } else if (upper.startsWith('RCPT TO')) {
          socket.write('$rcptReply\r\n');
        } else if (upper == 'DATA') {
          if (dropBeforeData) {
            socket.destroy();
            return;
          }
          socket.write('$dataReply\r\n');
          if (dataReply.startsWith('354')) inData = true;
        } else if (upper == 'QUIT') {
          socket.write('221 bye\r\n');
          socket.destroy();
          return;
        } else if (upper == 'RSET') {
          socket.write('250 ok\r\n');
        } else {
          socket.write('502 not implemented\r\n');
        }
      }
    }, onError: (_) {});
  }
}
