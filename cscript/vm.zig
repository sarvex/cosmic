const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const cs = @import("cscript.zig");
const Value = cs.Value;
const debug = builtin.mode == .Debug;

const log = stdx.log.scoped(.vm);

pub const VM = struct {
    alloc: std.mem.Allocator,
    parser: cs.Parser,
    compiler: cs.VMcompiler,

    /// [Eval context]

    /// Program counter. Index to the next instruction op in `ops`.
    pc: usize,
    /// Current stack frame ptr. Previous stack frame info is saved as a Value after all the reserved locals.
    framePtr: usize,
    contFlag: bool,

    ops: []const OpData,
    consts: []const Const,
    strBuf: []const u8,

    /// Value stack.
    stack: stdx.Stack(Value),

    /// Symbol table used to lookup object fields and methods.
    /// First, the SymbolId indexes into the table for a SymbolMap to lookup the final SymbolEntry by StructId.
    symbols: std.ArrayListUnmanaged(SymbolMap),

    /// Used to track which symbols already exist. Only considers the name right now.
    symSignatures: std.StringHashMapUnmanaged(SymbolId),

    /// Regular function symbol table.
    funcSyms: std.ArrayListUnmanaged(FuncSymbolEntry),
    funcSymSignatures: std.StringHashMapUnmanaged(SymbolId),

    /// Structs.
    structs: std.ArrayListUnmanaged(Struct),
    listS: StructId,
    iteratorObjSym: SymbolId,
    nextObjSym: SymbolId,

    panicMsg: []const u8,

    opCounts: []OpCount,

    pub fn init(self: *VM, alloc: std.mem.Allocator) !void {
        self.* = .{
            .alloc = alloc,
            .parser = cs.Parser.init(alloc),
            .compiler = undefined,
            .ops = undefined,
            .consts = undefined,
            .strBuf = undefined,
            .stack = .{},
            .pc = 0,
            .framePtr = 0,
            .contFlag = false,
            .symbols = .{},
            .symSignatures = .{},
            .funcSyms = .{},
            .funcSymSignatures = .{},
            .structs = .{},
            .listS = undefined,
            .iteratorObjSym = undefined,
            .nextObjSym = undefined,
            .opCounts = undefined,
            .panicMsg = "",
        };
        self.compiler.init(self);
        try self.stack.ensureTotalCapacity(self.alloc, 100);

        // Init compile time builtins.
        const resize = try self.ensureStructSym("resize");
        self.listS = try self.addStruct("List");
        try self.addStructSym(self.listS, resize, SymbolEntry.initNativeFunc1(nativeListResize));
        self.iteratorObjSym = try self.ensureStructSym("iterator");
        try self.addStructSym(self.listS, self.iteratorObjSym, SymbolEntry.initNativeFunc1(nativeListIterator));
        self.nextObjSym = try self.ensureStructSym("next");
        try self.addStructSym(self.listS, self.nextObjSym, SymbolEntry.initNativeFunc1(nativeListNext));
        const add = try self.ensureStructSym("add");
        try self.addStructSym(self.listS, add, SymbolEntry.initNativeFunc1(nativeListAdd));
    }

    pub fn deinit(self: *VM) void {
        self.parser.deinit();
        self.compiler.deinit();
        self.stack.deinit(self.alloc);

        for (self.symbols.items) |*map| {
            if (map.mapT == .manyStructs) {
                map.inner.manyStructs.deinit(self.alloc);
            }
        }
        self.symbols.deinit(self.alloc);
        self.symSignatures.deinit(self.alloc);

        self.funcSyms.deinit(self.alloc);
        self.funcSymSignatures.deinit(self.alloc);

        self.structs.deinit(self.alloc);
        self.alloc.free(self.panicMsg);
    }

    pub fn eval(self: *VM, src: []const u8, comptime trace: bool) !Value {
        var tt = stdx.debug.trace();
        const astRes = try self.parser.parse(src);
        if (astRes.has_error) {
            log.debug("Parse Error: {s}", .{astRes.err_msg});
            return error.ParseError;
        }
        tt.endPrint("parse");

        tt = stdx.debug.trace();
        const res = try self.compiler.compile(astRes);
        if (res.hasError) {
            log.debug("Compile Error: {s}", .{self.compiler.lastErr});
            return error.CompileError;
        }
        tt.endPrint("compile");

        // self.dumpByteCode(res.buf);

        if (trace) {
            const numOps = @enumToInt(cs.OpCode.end) + 1;
            var opCounts: [numOps]cs.OpCount = undefined;
            self.opCounts = &opCounts;
            var i: u32 = 0;
            while (i < numOps) : (i += 1) {
                self.opCounts[i] = .{
                    .code = i,
                    .count = 0,
                };
            }
        }
        tt = stdx.debug.trace();
        defer {
            tt.endPrint("eval");
            if (trace) {
                self.dumpInfo();
                const S = struct {
                    fn opCountLess(_: void, a: cs.OpCount, b: cs.OpCount) bool {
                        return a.count > b.count;
                    }
                };
                std.sort.sort(cs.OpCount, self.opCounts, {}, S.opCountLess);
                var i: u32 = 0;
                const numOps = @enumToInt(cs.OpCode.end) + 1;
                while (i < numOps) : (i += 1) {
                    if (self.opCounts[i].count > 0) {
                        const op = std.meta.intToEnum(cs.OpCode, self.opCounts[i].code) catch continue;
                        log.info("{} {}", .{op, self.opCounts[i].count});
                    }
                }
            }
        }

        return self.evalByteCode(res.buf, trace) catch |err| {
            if (err == error.Panic) {
                log.debug("panic: {s}", .{self.panicMsg});
            }
            return err;
        };
    }

    pub fn dumpInfo(self: *VM) void {
        log.info("stack cap: {}", .{self.stack.buf.len});
        log.info("stack top: {}", .{self.stack.top});
    }

    pub fn dumpByteCode(self: *VM, buf: ByteCodeBuffer) void {
        _ = self;
        for (buf.consts.items) |extra| {
            log.debug("extra {}", .{extra});
        }
    }

    pub fn popStackFrame(self: *VM, comptime numRetVals: u2) void {
        @setRuntimeSafety(debug);

        // If there are fewer return values than required from the function call, 
        // fill the missing slots with the none value.
        switch (numRetVals) {
            0 => {
                const retInfo = self.stack.buf[self.stack.top-1];
                const reqNumArgs = retInfo.retInfo.numRetVals;
                if (reqNumArgs == 0) {
                    self.stack.top = self.framePtr;
                    // Restore pc.
                    self.framePtr = retInfo.retInfo.framePtr;
                    self.pc = retInfo.retInfo.pc;
                    return;
                } else {
                    switch (reqNumArgs) {
                        0 => unreachable,
                        1 => {
                            self.stack.buf[self.framePtr] = Value.initNone();
                            self.stack.top = self.framePtr + 1;
                        },
                        2 => {
                            // Only start checking for space after 2 since function calls should have at least one slot after framePtr.
                            self.stack.ensureTotalCapacity(self.alloc, self.stack.top + 1) catch stdx.fatal();
                            self.stack.buf[self.framePtr] = Value.initNone();
                            self.stack.buf[self.framePtr+1] = Value.initNone();
                            self.stack.top = self.framePtr + 2;
                        },
                        3 => {
                            self.stack.ensureTotalCapacity(self.alloc, self.stack.top + 2) catch stdx.fatal();
                            self.stack.buf[self.framePtr] = Value.initNone();
                            self.stack.buf[self.framePtr+1] = Value.initNone();
                            self.stack.buf[self.framePtr+2] = Value.initNone();
                            self.stack.top = self.framePtr + 3;
                        },
                    }
                    // Restore pc.
                    self.framePtr = retInfo.retInfo.framePtr;
                    self.pc = retInfo.retInfo.pc;
                    return;
                }
            },
            1 => {
                const retInfo = self.stack.buf[self.stack.top-2];
                const reqNumArgs = retInfo.retInfo.numRetVals;
                if (reqNumArgs == 1) {
                    // Copy return value to retInfo.
                    self.stack.buf[self.framePtr] = self.stack.buf[self.stack.top-1];
                    self.stack.top = self.framePtr + 1;

                    // Restore pc.
                    self.framePtr = retInfo.retInfo.framePtr;
                    self.pc = retInfo.retInfo.pc;
                    return;
                } else {
                    switch (reqNumArgs) {
                        0 => {
                            self.stack.top = self.framePtr;
                        },
                        1 => unreachable,
                        2 => {
                            self.stack.buf[self.framePtr+1] = Value.initNone();
                            self.stack.top = self.framePtr + 2;
                        },
                        3 => {
                            // Only start checking for space at 3 since function calls should have at least two slot after framePtr.
                            // self.stack.ensureTotalCapacity(self.alloc, self.stack.top + 1) catch stdx.fatal();
                            self.stack.buf[self.framePtr+1] = Value.initNone();
                            self.stack.buf[self.framePtr+2] = Value.initNone();
                            self.stack.top = self.framePtr + 3;
                        },
                    }
                    // Restore pc.
                    self.framePtr = retInfo.retInfo.framePtr;
                    self.pc = retInfo.retInfo.pc;
                    return;
                }
            },
            2 => {
                unreachable;
            },
            3 => {
                unreachable;
            },
        }
    }

    pub fn evalByteCode(self: *VM, buf: ByteCodeBuffer, comptime trace: bool) !Value {
        if (buf.ops.items.len == 0) {
            return error.NoEndOp;
        }

        self.stack.clearRetainingCapacity();
        self.ops = buf.ops.items;
        self.consts = buf.consts.items;
        self.strBuf = buf.strBuf.items;
        self.pc = 0;
        self.framePtr = 0;

        try self.stack.ensureTotalCapacity(self.alloc, buf.mainLocalSize);
        self.stack.top = buf.mainLocalSize;

        try self.evalStackFrame(trace);
        if (self.stack.top == buf.mainLocalSize) {
            return Value.initNone();
        } else {
            return self.popRegister();
        }
    }

    fn sliceList(self: *VM, listV: Value, startV: Value, endV: Value) !Value {
        if (listV.isPointer()) {
            const obj = stdx.mem.ptrCastAlign(*GenericObject, listV.asPointer());
            if (obj.structId == self.listS) {
                const list = stdx.mem.ptrCastAlign(*Rc(List), listV.asPointer());
                var start = @floatToInt(i32, startV.toF64());
                if (start < 0) {
                    start = @intCast(i32, list.val.inner.items.len) + start + 1;
                }
                var end = @floatToInt(i32, endV.toF64());
                if (end < 0) {
                    end = @intCast(i32, list.val.inner.items.len) + end + 1;
                }
                if (start < 0 or start > list.val.inner.items.len) {
                    return self.panic("Index out of bounds");
                }
                if (end < start or end > list.val.inner.items.len) {
                    return self.panic("Index out of bounds");
                }
                return self.allocList(list.val.inner.items[@intCast(u32, start)..@intCast(u32, end)]);
            } else {
                try stdx.panic("expected list");
            }
        } else {
            try stdx.panic("expected pointer");
        }
    }

    fn allocList(self: *VM, elems: []const Value) !Value {
        const list = try self.alloc.create(Rc(List));
        list.* = .{
            .structId = self.listS,
            .rc = 1,
            .val = .{
                .inner = .{},
                .nextIterIdx = 0,
            },
        };
        try list.val.inner.appendSlice(self.alloc, elems);
        return Value.initPtr(list);
    }

    inline fn getStackFrameValue(self: VM, offset: u8) Value {
        @setRuntimeSafety(debug);
        return self.stack.buf[self.framePtr + offset];
    }

    inline fn setStackFrameValue(self: VM, offset: u8, val: Value) void {
        @setRuntimeSafety(debug);
        self.stack.buf[self.framePtr + offset] = val;
    }

    inline fn popRegister(self: *VM) Value {
        @setRuntimeSafety(debug);
        return self.stack.pop();
    }

    inline fn pushRegister(self: *VM, val: Value) !void {
        @setRuntimeSafety(debug);
        if (self.stack.top == self.stack.buf.len) {
            try self.stack.growTotalCapacity(self.alloc, self.stack.top + 1);
        }
        self.stack.buf[self.stack.top] = val;
        self.stack.top += 1;
    }

    fn addStruct(self: *VM, name: []const u8) !StructId {
        _ = name;
        const s = Struct{
            .name = "",
        };
        const id = @intCast(u32, self.structs.items.len);
        try self.structs.append(self.alloc, s);
        return id;
    }
    
    pub fn ensureFuncSym(self: *VM, name: []const u8) !SymbolId {
        const res = try self.funcSymSignatures.getOrPut(self.alloc, name);
        if (!res.found_existing) {
            const id = @intCast(u32, self.funcSyms.items.len);
            try self.funcSyms.append(self.alloc, .{
                .entryT = .none,
                .inner = undefined,
            });
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub fn ensureStructSym(self: *VM, name: []const u8) !SymbolId {
        const res = try self.symSignatures.getOrPut(self.alloc, name);
        if (!res.found_existing) {
            const id = @intCast(u32, self.symbols.items.len);
            try self.symbols.append(self.alloc, .{
                .mapT = .empty,
                .inner = undefined,
            });
            res.value_ptr.* = id;
            return id;
        } else {
            return res.value_ptr.*;
        }
    }

    pub inline fn setFuncSym(self: *VM, symId: SymbolId, sym: FuncSymbolEntry) !void {
        self.funcSyms.items[symId] = sym;
    }

    fn addStructSym(self: *VM, id: StructId, symId: SymbolId, sym: SymbolEntry) !void {
        switch (self.symbols.items[symId].mapT) {
            .empty => {
                self.symbols.items[symId] = .{
                    .mapT = .oneStruct,
                    .inner = .{
                        .oneStruct = .{
                            .id = id,
                            .sym = sym,
                        },
                    },
                };
            },
            else => stdx.panicFmt("unsupported {}", .{self.symbols.items[symId].mapT}),
        }
    }

    fn getIndex(self: *VM, left: Value, index: Value) !Value {
        if (left.isPointer()) {
            const obj = stdx.mem.ptrCastAlign(*GenericObject, left.asPointer());
            if (obj.structId == self.listS) {
                const list = stdx.mem.ptrCastAlign(*Rc(List), left.asPointer());
                const idx = @floatToInt(u32, index.toF64());
                if (idx < list.val.inner.items.len) {
                    return list.val.inner.items[idx];
                } else {
                    return error.OutOfBounds;
                }
            } else {
                return stdx.panic("expected list");
            }
        } else {
            return stdx.panic("expected pointer");
        }
    }

    fn panic(self: *VM, msg: []const u8) error{Panic, OutOfMemory} {
        self.panicMsg = try self.alloc.dupe(u8, msg);
        return error.Panic;
    }

    fn nativeListAdd(self: *VM, ptr: *anyopaque, args: []const Value) Value {
        @setRuntimeSafety(debug);
        if (args.len == 0) {
            stdx.panic("Args mismatch");
        }
        const list = stdx.mem.ptrCastAlign(*Rc(List), ptr);
        list.val.inner.append(self.alloc, args[0]) catch stdx.fatal();
        return Value.initNone();
    }

    fn nativeListNext(self: *VM, ptr: *anyopaque, args: []const Value) Value {
        @setRuntimeSafety(debug);
        _ = self;
        _ = args;
        const list = stdx.mem.ptrCastAlign(*Rc(List), ptr);
        if (list.val.nextIterIdx < list.val.inner.items.len) {
            defer list.val.nextIterIdx += 1;
            return list.val.inner.items[list.val.nextIterIdx];
        } else return Value.initNone();
    }

    fn nativeListIterator(self: *VM, ptr: *anyopaque, args: []const Value) Value {
        _ = self;
        _ = args;
        const list = stdx.mem.ptrCastAlign(*Rc(List), ptr);
        list.val.nextIterIdx = 0;
        return Value.initPtr(ptr);
    }

    fn nativeListResize(self: *VM, ptr: *anyopaque, args: []const Value) Value {
        if (args.len == 0) {
            stdx.panic("Args mismatch");
        }
        const list = stdx.mem.ptrCastAlign(*Rc(std.ArrayListUnmanaged(Value)), ptr);
        const size = @floatToInt(u32, args[0].toF64());
        list.val.resize(self.alloc, size) catch stdx.fatal();
        return Value.initNone();
    }

    fn setIndex(self: *VM, left: Value, index: Value, right: Value) !void {
        if (left.isPointer()) {
            const obj = stdx.mem.ptrCastAlign(*GenericObject, left.asPointer());
            if (obj.structId == self.listS) {
                const list = stdx.mem.ptrCastAlign(*Rc(std.ArrayListUnmanaged(Value)), left.asPointer());
                const idx = @floatToInt(u32, index.toF64());
                if (idx < list.val.items.len) {
                    list.val.items[idx] = right;
                } else {
                    // var i: u32 = @intCast(u32, list.val.items.len);
                    // try list.val.resize(self.alloc, idx + 1);
                    // while (i < idx) : (i += 1) {
                    //     list.val.items[i] = Value.none();
                    // }
                    // list.val.items[idx] = right;
                    return self.panic("Index out of bounds.");
                }
            } else {
                return stdx.panic("expected list");
            }
        } else {
            return stdx.panic("expected pointer");
        }
    }

    pub fn release(self: *VM, val: Value) void {
        @setRuntimeSafety(debug);
        if (val.isPointer()) {
            const obj = stdx.mem.ptrCastAlign(*GenericObject, val.asPointer());
            obj.rc -= 1;
            if (obj.rc == 0) {
                if (obj.structId == self.listS) {
                    const list = stdx.mem.ptrCastAlign(*Rc(std.ArrayListUnmanaged(Value)), val.asPointer());
                    list.val.deinit(self.alloc);
                    self.alloc.destroy(list);
                } else {
                    return stdx.panic("expected list");
                }
            }
        }
    }

    /// Current stack top is already pointing past the last arg. 
    fn callSym(self: *VM, symId: SymbolId, numArgs: u8, retInfo: Value) !void {
        @setRuntimeSafety(debug);
        const sym = self.funcSyms.items[symId];
        switch (sym.entryT) {
            .func => {
                self.pc = sym.inner.func.pc;
                self.framePtr = self.stack.top - numArgs;
                // numLocals includes the function params as well as the return info value.
                self.stack.top = self.framePtr + sym.inner.func.numLocals;

                if (self.stack.top > self.stack.buf.len) {
                    try self.stack.growTotalCapacity(self.alloc, self.stack.top);
                }
                // Push return pc address and previous current framePtr onto the stack.
                self.stack.buf[self.stack.top-1] = retInfo;
            },
            .none => stdx.panic("Symbol doesn't exist."),
            else => stdx.panic("unsupported callsym"),
        }
    }

    inline fn callSymEntry(self: *VM, entry: SymbolEntry, argStart: usize, objPtr: *anyopaque, numArgs: u8, comptime reqNumRetVals: u2) void {
        _ = numArgs;
        @setRuntimeSafety(debug);
        switch (entry.entryT) {
            .nativeFunc1 => {
                const args = self.stack.buf[argStart + 1..self.stack.top];
                const res = entry.inner.nativeFunc1(self, objPtr, args);
                if (reqNumRetVals == 1) {
                    self.stack.buf[argStart] = res;
                    self.stack.top = argStart + 1;
                } else {
                    switch (reqNumRetVals) {
                        0 => {
                            self.stack.top = argStart;
                        },
                        1 => stdx.panic("not possible"),
                        2 => {
                            stdx.panic("unsupported require 2 ret vals");
                        },
                        3 => {
                            stdx.panic("unsupported require 3 ret vals");
                        },
                    }
                }
            },
            .nativeFunc2 => {
                const func = @ptrCast(fn (*VM, *anyopaque, []const Value) cs.ValuePair, entry.inner.nativeFunc2);
                const args = self.stack.buf[argStart + 1..self.stack.top];
                const res = func(self, objPtr, args);
                if (reqNumRetVals == 2) {
                    self.stack.buf[argStart] = res.left;
                    self.stack.buf[argStart + 1] = res.right;
                    self.stack.top = argStart + 1;
                } else {
                    switch (reqNumRetVals) {
                        0 => {
                            self.stack.top = argStart;
                        },
                        1 => unreachable,
                        2 => {
                            unreachable;
                        },
                        3 => {
                            unreachable;
                        },
                    }
                }
            },
            else => stdx.panicFmt("unsupported {}", .{entry.entryT}),
        }
    }

    fn callObjSym(self: *VM, symId: SymbolId, numArgs: u8, comptime reqNumRetVals: u2) void {
        @setRuntimeSafety(debug);
        // numArgs includes the receiver.
        const argStart = self.stack.top - numArgs;
        const recv = self.stack.buf[argStart];
        if (recv.isPointer()) {
            const obj = stdx.mem.ptrCastAlign(*GenericObject, recv.asPointer());
            const map = self.symbols.items[symId];
            switch (map.mapT) {
                .oneStruct => {
                    if (obj.structId == map.inner.oneStruct.id) {
                        self.callSymEntry(map.inner.oneStruct.sym, argStart, recv.asPointer().?, numArgs, reqNumRetVals);
                    } else stdx.panic("Symbol does not exist for receiver.");
                },
                else => stdx.panicFmt("unsupported {}", .{map.mapT}),
            } 
        }
    }

    inline fn buildReturnInfo(self: VM, comptime numRetVals: u2) Value {
        @setRuntimeSafety(debug);
        return Value{
            .retInfo = .{
                .pc = @intCast(u32, self.pc),
                .framePtr = @intCast(u30, self.framePtr),
                .numRetVals = numRetVals,
            },
        };
    }

    fn evalStackFrame(self: *VM, comptime trace: bool) anyerror!void {
        @setRuntimeSafety(debug);
        while (true) {
            if (trace) {
                const op = self.ops[self.pc].code;
                self.opCounts[@enumToInt(op)].count += 1;
            }
            log.debug("op: {}", .{self.ops[self.pc].code});
            switch (self.ops[self.pc].code) {
                .pushTrue => {
                    try self.pushRegister(Value.initTrue());
                    self.pc += 1;
                    continue;
                },
                .pushFalse => {
                    try self.pushRegister(Value.initFalse());
                    self.pc += 1;
                    continue;
                },
                .pushNone => {
                    try self.pushRegister(Value.initNone());
                    self.pc += 1;
                    continue;
                },
                .pushConst => {
                    const idx = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    try self.pushRegister(Value{ .val = self.consts[idx].val });
                    continue;
                },
                .pushNot => {
                    const val = self.popRegister();
                    try self.pushRegister(evalNot(val));
                    self.pc += 1;
                    continue;
                },
                .pushCompare => {
                    const right = self.popRegister();
                    const left = self.popRegister();
                    try self.pushRegister(evalCompare(left, right));
                    self.pc += 1;
                    continue;
                },
                .pushLess => {
                    self.pc += 1;
                    const right = self.popRegister();
                    const left = self.popRegister();
                    try self.pushRegister(evalLess(left, right));
                    continue;
                },
                .pushGreater => {
                    const right = self.popRegister();
                    const left = self.popRegister();
                    try self.pushRegister(evalGreater(left, right));
                    self.pc += 1;
                    continue;
                },
                .pushLessEqual => {
                    const right = self.popRegister();
                    const left = self.popRegister();
                    try self.pushRegister(evalLessOrEqual(left, right));
                    self.pc += 1;
                    continue;
                },
                .pushGreaterEqual => {
                    const right = self.popRegister();
                    const left = self.popRegister();
                    try self.pushRegister(evalGreaterOrEqual(left, right));
                    self.pc += 1;
                    continue;
                },
                .pushOr => {
                    self.pc += 1;
                    const right = self.popRegister();
                    const left = self.popRegister();
                    try self.pushRegister(evalOr(left, right));
                    continue;
                },
                .pushAnd => {
                    self.pc += 1;
                    const right = self.popRegister();
                    const left = self.popRegister();
                    try self.pushRegister(evalAnd(left, right));
                    continue;
                },
                .pushAdd => {
                    self.pc += 1;
                    self.stack.top -= 1;
                    const left = self.stack.buf[self.stack.top-1];
                    const right = self.stack.buf[self.stack.top];
                    self.stack.buf[self.stack.top-1] = evalAdd(left, right);
                    continue;
                },
                .pushMinus => {
                    self.pc += 1;
                    self.stack.top -= 1;
                    const left = self.stack.buf[self.stack.top-1];
                    const right = self.stack.buf[self.stack.top];
                    self.stack.buf[self.stack.top-1] = evalMinus(left, right);
                    continue;
                },
                .pushMinus1 => {
                    const leftOffset = self.ops[self.pc+1].arg;
                    const rightOffset = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    if (leftOffset == NullStackOffsetU8) {
                        const left = self.stack.buf[self.stack.top-1];
                        const right = self.getStackFrameValue(rightOffset);
                        self.stack.buf[self.stack.top-1] = evalMinus(left, right);
                        continue;
                    } else {
                        const left = self.getStackFrameValue(leftOffset);
                        const right = self.stack.buf[self.stack.top-1];
                        self.stack.buf[self.stack.top-1] = evalMinus(left, right);
                        continue;
                    }
                },
                .pushMinus2 => {
                    const leftOffset = self.ops[self.pc+1].arg;
                    const rightOffset = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    const left = self.getStackFrameValue(leftOffset);
                    const right = self.getStackFrameValue(rightOffset);
                    try self.pushRegister(evalMinus(left, right));
                    continue;
                },
                .pushList => {
                    const numElems = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const top = self.stack.top;
                    const elems = self.stack.buf[top-numElems..top];
                    const list = try self.allocList(elems);
                    self.stack.top = top-numElems;
                    try self.pushRegister(list);
                    continue;
                },
                .pushSlice => {
                    self.pc += 1;
                    const end = self.popRegister();
                    const start = self.popRegister();
                    const list = self.popRegister();
                    const newList = try self.sliceList(list, start, end);
                    try self.pushRegister(newList);
                    continue;
                },
                .addSet => {
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const val = self.popRegister();
                    self.setStackFrameValue(offset, evalAdd(self.getStackFrameValue(offset), val));
                    continue;
                },
                .set => {
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const val = self.popRegister();
                    self.setStackFrameValue(offset, val);
                    continue;
                },
                .setNew => {
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const val = self.popRegister();
                    const reqSize = self.framePtr + offset + 1;
                    if (self.stack.top < reqSize) {
                        try self.stack.ensureTotalCapacity(self.alloc, reqSize);
                        self.stack.top = reqSize;
                    }
                    self.setStackFrameValue(offset, val);
                    continue;
                },
                .setIndex => {
                    self.pc += 1;
                    const right = self.popRegister();
                    const index = self.popRegister();
                    const left = self.popRegister();
                    try self.setIndex(left, index, right);
                    continue;
                },
                .load => {
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    const val = self.getStackFrameValue(offset);
                    try self.pushRegister(val);
                    continue;
                },
                .pushIndex => {
                    self.pc += 1;
                    const index = self.popRegister();
                    const left = self.popRegister();
                    const val = try self.getIndex(left, index);
                    try self.pushRegister(val);
                    continue;
                },
                .jumpBack => {
                    self.pc -= self.ops[self.pc+1].arg;
                    continue;
                },
                .jump => {
                    self.pc += self.ops[self.pc+1].arg;
                    continue;
                },
                .jumpNotCond => {
                    const pcOffset = self.ops[self.pc+1].arg;
                    const cond = self.popRegister();
                    if (!cond.toBool()) {
                        self.pc += pcOffset;
                    } else {
                        self.pc += 2;
                    }
                    continue;
                },
                .release => {
                    const offset = self.ops[self.pc+1].arg;
                    self.pc += 2;
                    self.release(self.getStackFrameValue(offset));
                    continue;
                },
                .pushCall => {
                    stdx.unsupported();
                },
                .call => {
                    stdx.unsupported();
                },
                .callStr => {
                    // const numArgs = self.ops[self.pc+1].arg;
                    // const str = self.extras[self.extraPc].two;
                    self.pc += 3;

                    // const top = self.registers.items.len;
                    // const vals = self.registers.items[top-numArgs..top];
                    // self.registers.items.len = top-numArgs;

                    // self.callStr(vals[0], self.strBuf[str[0]..str[1]], vals[1..]);
                    continue;
                },
                .callObjSym => {
                    const symId = self.ops[self.pc+1].arg;
                    const numArgs = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    self.callObjSym(symId, numArgs, 0);
                    continue;
                },
                .pushCallSym0 => {
                    const symId = self.ops[self.pc+1].arg;
                    const numArgs = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    const retInfo = self.buildReturnInfo(0);
                    try self.callSym(symId, numArgs, retInfo);
                    // try @call(.{ .modifier = .always_inline }, self.callSym, .{ symId, vals, false });
                    continue;
                },
                .pushCallSym1 => {
                    const symId = self.ops[self.pc+1].arg;
                    const numArgs = self.ops[self.pc+2].arg;
                    self.pc += 3;

                    const retInfo = self.buildReturnInfo(1);
                    try self.callSym(symId, numArgs, retInfo);
                    // try @call(.{ .modifier = .always_inline }, self.callSym, .{ symId, vals, true });
                    continue;
                },
                .forIter => {
                    const local = self.ops[self.pc+1].arg;
                    const endPc = self.pc + self.ops[self.pc+2].arg;
                    const innerPc = self.pc + 3;

                    self.callObjSym(self.iteratorObjSym, 1, 1);
                    const iter = self.popRegister();
                    if (local == 255) {
                        while (true) {
                            try self.pushRegister(iter);
                            // const retInfo2 = self.buildReturnInfo(1);
                            self.callObjSym(self.nextObjSym, 1, 1);
                            const next = self.popRegister();
                            if (next.isNone()) {
                                break;
                            }
                            self.pc = innerPc;
                            _ = try self.evalStackFrame(trace);
                            if (!self.contFlag) {
                                break;
                            }
                        }
                    } else {
                        while (true) {
                            try self.pushRegister(iter);
                            // const retInfo2 = self.buildReturnInfo(1);
                            self.callObjSym(self.nextObjSym, 1, 1);
                            const next = self.popRegister();
                            if (next.isNone()) {
                                break;
                            }
                            self.setStackFrameValue(local, next);
                            self.pc = innerPc;
                            _ = try self.evalStackFrame(trace);
                            if (!self.contFlag) {
                                break;
                            }
                        }
                    }
                    self.pc = endPc;
                },
                .forRange => {
                    const local = self.ops[self.pc+1].arg;
                    const endPc = self.pc + self.ops[self.pc+2].arg;
                    const innerPc = self.pc + 3;

                    const step = self.popRegister().toF64();
                    const rangeEnd = self.popRegister().toF64();
                    var i = self.popRegister().toF64();

                    // defer stdx.panicFmt("forrange {}", .{self.stack.top});

                    if (local == 255) {
                        while (i < rangeEnd) : (i += step) {
                            self.pc = innerPc;
                            _ = try self.evalStackFrame(trace);
                            if (!self.contFlag) {
                                break;
                            }
                        }
                    } else {
                        while (i < rangeEnd) : (i += step) {
                            self.setStackFrameValue(local, .{ .val = @bitCast(u64, i) });
                            self.pc = innerPc;
                            _ = try self.evalStackFrame(trace);
                            if (!self.contFlag) {
                                break;
                            }
                        }
                    }
                    self.pc = endPc;
                    continue;
                },
                .cont => {
                    self.contFlag = true;
                    return;
                },
                .ret2 => {
                    self.popStackFrame(2);
                    continue;
                },
                .ret1 => {
                    self.popStackFrame(1);
                    continue;
                },
                .ret0 => {
                    self.popStackFrame(0);
                    continue;
                },
                .end => {
                    return;
                },
            }
        }
    }
};

fn evalAnd(left: cs.Value, right: cs.Value) cs.Value {
    if (left.isNumber()) {
        if (left.asF64() == 0) {
            return left;
        } else {
            return right;
        }
    } else {
        switch (left.getTag()) {
            cs.TagFalse => return left,
            cs.TagTrue => return right,
            cs.TagNone => return left,
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalOr(left: cs.Value, right: cs.Value) cs.Value {
    if (left.isNumber()) {
        if (left.asF64() == 0) {
            return right;
        } else {
            return left;
        }
    } else {
        switch (left.getTag()) {
            cs.TagFalse => return right,
            cs.TagTrue => return left,
            cs.TagNone => return right,
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalGreaterOrEqual(left: cs.Value, right: cs.Value) cs.Value {
    return Value.initBool(left.toF64() >= right.toF64());
}

fn evalGreater(left: cs.Value, right: cs.Value) cs.Value {
    return Value.initBool(left.toF64() > right.toF64());
}

fn evalLessOrEqual(left: cs.Value, right: cs.Value) cs.Value {
    return Value.initBool(left.toF64() <= right.toF64());
}

fn evalLess(left: cs.Value, right: cs.Value) cs.Value {
    @setRuntimeSafety(debug);
    return Value.initBool(left.toF64() < right.toF64());
}

fn evalCompare(left: cs.Value, right: cs.Value) cs.Value {
    if (left.isNumber()) {
        return Value.initBool(right.isNumber() and left.asF64() == right.asF64());
    } else {
        switch (left.getTag()) {
            cs.TagFalse => return Value.initBool(right.isFalse()),
            cs.TagTrue => return Value.initBool(right.isTrue()),
            cs.TagNone => return Value.initBool(right.isNone()),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalMinus(left: cs.Value, right: cs.Value) cs.Value {
    @setRuntimeSafety(debug);
    if (left.isNumber()) {
        return Value.initF64(left.asF64() - right.toF64());
    } else {
        switch (left.getTag()) {
            cs.TagFalse => return Value.initF64(-right.toF64()),
            cs.TagTrue => return Value.initF64(1 - right.toF64()),
            cs.TagNone => return Value.initF64(-right.toF64()),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalAdd(left: cs.Value, right: cs.Value) cs.Value {
    @setRuntimeSafety(debug);
    if (left.isNumber()) {
        return Value.initF64(left.asF64() + right.toF64());
    } else {
        switch (left.getTag()) {
            cs.TagFalse => return Value.initF64(right.toF64()),
            cs.TagTrue => return Value.initF64(1 + right.toF64()),
            cs.TagNone => return Value.initF64(right.toF64()),
            else => stdx.panic("unexpected tag"),
        }
    }
}

fn evalNot(val: cs.Value) cs.Value {
    if (val.isNumber()) {
        return cs.Value.initFalse();
    } else {
        switch (val.getTag()) {
            cs.TagFalse => return cs.Value.initTrue(),
            cs.TagTrue => return cs.Value.initFalse(),
            cs.TagNone => return cs.Value.initTrue(),
            else => stdx.panic("unexpected tag"),
        }
    }
}

pub const StringIndexContext = struct {
    buf: *std.ArrayListUnmanaged(u8),

    pub fn hash(self: StringIndexContext, s: stdx.IndexSlice(u32)) u64 {
        return std.hash.Wyhash.hash(0, self.buf.items[s.start..s.end]);
    }

    pub fn eql(self: StringIndexContext, a: stdx.IndexSlice(u32), b: stdx.IndexSlice(u32)) bool {
        return std.mem.eql(u8, self.buf.items[a.start..a.end], self.buf.items[b.start..b.end]);
    }
};

pub const StringIndexInsertContext = struct {
    buf: *std.ArrayListUnmanaged(u8),

    pub fn hash(self: StringIndexInsertContext, s: []const u8) u64 {
        _ = self;
        return std.hash.Wyhash.hash(0, s);
    }

    pub fn eql(self: StringIndexInsertContext, a: []const u8, b: stdx.IndexSlice(u32)) bool {
        return std.mem.eql(u8, a, self.buf.items[b.start..b.end]);
    }
};

pub const Const = packed union {
    val: u64,
    two: [2]u32,
};

/// Holds vm instructions.
pub const ByteCodeBuffer = struct {
    alloc: std.mem.Allocator,
    /// The number of local vars in the main block to reserve space for.
    mainLocalSize: u32,
    ops: std.ArrayListUnmanaged(OpData),
    consts: std.ArrayListUnmanaged(Const),
    /// Contiguous constant strings in a buffer.
    strBuf: std.ArrayListUnmanaged(u8),
    /// Tracks the start index of strings that are already in strBuf.
    strMap: std.HashMapUnmanaged(stdx.IndexSlice(u32), u32, StringIndexContext, std.hash_map.default_max_load_percentage),

    pub fn init(alloc: std.mem.Allocator) ByteCodeBuffer {
        return .{
            .alloc = alloc,
            .mainLocalSize = 0,
            .ops = .{},
            .consts = .{},
            .strBuf = .{},
            .strMap = .{},
        };
    }

    pub fn deinit(self: *ByteCodeBuffer) void {
        self.ops.deinit(self.alloc);
        self.consts.deinit(self.alloc);
        self.strBuf.deinit(self.alloc);
        self.strMap.deinit(self.alloc);
    }

    pub fn clear(self: *ByteCodeBuffer) void {
        self.ops.clearRetainingCapacity();
        self.consts.clearRetainingCapacity();
        self.strBuf.clearRetainingCapacity();
        self.strMap.clearRetainingCapacity();
    }

    pub fn pushConst(self: *ByteCodeBuffer, val: Const) !u32 {
        const start = @intCast(u32, self.consts.items.len);
        try self.consts.resize(self.alloc, self.consts.items.len + 1);
        self.consts.items[start] = val;
        return start;
    }

    pub fn pushOp(self: *ByteCodeBuffer, code: OpCode) !void {
        const start = self.ops.items.len;
        try self.ops.resize(self.alloc, self.ops.items.len + 1);
        self.ops.items[start] = .{ .code = code };
    }

    pub fn pushOp1(self: *ByteCodeBuffer, code: OpCode, arg: u8) !void {
        const start = self.ops.items.len;
        try self.ops.resize(self.alloc, self.ops.items.len + 2);
        self.ops.items[start] = .{ .code = code };
        self.ops.items[start+1] = .{ .arg = arg };
    }

    pub fn pushOp2(self: *ByteCodeBuffer, code: OpCode, arg: u8, arg2: u8) !void {
        const start = self.ops.items.len;
        try self.ops.resize(self.alloc, self.ops.items.len + 3);
        self.ops.items[start] = .{ .code = code };
        self.ops.items[start+1] = .{ .arg = arg };
        self.ops.items[start+2] = .{ .arg = arg2 };
    }

    pub fn setOpArgs1(self: *ByteCodeBuffer, idx: usize, arg: u8) void {
        self.ops.items[idx].arg = arg;
    }

    pub fn getStringConst(self: *ByteCodeBuffer, str: []const u8) !stdx.IndexSlice(u32) {
        const ctx = StringIndexContext{ .buf = &self.strBuf };
        const insertCtx = StringIndexInsertContext{ .buf = &self.strBuf };
        const res = try self.strMap.getOrPutContextAdapted(self.alloc, str, insertCtx, ctx);
        if (res.found_existing) {
            return res.key_ptr.*;
        } else {
            const start = @intCast(u32, self.strBuf.items.len);
            try self.strBuf.appendSlice(self.alloc, str);
            res.key_ptr.* = stdx.IndexSlice(u32).init(start, @intCast(u32, self.strBuf.items.len));
            return res.key_ptr.*;
        }
    }
};

pub const OpData = packed union {
    code: OpCode,
    arg: u8,
};

pub const OpCode = enum(u8) {
    /// Push boolean onto register stack.
    pushTrue,
    pushFalse,
    /// Push none value onto register stack.
    pushNone,
    /// Push constant value onto register stack.
    pushConst,
    /// Pops top two registers, performs or, and pushes result onto stack.
    pushOr,
    /// Pops top two registers, performs and, and pushes result onto stack.
    pushAnd,
    /// Pops top register, performs not, and pushes result onto stack.
    pushNot,
    /// Pops top register and copies value to address relative to the local frame.
    set,
    /// Same as set except it also does a ensure capacity on the stack.
    setNew,
    /// Pops right, index, left registers, sets right value to address of left[index].
    setIndex,
    /// Loads a value from address relative to the local frame onto the register stack.
    load,
    pushIndex,
    /// Pops top two registers, performs addition, and pushes result onto stack.
    pushAdd,
    /// Pops specifc number of registers to allocate a new list on the heap. Pointer to new list is pushed onto the stack.
    pushList,
    pushSlice,
    /// Pops top register, if value evals to false, jumps the pc forward by an offset.
    jumpNotCond,
    /// Jumps the pc forward by an offset.
    jump,
    jumpBack,

    release,
    /// Pops args and callee registers, performs a function call, and pushes result onto stack.
    pushCall,
    /// Like pushCall but does not push the result onto the stack.
    call,
    /// Num args includes the receiver.
    callStr,
    /// Num args includes the receiver.
    callObjSym,
    pushCallSym0,
    pushCallSym1,
    ret2,
    ret1,
    ret0,
    addSet,
    pushCompare,
    pushLess,
    pushGreater,
    pushLessEqual,
    pushGreaterEqual,
    pushMinus,
    pushMinus1,
    pushMinus2,
    cont,
    forRange,
    forIter,

    /// Returns the top register or None back to eval.
    end,
};

const NullStackOffsetU8 = 255;

pub fn Rc(comptime T: type) type {
    return struct {
        structId: StructId,
        rc: u32,
        val: T,
    };
}

const GenericObject = struct {
    structId: StructId,
    rc: u32,
};

const SymbolMapType = enum {
    oneStruct,
    // twoStructs,
    manyStructs,
    empty,
};

const SymbolMap = struct {
    mapT: SymbolMapType,
    inner: union {
        oneStruct: struct {
            id: StructId,
            sym: SymbolEntry,
        },
        // twoStructs: struct {
        // },
        manyStructs: struct {
            map: std.AutoHashMapUnmanaged(StructId, SymbolEntry),

            fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
                self.map.deinit(alloc);
            }
        },
    },
};

const SymbolEntryType = enum {
    func,
    nativeFunc1,
    nativeFunc2,
    field,
};

const SymbolEntry = struct {
    entryT: SymbolEntryType,
    inner: packed union {
        nativeFunc1: fn (*VM, *anyopaque, []const Value) Value,
        nativeFunc2: fn (*VM, *anyopaque, []const Value) cs.ValuePair,
        func: packed struct {
            pc: u32,
        },
    },

    fn initNativeFunc1(func: fn (*VM, *anyopaque, []const Value) Value) SymbolEntry {
        return .{
            .entryT = .nativeFunc1,
            .inner = .{
                .nativeFunc1 = func,
            },
        };
    }

    fn initNativeFunc2(func: fn (*VM, *anyopaque, []const Value) cs.ValuePair) SymbolEntry {
        return .{
            .entryT = .nativeFunc2,
            .inner = .{
                .nativeFunc2 = func,
            },
        };
    }
};

const FuncSymbolEntryType = enum {
    func,
    nativeFunc,
    none,
};

pub const FuncSymbolEntry = struct {
    entryT: FuncSymbolEntryType,
    inner: packed union {
        nativeFunc: *const anyopaque,
        func: packed struct {
            pc: usize,
            numLocals: u32,
        },
    },

    fn initNativeFunc(func: *const anyopaque) FuncSymbolEntry {
        return .{
            .entryT = .nativeFunc,
            .inner = .{
                .nativeFunc = func,
            },
        };
    }

    pub fn initFunc(pc: usize, numLocals: u32) FuncSymbolEntry {
        return .{
            .entryT = .func,
            .inner = .{
                .func = .{
                    .pc = pc,
                    .numLocals = numLocals,
                },
            },
        };
    }
};

const StructId = u32;

const Struct = struct {
    name: []const u8,
};

// const StructSymbol = struct {
//     name: []const u8,
// };

const SymbolId = u32;

pub const OpCount = struct {
    code: u32,
    count: u32,
};

const List = struct {
    inner: std.ArrayListUnmanaged(Value),
    nextIterIdx: u32,
};