const std = @import("std");
const windows = std.os.windows;
const ws2 = windows.ws2_32;
const Iocp = @import("iocp.zig").Iocp;

fn wsaInit() !void {
    var data: ws2.WSADATA = undefined;
    const ver = @as(windows.WORD, 0x0202); // Winsock 2.2
    if (ws2.WSAStartup(ver, &data) != 0) return error.WinsockInitFailed;
}

fn closeSocket(s: ws2.SOCKET) void {
    _ = ws2.closesocket(s);
}

// Простой сервер: accept → send → recv → close
fn serverThread(args: socWrapper) void {
    const s_acc = ws2.accept(args.s_listen, null, null);
    if (s_acc == ws2.INVALID_SOCKET) return;
    defer closeSocket(s_acc);

    const hello1 = "hello ";
    _ = ws2.send(s_acc, hello1.ptr, @as(i32, @intCast(hello1.len)), 0);

    var buf: [128]u8 = undefined;
    var n = ws2.recv(s_acc, &buf, @as(i32, @intCast(buf.len)), 0);
    if (n > 0) {
        std.debug.print("server got: ", .{});
    }
    while (n > 0) {
        const got = buf[0..@as(usize, @intCast(n))];
        std.debug.print("{s}", .{got});
        n = ws2.recv(s_acc, &buf, @as(i32, @intCast(buf.len)), 0);
    }
}

const socWrapper = struct {
    s_listen: ws2.SOCKET,
};

pub fn main() !void {
    try wsaInit();
    defer _ = ws2.WSACleanup();

    // IOCP
    var port = try Iocp.init(0);
    defer port.deinit();

    // LISTEN socket (loopback:0)
    const s_listen = ws2.WSASocketW(
        @as(i32, @intCast(ws2.AF.INET)),
        ws2.SOCK.STREAM,
        ws2.IPPROTO.TCP,
        null,
        0,
        ws2.WSA_FLAG_OVERLAPPED,
    );
    if (s_listen == ws2.INVALID_SOCKET) return error.SocketCreateFailed;
    defer closeSocket(s_listen);

    var bind_addr = ws2.sockaddr.in{
        // .family по умолчанию AF.INET
        .port = ws2.htons(0),                   // порт 0 => выберет ОС
        .addr = ws2.htonl(0x7f000001),          // 127.0.0.1
    };
    if (ws2.bind(s_listen, @ptrCast(&bind_addr),
        @as(i32, @intCast(@sizeOf(ws2.sockaddr.in)))) == ws2.SOCKET_ERROR)
        return error.BindFailed;

    if (ws2.listen(s_listen, 1) == ws2.SOCKET_ERROR)
        return error.ListenFailed;

    // Узнаём фактический порт
    var actual: ws2.sockaddr.in = undefined;
    var namelen: i32 = @as(i32, @intCast(@sizeOf(ws2.sockaddr.in)));
    if (ws2.getsockname(s_listen, @ptrCast(&actual), &namelen) == ws2.SOCKET_ERROR)
        return error.GetSockNameFailed;
    const port_le: u16 = ws2.ntohs(actual.port);

    // Запускаем серверный поток (accept+send+recv)
    var th = try std.Thread.spawn(.{}, serverThread, .{ socWrapper{ .s_listen = s_listen } });
    defer th.join();

    // CLIENT socket (overlapped) → connect
    const s_cli = ws2.WSASocketW(
        @as(i32, @intCast(ws2.AF.INET)),
        ws2.SOCK.STREAM,
        ws2.IPPROTO.TCP,
        null,
        0,
        ws2.WSA_FLAG_OVERLAPPED,
    );
    if (s_cli == ws2.INVALID_SOCKET) return error.SocketCreateFailed;
    defer closeSocket(s_cli);

    var peer = ws2.sockaddr.in{
        .port = ws2.htons(port_le),
        .addr = ws2.htonl(0x7f000001),
    };
    if (ws2.connect(s_cli, @ptrCast(&peer),
        @as(i32, @intCast(@sizeOf(ws2.sockaddr.in)))) == ws2.SOCKET_ERROR)
        return error.ConnectFailed;

    // Ассоциируем клиентский сокет с IOCP
    try port.attach(@ptrCast(s_cli), 0xC0FFEE);

    // Постим overlapped WSARecv и ждём через IOCP
    // буфер для приёма
    var storage: [128]u8 = undefined;

        // 1) правильно заполняем WSABUF: .buf = [*]u8
    const wbuf = ws2.WSABUF{
            .len = @as(windows.ULONG, @intCast(storage.len)),
            .buf = storage[0..].ptr, // <-- было: &storage
    };

        // 2) WSARecv хочет [*]WSABUF: оборачиваем в массив и берём .ptr
    var bufs = [_]ws2.WSABUF{ wbuf };
        var flags: u32 = 0;
        var ov = std.mem.zeroes(windows.OVERLAPPED);

        const r = ws2.WSARecv(s_cli, bufs[0..].ptr, 1, null, &flags, &ov, null);
        if (r == ws2.SOCKET_ERROR) {
            const err = ws2.WSAGetLastError();
            if (err != .WSA_IO_PENDING) return error.WSARecvFailed;
        }

    // Ждём одно завершение
    const c = try port.waitOne(1000);
    if (c.completion_key != 0xC0FFEE) return error.BadKey;

    const got = storage[0..@as(usize, @intCast(c.bytes_transferred))];
    std.debug.print("client got: {s}\n", .{got});

    // Ответим серверу
    const p1 = "world!";
    _ = ws2.send(s_cli, got.ptr, @as(i32, @intCast(got.len)), 0);
    _ = ws2.send(s_cli, p1.ptr, @as(i32, @intCast(p1.len)), 0);
}
