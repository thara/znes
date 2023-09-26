const std = @import("std");

pub const CpuStatus = std.StaticBitSet(8);

pub const Cpu = struct {
    a: u8,
    x: u8,
    y: u8,
    s: u8,
    p: CpuStatus,
    pc: u16,
    cycles: u64,
};

pub const Nes = struct {
    cpu: Cpu,
};
