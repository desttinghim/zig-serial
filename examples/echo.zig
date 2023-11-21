const std = @import("std");
const zig_serial = @import("serial");

pub fn main() !u8 {
    const port_name = if (@import("builtin").os.tag == .windows) "\\\\.\\COM1" else "/dev/ttyUSB0";

    const port = try zig_serial.SerialPort.open(port_name, zig_serial.SerialConfig{
        .baud_rate = 115200,
        .word_size = 8,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    });

    while (true) {
        if (try port.getBytesAvailable() != 0) {
            var buffer: [1024]u8 = undefined;
            const read_bytes = try port.read(&buffer);

            var written: usize = 0;
            while (written < read_bytes.len) {
                written += try port.write(read_bytes[written..]);
            }
        } else {
            std.time.sleep(std.time.ns_per_ms);
        }
    }

    return 0;
}
