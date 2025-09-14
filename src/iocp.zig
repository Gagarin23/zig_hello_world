const std = @import("std");
const windows = std.os.windows;

/// Простой thin-wrapper вокруг IOCP (I/O Completion Port) на базе std.os.windows.
///
/// Ключевые моменты:
/// - Не объявляем никаких extern: используем готовые обёртки std.os.windows:
///   CreateIoCompletionPort / PostQueuedCompletionStatus / GetQueuedCompletionStatus / CloseHandle.
/// - Тип ключа завершения (completion key) — `usize`, как и в обёртках std.
/// - Ошибки ожидания возвращаем в виде чётких ошибок (.Aborted/.Cancelled/.EOF/.Timeout),
///   что напрямую соответствует enum-результату std.os.windows.GetQueuedCompletionStatus().
pub const Iocp = struct {
    /// Нативный дескриптор порта завершений.
    handle: windows.HANDLE,

    /// Результат извлечения из очереди.
    pub const Completion = struct {
        /// Кол-во переданных байт (для I/O операций); для «пользовательских» постов — что вы положили.
        bytes_transferred: windows.DWORD,
        /// Ключ завершения — произвольное значение, обычно идентифицирует источник/объект.
        completion_key: usize,
        /// OVERLAPPED, связанный с операцией (если постили системные I/O). Может быть null,
        /// если использовали «пользовательский» пост без OVERLAPPED.
        overlapped: ?*windows.OVERLAPPED,
    };

    /// Ошибки ожидания из очереди (набор полностью соответствует std-обёртке).
    pub const WaitError = error{
    Aborted,   // очередь/объект был «заброшен» (ABANDONED_WAIT_0)
        Cancelled, // операция отменена (OPERATION_ABORTED)
        EOF,       // достигнут EOF (HANDLE_EOF)
        Timeout,   // ожидание истекло
    };

    /// Создаёт новый IOCP.
    ///
    /// Параметры:
    /// - `concurrency`: рекомендуемое число одновременно исполняющихся потоков (передаётся в
    ///   CreateIoCompletionPort как `concurrent_thread_count`). 0 => решение за ОС.
    ///
    /// Реализация:
    /// - Вызов std.os.windows.CreateIoCompletionPort с `INVALID_HANDLE_VALUE` создаёт новый порт.
    ///   (Это поведение WinAPI; std-обёртка пробрасывает ошибки и возвращает HANDLE.)
    pub fn init(concurrency: u32) !Iocp {
        const port = try windows.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE, // file_handle: создание нового порта
            null,                         // existing_completion_port: отсутствует
            0,                            // completion_key при создании порта игнорируется
            @as(windows.DWORD, @intCast(concurrency)), // concurrent_thread_count
        );
        return .{ .handle = port };
    }

    /// Привязывает дескриптор (файл/сокет/канал) к уже созданному IOCP.
    ///
    /// Параметры:
    /// - `file_handle`: произвольный дескриптор Win32, поддерживающий асинхронный I/O.
    /// - `key`: `usize`, который будет возвращаться в очереди для событий с этого дескриптора.
    ///
    /// Реализация:
    /// - Повторный вызов CreateIoCompletionPort с существующим портом.
    pub fn attach(self: *Iocp, file_handle: windows.HANDLE, key: usize) !void {
        // Возвратом будет тот же порт (HANDLE), но нам он не нужен — положимся, что OS привязала.
        _ = try windows.CreateIoCompletionPort(
            file_handle,    // привязываемый дескриптор
            self.handle,    // существующий порт
            key,            // completion key для этого дескриптора
            0,              // concurrent_thread_count игнорируется при привязке
        );
    }

    /// Посылает «пользовательское» событие в очередь (без реального I/O).
    ///
    /// Параметры:
    /// - `key`: значение, которое вы хотите извлечь в потребителе (обычно id «задачи»).
    /// - `bytes`: произвольный счётчик/полезная нагрузка в поле bytes_transferred.
    /// - `ov`: обычно null. Можно передать указатель на OVERLAPPED, если хотите связать с ним событие.
    ///
    /// Реализация:
    /// - std.os.windows.PostQueuedCompletionStatus; ошибки Unexpected пробрасываются как Zig error.
    pub fn post(self: *Iocp, key: usize, bytes: u32, ov: ?*windows.OVERLAPPED) !void {
        try windows.PostQueuedCompletionStatus(
            self.handle,
            @as(windows.DWORD, @intCast(bytes)),
            key,
            ov,
        );
    }

    /// Блокирующее извлечение одного события из очереди.
    ///
    /// Параметры:
    /// - `timeout_ms`: `null` => бесконечно (INFINITE). Иначе — таймаут в миллисекундах.
    ///
    /// Возврат:
    /// - `Completion` при успехе,
    /// - `WaitError` при аборте/отмене/EOF/таймауте.
    ///
    /// Реализация:
    /// - std.os.windows.GetQueuedCompletionStatus() возвращает enum-результат и заполняет ссылки.
    pub fn waitOne(self: *Iocp, timeout_ms: ?u32) WaitError!Completion {
        var bytes: windows.DWORD = 0;
        var key: usize = 0;
        var overlapped: ?*windows.OVERLAPPED = null;

        const res = windows.GetQueuedCompletionStatus(
            self.handle,
            &bytes,
            &key,
            &overlapped,
            timeout_ms orelse windows.INFINITE,
        );

        return switch (res) {
            .Normal => .{
                .bytes_transferred = bytes,
                .completion_key = key,
                .overlapped = overlapped,
            },
            .Aborted => error.Aborted,
            .Cancelled => error.Cancelled,
            .EOF => error.EOF,
            .Timeout => error.Timeout,
        };
    }

    /// Закрывает IOCP (дескриптор порта).
    ///
    /// Замечание:
    /// - В WinAPI закрытие порта не «будит» ожидающие потоки. Обычно для корректного завершения
    ///   рассылают N «ядовитых пилюль» через `post(...)` и только потом закрывают.
    pub fn deinit(self: *Iocp) void {
        windows.CloseHandle(self.handle);
    }
};

test "iocp basic post/wait" {
    // Простейший sanity-тест: создаём порт, отправляем пользовательское событие и читаем его.
    var iocp = try Iocp.init(0);
    defer iocp.deinit();

    const test_key: usize = 0xC0FFEE;
    const test_bytes: u32 = 1234;

    try iocp.post(test_key, test_bytes, null);

    const c = try iocp.waitOne(1000);
    try std.testing.expectEqual(@as(usize, test_key), c.completion_key);
    try std.testing.expectEqual(@as(windows.DWORD, test_bytes), c.bytes_transferred);
    try std.testing.expectEqual(@as(?*windows.OVERLAPPED, null), c.overlapped);
}
