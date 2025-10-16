pub const C = @cImport({
    @cDefine("_GNU_SOURCE", "");
    @cInclude("fcntl.h");
});
pub const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});
