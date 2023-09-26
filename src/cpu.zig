const types = @import("types.zig");
const decoder = @import("cpu_decoder.zig");

pub fn CpuEmu(
    comptime readFn: fn (nes: *types.Nes, addr: u16) u8,
    comptime writeFn: fn (nes: *types.Nes, addr: u16, value: u8) noreturn,
    comptime tickFn: fn (nes: *types.Nes) noreturn,
) type {
    return struct {
        pub fn power_on(nes: *types.Nes) noreturn {
            // https://wiki.nesdev.com/w/index.php/CPU_power_up_state

            // IRQ disabled
            nes.cpu.p.setValue(0x34);
            nes.cpu.a = 0x00;
            nes.cpu.x = 0x00;
            nes.cpu.y = 0x00;
            nes.cpu.s = 0x00;

            // frame irq disabled
            write(nes, 0x4017, 0x00);
            // all channels disabled
            write(nes, 0x4015, 0x00);
        }

        pub fn step(nes: *types.Nes) noreturn {
            var op = fetch(nes);
            var inst = decoder.decode(op);
            execute(nes, &inst);
        }

        fn fetch(nes: *types.Nes) u16 {
            var op = read(nes, nes.cpu.pc);
            nes.cpu.pc += 1;
            return op;
        }

        fn read(nes: *types.Nes, addr: u16) u8 {
            var value = readFn(nes, addr);
            tick();
            return value;
        }

        fn readWord(nes: *types.Nes, addr: u16) u16 {
            return @as(u16, read(nes, addr)) | @as(u16, read(nes, addr + 1)) << 8;
        }

        fn readOnIndirect(nes: *types.Nes, addr: u16) u16 {
            var low: u16 = @intCast(read(nes, addr));
            // Reproduce 6502 bug - http://nesdev.com/6502bugs.txt
            var high: u16 = @intCast(read(nes, (addr & 0xFF00) | ((addr + 1) & 0x00FF)));
            return low | (high << 8);
        }

        fn write(nes: *types.Nes, addr: u16, value: u8) noreturn {
            writeFn(nes, addr, value);
            tick();
        }

        fn tick(nes: *types.Nes) noreturn {
            nes.cpu.cycles += 1;
            tickFn(nes);
        }

        fn execute(nes: *types.Nes, inst: *decoder.Instruction) noreturn {
            get_operand(nes, inst.AddressingMode);
        }

        fn get_operand(nes: *types.Nes, addressingMode: decoder.AddressingMode) u16 {
            return switch (addressingMode) {
                decoder.AddressingMode.implicit => 0,
                decoder.AddressingMode.accumulator => @intCast(nes.cpu.a),
                decoder.AddressingMode.immediate => blk: {
                    var pc = nes.cpu.pc;
                    nes.cpu.pc += 1;
                    break :blk pc;
                },
                decoder.AddressingMode.zeroPage => blk: {
                    var v = read(nes, nes.cpu.pc);
                    nes.cpu.pc += 1;
                    break :blk @intCast(v);
                },
                decoder.AddressingMode.zeroPageX => blk: {
                    tick(nes);
                    var v: u16 = (@as(u16, read(nes, nes.cpu.pc)) + @as(u16, read(nes, nes.cpu.x))) & 0xFF;
                    nes.cpu.pc += 1;
                    break :blk @intCast(v);
                },
                decoder.AddressingMode.zeroPageY => blk: {
                    tick(nes);
                    var v: u16 = (@as(u16, read(nes, nes.cpu.pc)) + @as(u16, read(nes, nes.cpu.y))) & 0xFF;
                    nes.cpu.pc += 1;
                    break :blk @intCast(v);
                },
                decoder.AddressingMode.absolute => blk: {
                    var v = readWord(nes, nes.cpu.pc);
                    nes.cpu.pc += 2;
                    break :blk v;
                },
                decoder.AddressingMode.absoluteX => blk: {
                    var v = readWord(nes, nes.cpu.pc);
                    nes.cpu.pc += 2;
                    tick(nes);
                    break :blk v + @as(u16, nes.cpu.x);
                },
                decoder.AddressingMode.absoluteXWithPenalty => blk: {
                    var v = readWord(nes, nes.cpu.pc);
                    nes.cpu.pc += 2;
                    if (pageCrossed(@as(u16, nes.cpu.x), v)) {
                        tick(nes);
                    }
                    break :blk v + @as(u16, nes.cpu.x);
                },
                decoder.AddressingMode.absoluteY => blk: {
                    var v = readWord(nes, nes.cpu.pc);
                    nes.cpu.pc += 2;
                    tick(nes);
                    break :blk v + @as(u16, nes.cpu.y);
                },
                decoder.AddressingMode.absoluteYWithPenalty => blk: {
                    var v = readWord(nes, nes.cpu.pc);
                    nes.cpu.pc += 2;
                    if (pageCrossed(@as(u16, nes.cpu.y), v)) {
                        tick(nes);
                    }
                    break :blk v + @as(u16, nes.cpu.y);
                },
                decoder.AddressingMode.relative => blk: {
                    var v = read(nes, nes.cpu.pc);
                    nes.cpu.pc += 1;
                    break :blk @intCast(v);
                },
                decoder.AddressingMode.indirect => blk: {
                    var m = readWord(nes, nes.cpu.pc);
                    var v = readOnIndirect(m);
                    nes.cpu.pc += 2;
                    break :blk v;
                },
                decoder.AddressingMode.indexedIndirect => blk: {
                    var m = read(nes, nes.cpu.pc);
                    var v = readOnIndirect(nes, @intCast(m + nes.cpu.x));
                    nes.cpu.pc += 1;
                    tick(nes);
                    break :blk v;
                },
                decoder.AddressingMode.indirectIndexed => blk: {
                    var m = read(nes, nes.cpu.pc);
                    var v = readOnIndirect(nes, @intCast(m));
                    nes.cpu.pc += 1;
                    tick(nes);
                    break :blk v + @as(u16, nes.cpu.y);
                },
                decoder.AddressingMode.indirectIndexedWithPenalty => blk: {
                    var m = read(nes, nes.cpu.pc);
                    var v = readOnIndirect(nes, @intCast(m));
                    nes.cpu.pc += 1;
                    if (pageCrossed(@as(u16, nes.cpu.y), v)) {
                        tick(nes);
                    }
                    break :blk v + @as(u16, nes.cpu.y);
                },
            };
        }
    };
}

fn pageCrossed(a: anytype, b: anytype) bool {
    var p = 0xFF00;
    return (a + b) & p != (b & p);
}
