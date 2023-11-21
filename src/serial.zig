const std = @import("std");
const builtin = @import("builtin");
const c = @cImport(@cInclude("termios.h"));

pub fn list() !PortIterator {
    return try PortIterator.init();
}

pub fn list_info() !InformationIterator {
    return try InformationIterator.init();
}

pub const PortIterator = switch (builtin.os.tag) {
    .windows => WindowsPortIterator,
    .linux => LinuxPortIterator,
    .macos => DarwinPortIterator,
    else => @compileError("OS is not supported for port iteration"),
};

pub const InformationIterator = switch (builtin.os.tag) {
    .windows => WindowsInformationIterator,
    .linux, .macos => @panic("'Port Information' not yet implemented for this OS"),
    else => @compileError("OS is not supported for information iteration"),
};

pub const SerialPortDescription = struct {
    file_name: []const u8,
    display_name: []const u8,
    driver: ?[]const u8,
};

pub const PortInformation = struct {
    port_name: []const u8,
    system_location: []const u8,
    friendly_name: []const u8,
    description: []const u8,
    manufacturer: []const u8,
    serial_number: []const u8,
    // TODO: review whether to remove `hw_id`.
    // Is this useless/being used in a Windows-only way?
    hw_id: []const u8,
    vid: u16,
    pid: u16,
};

const HKEY = std.os.windows.HKEY;
const HWND = std.os.windows.HANDLE;
const HDEVINFO = std.os.windows.HANDLE;
const DEVINST = std.os.windows.DWORD;
const SP_DEVINFO_DATA = extern struct {
    cbSize: std.os.windows.DWORD,
    classGuid: std.os.windows.GUID,
    devInst: std.os.windows.DWORD,
    reserved: std.os.windows.ULONG_PTR,
};

const WindowsPortIterator = struct {
    const Self = @This();

    key: HKEY,
    index: u32,

    name: [256:0]u8 = undefined,
    name_size: u32 = 256,

    data: [256]u8 = undefined,
    filepath_data: [256]u8 = undefined,
    data_size: u32 = 256,

    pub fn init() !Self {
        const HKEY_LOCAL_MACHINE = @as(HKEY, @ptrFromInt(0x80000002));
        const KEY_READ = 0x20019;

        var self: Self = undefined;
        self.index = 0;
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "HARDWARE\\DEVICEMAP\\SERIALCOMM\\", 0, KEY_READ, &self.key) != 0)
            return error.WindowsError;

        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = RegCloseKey(self.key);
        self.* = undefined;
    }

    pub fn next(self: *Self) !?SerialPortDescription {
        defer self.index += 1;

        self.name_size = 256;
        self.data_size = 256;

        return switch (RegEnumValueA(self.key, self.index, &self.name, &self.name_size, null, null, &self.data, &self.data_size)) {
            0 => SerialPortDescription{
                .file_name = try std.fmt.bufPrint(&self.filepath_data, "\\\\.\\{s}", .{self.data[0 .. self.data_size - 1]}),
                .display_name = self.data[0 .. self.data_size - 1],
                .driver = self.name[0..self.name_size],
            },
            259 => null,
            else => error.WindowsError,
        };
    }
};

