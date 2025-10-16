pub const NanoUnit = struct {
    pub const ms = 10e5;
    pub const s = 10e8;
};

pub const ByteUnit = struct {
    pub const kb = 1 << 10;
    pub const mb = 1 << 20;
    pub const gb = 1 << 30;
};

pub const CacheSize = struct {
    // TODO: dynamically grab this?
    pub const L1 = ByteUnit.kb * 128;
    pub const L2 = ByteUnit.mb * 1;
    pub const L3 = ByteUnit.mb * 8;
};
