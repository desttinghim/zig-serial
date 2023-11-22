const std = @import("std");
const zig_serial = @import("serial");

pub fn main() !u8 {
    const port_name = if (@import("builtin").os.tag == .windows) "\\\\.\\COM3" else "/dev/ttyUSB0";

    const port = try zig_serial.SerialPort.open(port_name, zig_serial.SerialConfig{
        .baud_rate = 115200,
        .word_size = 8,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    }, .Nonblocking);
    defer port.close();

    while (true) {
        var buffer: [1024]u8 = undefined;
        if (try port.getInputBytesAvailable() != 0) {
            const read_bytes = try port.read(&buffer, null);
            std.log.info("bytes read: {s}", .{read_bytes});

            try port.write(read_bytes, null);
        } else {
            std.time.sleep(std.time.ns_per_ms);
        }
    }

    return 0;
}
