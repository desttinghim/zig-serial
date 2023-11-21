const std = @import("std");
const zig_serial = @import("serial");

pub fn main() !u8 {
    const port_name = if (@import("builtin").os.tag == .windows) "\\\\.\\COM1" else "/dev/ttyACM0";

    const port = try zig_serial.openSerialPort(port_name, zig_serial.SerialConfig{
        .baud_rate = 115200,
        .word_size = 8,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    });

    var timer = try std.time.Timer.start();
    while (true) {
        if (try zig_serial.getBytesInWaiting(port) != 0) {
            var buffer: [1024]u8 = undefined;
            const read_bytes = try zig_serial.readAvailableBytesIntoBuffer(port, &buffer);
            std.debug.print("{s}\n", .{read_bytes});
            var written: usize = 0;
            while (written < read_bytes.len) {
                written += try zig_serial.writeBytesFromBuffer(port, read_bytes);
            }
            timer.reset();
        } else {
            var time = timer.read();
            if (time >= std.time.ns_per_s * 10) {
                std.debug.print("{} seconds since last message\n", .{time / std.time.ns_per_s});
                timer.reset();
            }
            std.time.sleep(std.time.ns_per_ms);
        }
    }

    return 0;
}
