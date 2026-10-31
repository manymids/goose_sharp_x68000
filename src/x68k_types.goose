// MCP の層ビット。実行中の cpu.a[] は 0..7 なので、レジスタ番号は m68k_types の REG_A0 = 0 を使う。
import .m68k_types;

let MCP_LAYER_L0 = 1;
let MCP_LAYER_L1 = 2;
let MCP_LAYER_L2 = 4;
let MCP_LAYER_L3 = 8;
let MCP_LAYER_L4 = 16;
let MCP_LAYER_DEFAULT = 3;
let MCP_LAYER_ALL = 31;

let KEY_ACTION_PRESS   = 1;
let KEY_ACTION_RELEASE = 2;
let KEY_ACTION_TAP     = 3;