const WindowsInformationIterator = struct {
    const Self = @This();

    index: std.os.windows.DWORD,
    device_info_set: HDEVINFO,

    port_buffer: [256:0]u8,
    sys_buffer: [256:0]u8,
    name_buffer: [256:0]u8,
    desc_buffer: [256:0]u8,
    man_buffer: [256:0]u8,
    serial_buffer: [256:0]u8,
    hw_id: [256:0]u8,

    const Property = enum(std.os.windows.DWORD) {
        SPDRP_DEVICEDESC = 0x00000000,
        SPDRP_MFG = 0x0000000B,
        SPDRP_FRIENDLYNAME = 0x0000000C,
    };

    // GUID taken from <devguid.h>
    const DIGCF_PRESENT = 0x00000002;
    const DIGCF_DEVICEINTERFACE = 0x00000010;
    const device_setup_tokens = .{
        .{ std.os.windows.GUID{ .Data1 = 0x4d36e978, .Data2 = 0xe325, .Data3 = 0x11ce, .Data4 = .{ 0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18 } }, DIGCF_PRESENT },
        .{ std.os.windows.GUID{ .Data1 = 0x4d36e96d, .Data2 = 0xe325, .Data3 = 0x11ce, .Data4 = .{ 0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18 } }, DIGCF_PRESENT },
        .{ std.os.windows.GUID{ .Data1 = 0x86e0d1e0, .Data2 = 0x8089, .Data3 = 0x11d0, .Data4 = .{ 0x9c, 0xe4, 0x08, 0x00, 0x3e, 0x30, 0x1f, 0x73 } }, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE },
        .{ std.os.windows.GUID{ .Data1 = 0x2c7089aa, .Data2 = 0x2e0e, .Data3 = 0x11d1, .Data4 = .{ 0xb1, 0x14, 0x00, 0xc0, 0x4f, 0xc2, 0xaa, 0xe4 } }, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE },
    };

    pub fn init() !Self {
        var self: Self = undefined;
        self.index = 0;

        inline for (device_setup_tokens) |token| {
            const guid = token[0];
            const flags = token[1];

            self.device_info_set = SetupDiGetClassDevsW(
                &guid,
                null,
                null,
                flags,
            );

            if (self.device_info_set != std.os.windows.INVALID_HANDLE_VALUE) break;
        }

        if (self.device_info_set == std.os.windows.INVALID_HANDLE_VALUE) return error.WindowsError;

        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = SetupDiDestroyDeviceInfoList(self.device_info_set);
        self.* = undefined;
    }

    pub fn next(self: *Self) !?PortInformation {
        var device_info_data: SP_DEVINFO_DATA = .{
            .cbSize = @sizeOf(SP_DEVINFO_DATA),
            .classGuid = std.mem.zeroes(std.os.windows.GUID),
            .devInst = 0,
            .reserved = 0,
        };

        if (SetupDiEnumDeviceInfo(self.device_info_set, self.index, &device_info_data) != std.os.windows.TRUE) {
            return null;
        }

        defer self.index += 1;

        var info: PortInformation = std.mem.zeroes(PortInformation);
        @memset(&self.hw_id, 0);

        // NOTE: have not handled if port startswith("LPT")
        var length = getPortName(&self.device_info_set, &device_info_data, &self.port_buffer);
        info.port_name = self.port_buffer[0..length];

        info.system_location = try std.fmt.bufPrint(&self.sys_buffer, "\\\\.\\{s}", .{info.port_name});

        length = deviceRegistryProperty(&self.device_info_set, &device_info_data, Property.SPDRP_FRIENDLYNAME, &self.name_buffer);
        info.friendly_name = self.name_buffer[0..length];

        length = deviceRegistryProperty(&self.device_info_set, &device_info_data, Property.SPDRP_DEVICEDESC, &self.desc_buffer);
        info.description = self.desc_buffer[0..length];

        length = deviceRegistryProperty(&self.device_info_set, &device_info_data, Property.SPDRP_MFG, &self.man_buffer);
        info.manufacturer = self.man_buffer[0..length];

        if (SetupDiGetDeviceInstanceIdA(
            self.device_info_set,
            &device_info_data,
            @ptrCast(&self.hw_id),
            255,
            null,
        ) == std.os.windows.TRUE) {
            length = @as(u32, @truncate(std.mem.indexOfSentinel(u8, 0, &self.hw_id)));
            info.hw_id = self.hw_id[0..length];

            length = parseSerialNumber(&self.hw_id, &self.serial_buffer) catch 0;
            if (length == 0) {
                length = getParentSerialNumber(device_info_data.devInst, &self.hw_id, &self.serial_buffer) catch 0;
            }
            info.serial_number = self.serial_buffer[0..length];
            info.vid = parseVendorId(&self.hw_id) catch 0;
            info.pid = parseProductId(&self.hw_id) catch 0;
        } else {
            return error.WindowsError;
        }

        return info;
    }

    fn getPortName(device_info_set: *const HDEVINFO, device_info_data: *SP_DEVINFO_DATA, port_name: [*]u8) std.os.windows.DWORD {
        const hkey: HKEY = SetupDiOpenDevRegKey(
            device_info_set.*,
            device_info_data,
            0x00000001, // #define DICS_FLAG_GLOBAL
            0,
            0x00000001, // #define DIREG_DEV,
            std.os.windows.KEY_READ,
        );

        defer {
            _ = std.os.windows.advapi32.RegCloseKey(hkey);
        }

        inline for (.{ "PortName", "PortNumber" }) |key_token| {
            var port_length: std.os.windows.DWORD = std.os.windows.NAME_MAX;
            var data_type: std.os.windows.DWORD = 0;

            const result = std.os.windows.advapi32.RegQueryValueExW(
                hkey,
                std.unicode.utf8ToUtf16LeStringLiteral(key_token),
                null,
                &data_type,
                @as(?*std.os.windows.BYTE, @ptrCast(port_name)),
                &port_length,
            );

            // if this is valid, return now
            if (result == 0 and port_length > 0) {
                return port_length;
            }
        }

        return 0;
    }

    fn deviceRegistryProperty(device_info_set: *const HDEVINFO, device_info_data: *SP_DEVINFO_DATA, property: Property, property_str: [*]u8) std.os.windows.DWORD {
        var data_type: std.os.windows.DWORD = 0;
        var bytes_required: std.os.windows.DWORD = std.os.windows.MAX_PATH;

        const result = SetupDiGetDeviceRegistryPropertyW(
            device_info_set.*,
            device_info_data,
            @intFromEnum(property),
            &data_type,
            @as(?*std.os.windows.BYTE, @ptrCast(property_str)),
            std.os.windows.NAME_MAX,
            &bytes_required,
        );

        if (result == std.os.windows.FALSE) {
            std.debug.print("GetLastError: {}\n", .{std.os.windows.kernel32.GetLastError()});
            bytes_required = 0;
        }

        return bytes_required;
    }

    fn getParentSerialNumber(devinst: DEVINST, devid: []const u8, serial_number: [*]u8) !std.os.windows.DWORD {
        if (std.mem.startsWith(u8, devid, "FTDI")) {
            // Should not be called on "FTDI" so just return the serial number.
            return try parseSerialNumber(devid, serial_number);
        } else if (std.mem.startsWith(u8, devid, "USB")) {
            // taken from pyserial
            const max_usb_device_tree_traversal_depth = 5;
            const start_vidpid = std.mem.indexOf(u8, devid, "VID") orelse return error.WindowsError;
            const vidpid_slice = devid[start_vidpid .. start_vidpid + 17]; // "VIDxxxx&PIDxxxx"

            // keep looping over parent device to extract serial number if it contains the target VID and PID.
            var depth: u8 = 0;
            var child_inst: DEVINST = devinst;
            while (depth <= max_usb_device_tree_traversal_depth) : (depth += 1) {
                var parent_id: DEVINST = undefined;
                var local_buffer: [256:0]u8 = std.mem.zeroes([256:0]u8);

                if (CM_Get_Parent(&parent_id, child_inst, 0) != 0) return error.WindowsError;
                if (CM_Get_Device_IDA(parent_id, @ptrCast(&local_buffer), 256, 0) != 0) return error.WindowsError;
                defer child_inst = parent_id;

                if (!std.mem.containsAtLeast(u8, local_buffer[0..255], 1, vidpid_slice)) continue;

                const length = try parseSerialNumber(local_buffer[0..255], serial_number);
                if (length > 0) return length;
            }
        }

        return error.WindowsError;
    }

    fn parseSerialNumber(devid: []const u8, serial_number: [*]u8) !std.os.windows.DWORD {
        var delimiter: ?[]const u8 = undefined;

        if (std.mem.startsWith(u8, devid, "USB")) {
            delimiter = "\\&";
        } else if (std.mem.startsWith(u8, devid, "FTDI")) {
            delimiter = "\\+";
        } else {
            // What to do here?
            delimiter = null;
        }

        if (delimiter) |del| {
            var it = std.mem.tokenize(u8, devid, del);

            // throw away the start
            _ = it.next();
            while (it.next()) |segment| {
                if (std.mem.startsWith(u8, segment, "VID_")) continue;
                if (std.mem.startsWith(u8, segment, "PID_")) continue;

                // If "MI_{d}{d}", this is an interface number. The serial number will have to be
                // sourced from the parent node. Probably do not have to check all these conditions.
                if (segment.len == 5 and std.mem.eql(u8, "MI_", segment[0..3]) and std.ascii.isDigit(segment[3]) and std.ascii.isDigit(segment[4])) return 0;

                @memcpy(serial_number, segment);
                return @as(std.os.windows.DWORD, @truncate(segment.len));
            }
        }

        return error.WindowsError;
    }

    fn parseVendorId(devid: []const u8) !u16 {
        var delimiter: ?[]const u8 = undefined;

        if (std.mem.startsWith(u8, devid, "USB")) {
            delimiter = "\\&";
        } else if (std.mem.startsWith(u8, devid, "FTDI")) {
            delimiter = "\\+";
        } else {
            delimiter = null;
        }

        if (delimiter) |del| {
            var it = std.mem.tokenize(u8, devid, del);

            while (it.next()) |segment| {
                if (std.mem.startsWith(u8, segment, "VID_")) {
                    return try std.fmt.parseInt(u16, segment[4..], 16);
                }
            }
        }

        return error.WindowsError;
    }

    fn parseProductId(devid: []const u8) !u16 {
        var delimiter: ?[]const u8 = undefined;

        if (std.mem.startsWith(u8, devid, "USB")) {
            delimiter = "\\&";
        } else if (std.mem.startsWith(u8, devid, "FTDI")) {
            delimiter = "\\+";
        } else {
            delimiter = null;
        }

        if (delimiter) |del| {
            var it = std.mem.tokenize(u8, devid, del);

            while (it.next()) |segment| {
                if (std.mem.startsWith(u8, segment, "PID_")) {
                    return try std.fmt.parseInt(u16, segment[4..], 16);
                }
            }
        }

        return error.WindowsError;
    }
};

extern "advapi32" fn RegOpenKeyExA(
    key: HKEY,
    lpSubKey: std.os.windows.LPCSTR,
    ulOptions: std.os.windows.DWORD,
    samDesired: std.os.windows.REGSAM,
    phkResult: *HKEY,
) callconv(std.os.windows.WINAPI) std.os.windows.LSTATUS;
extern "advapi32" fn RegCloseKey(key: HKEY) callconv(std.os.windows.WINAPI) std.os.windows.LSTATUS;
extern "advapi32" fn RegEnumValueA(
    hKey: HKEY,
    dwIndex: std.os.windows.DWORD,
    lpValueName: std.os.windows.LPSTR,
    lpcchValueName: *std.os.windows.DWORD,
    lpReserved: ?*std.os.windows.DWORD,
    lpType: ?*std.os.windows.DWORD,
    lpData: [*]std.os.windows.BYTE,
    lpcbData: *std.os.windows.DWORD,
) callconv(std.os.windows.WINAPI) std.os.windows.LSTATUS;
extern "setupapi" fn SetupDiGetClassDevsW(
    classGuid: ?*const std.os.windows.GUID,
    enumerator: ?std.os.windows.PCWSTR,
    hwndParanet: ?HWND,
    flags: std.os.windows.DWORD,
) callconv(std.os.windows.WINAPI) HDEVINFO;
extern "setupapi" fn SetupDiEnumDeviceInfo(
    devInfoSet: HDEVINFO,
    memberIndex: std.os.windows.DWORD,
    device_info_data: *SP_DEVINFO_DATA,
) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
extern "setupapi" fn SetupDiDestroyDeviceInfoList(device_info_set: HDEVINFO) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
extern "setupapi" fn SetupDiOpenDevRegKey(
    device_info_set: HDEVINFO,
    device_info_data: *SP_DEVINFO_DATA,
    scope: std.os.windows.DWORD,
    hwProfile: std.os.windows.DWORD,
    keyType: std.os.windows.DWORD,
    samDesired: std.os.windows.REGSAM,
) callconv(std.os.windows.WINAPI) HKEY;
extern "setupapi" fn SetupDiGetDeviceRegistryPropertyW(
    hDevInfo: HDEVINFO,
    pSpDevInfoData: *SP_DEVINFO_DATA,
    property: std.os.windows.DWORD,
    propertyRegDataType: ?*std.os.windows.DWORD,
    propertyBuffer: ?*std.os.windows.BYTE,
    propertyBufferSize: std.os.windows.DWORD,
    requiredSize: ?*std.os.windows.DWORD,
) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
extern "setupapi" fn SetupDiGetDeviceInstanceIdA(
    device_info_set: HDEVINFO,
    device_info_data: *SP_DEVINFO_DATA,
    deviceInstanceId: *?std.os.windows.CHAR,
    deviceInstanceIdSize: std.os.windows.DWORD,
    requiredSize: ?*std.os.windows.DWORD,
) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
extern "cfgmgr32" fn CM_Get_Parent(
    pdnDevInst: *DEVINST,
    dnDevInst: DEVINST,
    ulFlags: std.os.windows.ULONG,
) callconv(std.os.windows.WINAPI) std.os.windows.DWORD;
extern "cfgmgr32" fn CM_Get_Device_IDA(
    dnDevInst: DEVINST,
    buffer: std.os.windows.LPSTR,
    bufferLen: std.os.windows.ULONG,
    ulFlags: std.os.windows.ULONG,
) callconv(std.os.windows.WINAPI) std.os.windows.DWORD;

const LinuxPortIterator = struct {
    const Self = @This();

    const root_dir = "/sys/class/tty";

    // ls -hal /sys/class/tty/*/device/driver

    dir: std.fs.IterableDir,
    iterator: std.fs.IterableDir.Iterator,

    full_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined,
    driver_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined,

    pub fn init() !Self {
        var dir = try std.fs.cwd().openIterableDir(root_dir, .{});
        errdefer dir.close();

        return Self{
            .dir = dir,
            .iterator = dir.iterate(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.dir.close();
        self.* = undefined;
    }

    pub fn next(self: *Self) !?SerialPortDescription {
        while (true) {
            if (try self.iterator.next()) |entry| {
                // not a dir => we don't care
                var tty_dir = self.dir.dir.openDir(entry.name, .{}) catch continue;
                defer tty_dir.close();

                // we need the device dir
                // no device dir =>  virtual device
                var device_dir = tty_dir.openDir("device", .{}) catch continue;
                defer device_dir.close();

                // We need the symlink for "driver"
                const link = device_dir.readLink("driver", &self.driver_path_buffer) catch continue;

                // full_path_buffer
                // driver_path_buffer

                var fba = std.heap.FixedBufferAllocator.init(&self.full_path_buffer);

                const path = try std.fs.path.join(fba.allocator(), &.{
                    "/dev/",
                    entry.name,
                });

                return SerialPortDescription{
                    .file_name = path,
                    .display_name = path,
                    .driver = std.fs.path.basename(link),
                };
            } else {
                return null;
            }
        }
        return null;
    }
};

const DarwinPortIterator = struct {
    const Self = @This();

    const root_dir = "/dev/";

    dir: std.fs.IterableDir,
    iterator: std.fs.IterableDir.Iterator,

    full_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined,
    driver_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined,

    pub fn init() !Self {
        var dir = try std.fs.cwd().openIterableDir(root_dir, .{});
        errdefer dir.close();

        return Self{
            .dir = dir,
            .iterator = dir.iterate(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.dir.close();
        self.* = undefined;
    }

    pub fn next(self: *Self) !?SerialPortDescription {
        while (true) {
            if (try self.iterator.next()) |entry| {
                if (!std.mem.startsWith(u8, entry.name, "cu.")) {
                    continue;
                } else {
                    var fba = std.heap.FixedBufferAllocator.init(&self.full_path_buffer);

                    const path = try std.fs.path.join(fba.allocator(), &.{
                        "/dev/",
                        entry.name,
                    });

                    return SerialPortDescription{
                        .file_name = path,
                        .display_name = path,
                        .driver = "darwin",
                    };
                }
            } else {
                return null;
            }
        }
        return null;
    }
};

pub const Parity = enum {
    /// No parity bit is used
    none,
    /// Parity bit is `0` when an even number of bits is set in the data.
    even,
    /// Parity bit is `0` when an odd number of bits is set in the data.
    odd,
    /// Parity bit is always `1`
    mark,
    /// Parity bit is always `0`
    space,
};

pub const StopBits = enum {
    /// The length of the stop bit is 1 bit
    one,
    /// The length of the stop bit is 2 bits
    two,
};

pub const Handshake = enum {
    /// No handshake is used
    none,
    /// XON-XOFF software handshake is used.
    software,
    /// Hardware handshake with RTS/CTS is used.
    hardware,
};

pub const SerialConfig = struct {
    /// Symbol rate in bits/second. Not that these
    /// include also parity and stop bits.
    baud_rate: u32,

    /// Parity to verify transport integrity.
    parity: Parity = .none,

    /// Number of stop bits after the data
    stop_bits: StopBits = .one,

    /// Number of data bits per word.
    /// Allowed values are 5, 6, 7, 8
    word_size: u4 = 8,

    /// Defines the handshake protocol used.
    handshake: Handshake = .none,

    /// How many characters to wait for before
    /// returning from read calls.
    character_minimum: u8 = 1,

    /// In deci-seconds, length of time to wait
    /// for before returning from read call. A value of
    /// zero indicates no timeout.
    character_timeout: u8 = 0,
};

const CBAUD = 0o000000010017; //Baud speed mask (not in POSIX).
const CMSPAR = 0o010000000000;
const CRTSCTS = 0o020000000000;

const VTIME = 5;
const VMIN = 6;
const VSTART = 8;
const VSTOP = 9;

/// This function configures a serial port with the given config.
/// `port` is an already opened serial port, on windows these
/// are either called `\\.\COMxx\` or `COMx`, on unixes the serial
/// port is called `/dev/ttyXXX`.
pub fn configureSerialPort(port: std.os.fd_t, config: SerialConfig) !void {
    switch (builtin.os.tag) {
        .windows => {
            var dcb = std.mem.zeroes(DCB);
            dcb.DCBlength = @sizeOf(DCB);

            if (GetCommState(port, &dcb) == 0)
                return error.WindowsError;

            var flags = DCBFlags.fromNumeric(dcb.flags);

            // std.log.err("{s} {s}", .{ dcb, flags });

            dcb.BaudRate = config.baud_rate;

            flags.fBinary = 1;
            flags.fParity = if (config.parity != .none) @as(u1, 1) else @as(u1, 0);
            flags.fOutxCtsFlow = if (config.handshake == .hardware) @as(u1, 1) else @as(u1, 0);
            flags.fOutxDsrFlow = 0;
            flags.fDtrControl = 0;
            flags.fDsrSensitivity = 0;
            flags.fTXContinueOnXoff = 0;
            flags.fOutX = if (config.handshake == .software) @as(u1, 1) else @as(u1, 0);
            flags.fInX = if (config.handshake == .software) @as(u1, 1) else @as(u1, 0);
            flags.fErrorChar = 0;
            flags.fNull = 0;
            flags.fRtsControl = if (config.handshake == .hardware) @as(u1, 1) else @as(u1, 0);
            flags.fAbortOnError = 0;
            dcb.flags = flags.toNumeric();

            dcb.wReserved = 0;
            dcb.ByteSize = config.word_size;
            dcb.Parity = switch (config.parity) {
                .none => @as(u8, 0),
                .even => @as(u8, 2),
                .odd => @as(u8, 1),
                .mark => @as(u8, 3),
                .space => @as(u8, 4),
            };
            dcb.StopBits = switch (config.stop_bits) {
                .one => @as(u2, 0),
                .two => @as(u2, 2),
            };
            dcb.XonChar = 0x11;
            dcb.XoffChar = 0x13;
            dcb.wReserved1 = 0;

            if (SetCommState(port, &dcb) == 0)
                return error.WindowsError;

            var cto = std.mem.zeroes(COMMTIMEOUTS);
            if (GetCommTimeouts(port, &cto) == 0)
                return error.WindowsError;

            // Set timeout between chars to character_timeout converted to milliseconds
            cto.ReadIntervalTimeout = @as(u32, @intCast(config.character_timeout)) * 100;
            // Disable timeout for total length
            cto.ReadTotalTimeoutConstant = 0;
            cto.ReadTotalTimeoutMultiplier = 0;

            if (SetCommTimeouts(port, &cto) == 0)
                return error.WindowsError;
        },
        .linux, .macos => |tag| {
            var settings = try std.os.tcgetattr(port);

            const os = switch (tag) {
                .macos => std.os.darwin,
                .linux => std.os.linux,
                else => unreachable,
            };

            settings.iflag = 0;
            settings.oflag = 0;
            settings.cflag = os.CREAD;
            settings.lflag = 0;
            settings.ispeed = 0;
            settings.ospeed = 0;

            switch (config.parity) {
                .none => {},
                .odd => settings.cflag |= os.PARODD,
                .even => {}, // even parity is default when parity is enabled
                .mark => settings.cflag |= os.PARODD | CMSPAR,
                .space => settings.cflag |= CMSPAR,
            }
            if (config.parity != .none) {
                settings.iflag |= os.INPCK; // enable parity checking
                settings.cflag |= os.PARENB; // enable parity generation
            }

            switch (config.handshake) {
                .none => settings.cflag |= os.CLOCAL,
                .software => settings.iflag |= os.IXON | os.IXOFF,
                .hardware => settings.cflag |= CRTSCTS,
            }

            switch (config.stop_bits) {
                .one => {},
                .two => settings.cflag |= os.CSTOPB,
            }

            switch (config.word_size) {
                5 => settings.cflag |= os.CS5,
                6 => settings.cflag |= os.CS6,
                7 => settings.cflag |= os.CS7,
                8 => settings.cflag |= os.CS8,
                else => return error.UnsupportedWordSize,
            }

            const baudmask = switch (tag) {
                .macos => try mapBaudToMacOSEnum(config.baud_rate),
                .linux => try mapBaudToLinuxEnum(config.baud_rate),
                else => unreachable,
            };

            settings.cflag &= ~@as(os.tcflag_t, CBAUD);
            settings.cflag |= baudmask;
            settings.ispeed = baudmask;
            settings.ospeed = baudmask;

            settings.cc[VMIN] = config.character_minimum;
            settings.cc[VSTOP] = 0x13; // XOFF
            settings.cc[VSTART] = 0x11; // XON
            settings.cc[VTIME] = config.character_timeout;

            try std.os.tcsetattr(port, .NOW, settings);
        },
        else => @compileError("unsupported OS, please implement!"),
    }
}

/// Flushes the serial port `port`. If `input` is set, all pending data in
/// the receive buffer is flushed, if `output` is set all pending data in
/// the send buffer is flushed.
pub fn flushSerialPort(port: std.fs.File, input: bool, output: bool) !void {
    if (!input and !output)
        return;

    switch (builtin.os.tag) {
        .windows => {
            const success = if (input and output)
                PurgeComm(port.handle, PURGE_TXCLEAR | PURGE_RXCLEAR)
            else if (input)
                PurgeComm(port.handle, PURGE_RXCLEAR)
            else if (output)
                PurgeComm(port.handle, PURGE_TXCLEAR)
            else
                @as(std.os.windows.BOOL, 0);
            if (success == 0)
                return error.FlushError;
        },

        .linux => if (input and output)
            try tcflush(port.handle, TCIOFLUSH)
        else if (input)
            try tcflush(port.handle, TCIFLUSH)
        else if (output)
            try tcflush(port.handle, TCOFLUSH),

        .macos => if (input and output)
            try tcflush(port.handle, c.TCIOFLUSH)
        else if (input)
            try tcflush(port.handle, c.TCIFLUSH)
        else if (output)
            try tcflush(port.handle, c.TCOFLUSH),

        else => @compileError("unsupported OS, please implement!"),
    }
}

pub const ControlPins = struct {
    rts: ?bool = null,
    dtr: ?bool = null,
};

pub fn changeControlPins(port: std.fs.File, pins: ControlPins) !void {
    switch (builtin.os.tag) {
        .windows => {
            const CLRDTR = 6;
            const CLRRTS = 4;
            const SETDTR = 5;
            const SETRTS = 3;

            if (pins.dtr) |dtr| {
                if (EscapeCommFunction(port.handle, if (dtr) SETDTR else CLRDTR) == 0)
                    return error.WindowsError;
            }
            if (pins.rts) |rts| {
                if (EscapeCommFunction(port.handle, if (rts) SETRTS else CLRRTS) == 0)
                    return error.WindowsError;
            }
        },
        .linux => {
            const TIOCM_RTS: c_int = 0x004;
            const TIOCM_DTR: c_int = 0x002;

            // from /usr/include/asm-generic/ioctls.h
            // const TIOCMBIS: u32 = 0x5416;
            // const TIOCMBIC: u32 = 0x5417;
            const TIOCMGET: u32 = 0x5415;
            const TIOCMSET: u32 = 0x5418;

            var flags: c_int = 0;
            if (std.os.linux.ioctl(port.handle, TIOCMGET, @intFromPtr(&flags)) != 0)
                return error.Unexpected;

            if (pins.dtr) |dtr| {
                if (dtr) {
                    flags |= TIOCM_DTR;
                } else {
                    flags &= ~TIOCM_DTR;
                }
            }
            if (pins.rts) |rts| {
                if (rts) {
                    flags |= TIOCM_RTS;
                } else {
                    flags &= ~TIOCM_RTS;
                }
            }

            if (std.os.linux.ioctl(port.handle, TIOCMSET, @intFromPtr(&flags)) != 0)
                return error.Unexpected;
        },

        .macos => {},

        else => @compileError("changeControlPins not implemented for " ++ @tagName(builtin.os.tag)),
    }
}

const PURGE_RXABORT = 0x0002;
const PURGE_RXCLEAR = 0x0008;
const PURGE_TXABORT = 0x0001;
const PURGE_TXCLEAR = 0x0004;

extern "kernel32" fn PurgeComm(hFile: std.os.windows.HANDLE, dwFlags: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
extern "kernel32" fn EscapeCommFunction(hFile: std.os.windows.HANDLE, dwFunc: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;

const TCIFLUSH = 0;
const TCOFLUSH = 1;
const TCIOFLUSH = 2;
const TCFLSH = 0x540B;

fn tcflush(fd: std.os.fd_t, mode: usize) !void {
    switch (builtin.os.tag) {
        .linux => {
            if (std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, fd))), TCFLSH, mode) != 0)
                return error.FlushError;
        },
        .macos => {
            const err = c.tcflush(fd, @as(c_int, @intCast(mode)));
            if (err != 0) {
                std.debug.print("tcflush failed: {d}\r\n", .{err});
                return error.FlushError;
            }
        },
        else => @compileError("unsupported OS, please implement!"),
    }
}

fn mapBaudToLinuxEnum(baudrate: usize) !std.os.linux.speed_t {
    return switch (baudrate) {
        // from termios.h
        50 => std.os.linux.B50,
        75 => std.os.linux.B75,
        110 => std.os.linux.B110,
        134 => std.os.linux.B134,
        150 => std.os.linux.B150,
        200 => std.os.linux.B200,
        300 => std.os.linux.B300,
        600 => std.os.linux.B600,
        1200 => std.os.linux.B1200,
        1800 => std.os.linux.B1800,
        2400 => std.os.linux.B2400,
        4800 => std.os.linux.B4800,
        9600 => std.os.linux.B9600,
        19200 => std.os.linux.B19200,
        38400 => std.os.linux.B38400,
        // from termios-baud.h
        57600 => std.os.linux.B57600,
        115200 => std.os.linux.B115200,
        230400 => std.os.linux.B230400,
        460800 => std.os.linux.B460800,
        500000 => std.os.linux.B500000,
        576000 => std.os.linux.B576000,
        921600 => std.os.linux.B921600,
        1000000 => std.os.linux.B1000000,
        1152000 => std.os.linux.B1152000,
        1500000 => std.os.linux.B1500000,
        2000000 => std.os.linux.B2000000,
        2500000 => std.os.linux.B2500000,
        3000000 => std.os.linux.B3000000,
        3500000 => std.os.linux.B3500000,
        4000000 => std.os.linux.B4000000,
        else => error.UnsupportedBaudRate,
    };
}

fn mapBaudToMacOSEnum(baudrate: usize) !std.os.darwin.speed_t {
    return switch (baudrate) {
        // from termios.h
        50 => std.os.darwin.B50,
        75 => std.os.darwin.B75,
        110 => std.os.darwin.B110,
        134 => std.os.darwin.B134,
        150 => std.os.darwin.B150,
        200 => std.os.darwin.B200,
        300 => std.os.darwin.B300,
        600 => std.os.darwin.B600,
        1200 => std.os.darwin.B1200,
        1800 => std.os.darwin.B1800,
        2400 => std.os.darwin.B2400,
        4800 => std.os.darwin.B4800,
        9600 => std.os.darwin.B9600,
        19200 => std.os.darwin.B19200,
        38400 => std.os.darwin.B38400,
        7200 => std.os.darwin.B7200,
        14400 => std.os.darwin.B14400,
        28800 => std.os.darwin.B28800,
        57600 => std.os.darwin.B57600,
        76800 => std.os.darwin.B76800,
        115200 => std.os.darwin.B115200,
        230400 => std.os.darwin.B230400,
        else => error.UnsupportedBaudRate,
    };
}

const DCBFlags = struct {
    fBinary: u1, // u1
    fParity: u1, // u1
    fOutxCtsFlow: u1, // u1
    fOutxDsrFlow: u1, // u1
    fDtrControl: u2, // u2
    fDsrSensitivity: u1, // u1
    fTXContinueOnXoff: u1, // u1
    fOutX: u1, // u1
    fInX: u1, // u1
    fErrorChar: u1, // u1
    fNull: u1, // u1
    fRtsControl: u2, // u2
    fAbortOnError: u1, // u1
    fDummy2: u17 = 0, // u17

    // TODO: Packed structs please
    pub fn fromNumeric(value: u32) DCBFlags {
        var flags: DCBFlags = undefined;
        flags.fBinary = @as(u1, @truncate(value >> 0)); // u1
        flags.fParity = @as(u1, @truncate(value >> 1)); // u1
        flags.fOutxCtsFlow = @as(u1, @truncate(value >> 2)); // u1
        flags.fOutxDsrFlow = @as(u1, @truncate(value >> 3)); // u1
        flags.fDtrControl = @as(u2, @truncate(value >> 4)); // u2
        flags.fDsrSensitivity = @as(u1, @truncate(value >> 6)); // u1
        flags.fTXContinueOnXoff = @as(u1, @truncate(value >> 7)); // u1
        flags.fOutX = @as(u1, @truncate(value >> 8)); // u1
        flags.fInX = @as(u1, @truncate(value >> 9)); // u1
        flags.fErrorChar = @as(u1, @truncate(value >> 10)); // u1
        flags.fNull = @as(u1, @truncate(value >> 11)); // u1
        flags.fRtsControl = @as(u2, @truncate(value >> 12)); // u2
        flags.fAbortOnError = @as(u1, @truncate(value >> 14)); // u1
        flags.fDummy2 = @as(u17, @truncate(value >> 15)); // u17
        return flags;
    }

    pub fn toNumeric(self: DCBFlags) u32 {
        var value: u32 = 0;
        value += @as(u32, self.fBinary) << 0; // u1
        value += @as(u32, self.fParity) << 1; // u1
        value += @as(u32, self.fOutxCtsFlow) << 2; // u1
        value += @as(u32, self.fOutxDsrFlow) << 3; // u1
        value += @as(u32, self.fDtrControl) << 4; // u2
        value += @as(u32, self.fDsrSensitivity) << 6; // u1
        value += @as(u32, self.fTXContinueOnXoff) << 7; // u1
        value += @as(u32, self.fOutX) << 8; // u1
        value += @as(u32, self.fInX) << 9; // u1
        value += @as(u32, self.fErrorChar) << 10; // u1
        value += @as(u32, self.fNull) << 11; // u1
        value += @as(u32, self.fRtsControl) << 12; // u2
        value += @as(u32, self.fAbortOnError) << 14; // u1
        value += @as(u32, self.fDummy2) << 15; // u17
        return value;
    }
};

test "DCBFlags" {
    var rand: u32 = 0;
    try std.os.getrandom(@as(*[4]u8, @ptrCast(&rand)));
    var flags = DCBFlags.fromNumeric(rand);
    try std.testing.expectEqual(rand, flags.toNumeric());
}

const DCB = extern struct {
    DCBlength: std.os.windows.DWORD,
    BaudRate: std.os.windows.DWORD,
    flags: u32,
    wReserved: std.os.windows.WORD,
    XonLim: std.os.windows.WORD,
    XoffLim: std.os.windows.WORD,
    ByteSize: std.os.windows.BYTE,
    Parity: std.os.windows.BYTE,
    StopBits: std.os.windows.BYTE,
    XonChar: u8,
    XoffChar: u8,
    ErrorChar: u8,
    EofChar: u8,
    EvtChar: u8,
    wReserved1: std.os.windows.WORD,
};

const COMMTIMEOUTS = extern struct {
    ReadIntervalTimeout: std.os.windows.DWORD,
    ReadTotalTimeoutMultiplier: std.os.windows.DWORD,
    ReadTotalTimeoutConstant: std.os.windows.DWORD,
    WriteTotalTimeoutMultiplier: std.os.windows.DWORD,
    WriteTotalTimeoutConstant: std.os.windows.DWORD,
};

extern "kernel32" fn GetCommState(hFile: std.os.windows.HANDLE, lpDCB: *DCB) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
extern "kernel32" fn SetCommState(hFile: std.os.windows.HANDLE, lpDCB: *DCB) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
extern "kernel32" fn GetCommTimeouts(hFile: std.os.windows.HANDLE, lpCTO: *COMMTIMEOUTS) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
extern "kernel32" fn SetCommTimeouts(hFile: std.os.windows.HANDLE, lpCTO: *COMMTIMEOUTS) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;

const COMSTAT = extern struct {
    flags: packed struct(std.os.windows.DWORD) {
        /// If this member is TRUE, transmission is waiting for the CTS (clear-to-send) signal to be sent.
        clearToSendHold: bool,
        /// If this member is TRUE, transmission is waiting for the DSR (data-set-ready) signal to be sent.
        dataSetReadyHold: bool,
        /// If this member is TRUE, transmission is waiting for the RLSD (receive-line-signal-detect) signal to be sent.
        receiveLineSignalDetectHold: bool,

        /// If this member is TRUE, transmission is waiting because the XOFF character was received.
        xoffHold: bool,

        /// If this member is TRUE, transmission is waiting because the XOFF character was transmitted.
        /// (Transmission halts when the XOFF character is transmitted to a system that takes the next
        /// character as XON, regardless of the actual character.)
        xoffSent: bool,

        /// If this member is TRUE, the end-of-file (EOF) character has been received.
        fEof: bool,

        /// If this member is TRUE, there is a character queued for transmission that has come to the
        /// communications device by way of the TransmitCommChar function. The communications device
        /// transmits such a character ahead of other characters in the device's output buffer.
        txim: bool,

        /// Reserved, do not use.
        _reserved: u25 = undefined,
    },

    /// The number of bytes received by the serial provider but not yet read by a ReadFile operation.
    bytesInInputBuffer: std.os.windows.DWORD,

    /// The number of bytes of user data remaining to be transmitted for all write operations. This value will be zero for a nonoverlapped write.
    bytesInOutputBuffer: std.os.windows.DWORD,
};

extern "kernel32" fn ClearCommError(hFile: std.os.windows.HANDLE, lpErrors: ?*std.os.windows.DWORD, lpStat: ?*COMSTAT) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;

/// Implements non-blocking IO for serial ports
/// Uses OS-native APIs to create a file handle with non-blocking reads and writes.
/// Provides a low-level polling API which can be used as a building block in asynchronous/event-driven APIs.
pub const SerialPort = struct {
    handle: std.os.fd_t,

    /// Open the given serial port with the passed configuration
    pub fn open(port_name: []const u8, config: SerialConfig) !SerialPort {
        const handle = handle: {
            switch (builtin.os.tag) {
                .windows => {
                    var buffer: [1024]u8 = undefined;
                    var fba = std.heap.FixedBufferAllocator.init(&buffer);
                    const port_name_utf16 = try std.unicode.utf8ToUtf16LeWithNull(fba.allocator(), port_name);
                    std.debug.assert(std.fs.path.isAbsoluteWindowsWTF16(port_name_utf16));

                    // file handle will be stored here
                    var handle: std.os.windows.HANDLE = undefined;
                    const path_len_bytes = std.math.cast(u16, port_name_utf16.len * 2) orelse return error.WindowsError;
                    var nt_name = std.os.windows.UNICODE_STRING{
                        .Length = path_len_bytes,
                        .MaximumLength = path_len_bytes,
                        .Buffer = @constCast(port_name_utf16.ptr),
                    };

                    var attr = std.os.windows.OBJECT_ATTRIBUTES{
                        .Length = @sizeOf(std.os.windows.OBJECT_ATTRIBUTES),
                        .RootDirectory = null,
                        .Attributes = 0,
                        .ObjectName = &nt_name,
                        .SecurityDescriptor = null,
                        .SecurityQualityOfService = null,
                    };

                    var io: std.os.windows.IO_STATUS_BLOCK = undefined;

                    const rc = std.os.windows.ntdll.NtCreateFile(
                        &handle, // FileHandle
                        std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE, // DesiredAccess
                        &attr,
                        &io,
                        null, // allocation size
                        std.os.windows.FILE_ATTRIBUTE_NORMAL,
                        0, // Share access - 0 for exclusive access
                        std.os.windows.OPEN_EXISTING,
                        0, // Create options
                        null,
                        0,
                    );
                    switch (rc) {
                        .SUCCESS => {
                            try configureSerialPort(handle, config);
                            break :handle handle;
                        },
                        else => return error.WindowsError,
                    }
                },
                .linux, .macos => {
                    // Examples say to use either NONBLOCK or NDELAY they have the same value
                    const result: std.os.fd_t = try std.os.open(port_name, std.os.linux.O.NONBLOCK, std.os.linux.O.RDWR);
                    try configureSerialPort(result, config);
                    break :handle result;
                },
                else => @compileError("unsupported OS, please implement!"),
            }
        };
        return .{
            .handle = handle,
        };
    }

    /// Close the serial port
    pub fn close(port: SerialPort) void {
        switch (builtin.os.tag) {
            .windows => {
                std.os.windows.CloseHandle(port.handle);
            },
            .linux => {
                std.os.linux.close(port.handle);
            },
            else => @compileError("unsupported OS, please implement!"),
        }
    }

    /// Gets the number of bytes waiting in the input buffer in a non-blocking way.
    pub fn getBytesAvailable(port: SerialPort) !usize {
        switch (builtin.os.tag) {
            .windows => {
                var comstat: COMSTAT = undefined;
                const success = ClearCommError(port.handle, null, &comstat);
                if (success == 0) {
                    // TODO: Use GetLastError to get more info
                    return error.GetStatusError;
                }
                return comstat.bytesInOutputBuffer;
            },

            .linux => {
                var number_of_unread_bytes: c_int = undefined;

                const err = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, port.handle))), TIOCINQ, @intFromPtr(&number_of_unread_bytes));
                if (err != 0) {
                    std.debug.print("ioctl TIOCINQ failed: {d}\r\n", .{err});
                    return error.GetStatusError;
                }

                return @intCast(number_of_unread_bytes);
            },

            .macos => {
                var number_of_unread_bytes: c_int = undefined;

                const err = std.c.ioctl(port.handle, TIOCINQ, &number_of_unread_bytes);
                if (err != 0) {
                    std.debug.print("ioctl TIOCINQ failed: {d}\r\n", .{err});
                    return error.GetStatusError;
                }

                return @intCast(number_of_unread_bytes);
            },
            else => @compileError("unsupported OS, please implement!"),
        }
    }

    /// Reads bytes from the serial port into the passed buffer and returns a slice of the written bytes.
    pub fn read(port: SerialPort, buffer: []u8) ![]u8 {
        switch (builtin.os.tag) {
            .windows => {
                var bytes_read: std.os.windows.DWORD = 0;
                if (std.os.windows.kernel32.ReadFile(port.handle, buffer.ptr, @intCast(buffer.len), &bytes_read, null) == 0)
                    return error.WindowsError;
                return buffer[0..bytes_read];
            },
            .linux => {
                const bytes_read = std.os.linux.read(port.handle, buffer.ptr, buffer.len);
                return buffer[0..bytes_read];
            },
            else => @compileError("unsupported OS, please implement!"),
        }
    }

    /// Writes bytes from the passed buffer to the serial port, returns the number of bytes written.
    /// If the number of bytes written is less than the length of the buffer, then the message did not finish sending.
    pub fn write(port: SerialPort, buffer: []const u8) !usize {
        switch (builtin.os.tag) {
            .windows => {
                var bytes_written: std.os.windows.DWORD = 0;
                if (std.os.windows.kernel32.WriteFile(port.handle, buffer.ptr, @intCast(buffer.len), &bytes_written, null) == 0)
                    return error.WindowsError;
                return bytes_written;
            },
            .linux => {
                const bytes_written = std.os.linux.write(port.handle, buffer.ptr, buffer.len);
                return bytes_written;
            },
            else => @compileError("unsupported OS, please implement!"),
        }
    }
};

const FIONREAD = 0x541B;
const TIOCINQ = FIONREAD;

test "iterate ports" {
    var it = try list();
    while (try it.next()) |port| {
        _ = port;
        // std.debug.print("{s} (file: {s}, driver: {s})\n", .{ port.display_name, port.file_name, port.driver });
    }
}

test "basic configuration test" {
    var cfg = SerialConfig{
        .handshake = .none,
        .baud_rate = 115200,
        .parity = .none,
        .word_size = 8,
        .stop_bits = .one,
    };

    var tty: []const u8 = undefined;

    switch (builtin.os.tag) {
        .windows => tty = "\\\\.\\COM3",
        .linux => tty = "/dev/ttyUSB0",
        .macos => tty = "/dev/cu.usbmodem101",
        else => unreachable,
    }

    var port = try std.fs.cwd().openFile(tty, .{ .mode = .read_write });
    defer port.close();

    try configureSerialPort(port.handle, cfg);
}

test "basic flush test" {
    var tty: []const u8 = undefined;
    // if any, these will likely exist on a machine
    switch (builtin.os.tag) {
        .windows => tty = "\\\\.\\COM3",
        .linux => tty = "/dev/ttyUSB0",
        .macos => tty = "/dev/cu.usbmodem101",
        else => unreachable,
    }
    var port = try std.fs.cwd().openFile(tty, .{ .mode = .read_write });
    defer port.close();

    try flushSerialPort(port, true, true);
    try flushSerialPort(port, true, false);
    try flushSerialPort(port, false, true);
    try flushSerialPort(port, false, false);
}

test "change control pins" {
    _ = changeControlPins;
}
