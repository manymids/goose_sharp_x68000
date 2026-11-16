// リコー RP5C15 リアルタイムクロック ($E8A000-$E8BFFF の奇数番地。16 個のレジスタが 32 バイトごとに繰り返す)。
//
// カウンタは 1970-01-01 (ローカル時刻) からの秒に、エミュレートした時間を足して持つので、
// 時計は機械と一緒に進み、毎回同じように再生できる。桁へ書くと、XEiJ と同じく差の分だけ時計をずらし、
// 範囲外の値は正規化して読み返す。ALARM 端子 (MFP GPIP0) はアラームの一致と 1 Hz / 16 Hz 出力の
// NOR。XEiJ と同じく、アラームの一致そのものは作っていない。

import std;
namespace rtc;

let ::RTC_UNITS_PER_SEC: i64 = 10000000; // エミュレートした時間の単位: 0.1 us
let ::RTC_HZ_UNIT: i64 = 312500;         // 1/32 s
let ::RTC_EPOCH_2026: i64 = 1767225600;  // 2026-01-01 00:00:00。XEiJ の ARCL の時計の起点

struct X68kRTC {
    now: i64 = 0,               // 電源を入れてからのエミュレートした時間 (0.1 us)
    base: i64 = RTC_EPOCH_2026,     // run_origin の時点のカウンタの値 (秒)
    run_origin: i64 = 0,
    running: bool = true,
    alarm_on: bool = false,
    bank: u8 = 0,
    rule: u8 = 1,               // 0 = 12 時間制、1 = 24 時間制
    week_gap: i64 = 4,          // 曜日 = (1970 年からの日数 + week_gap) mod 7
    test: u8 = 0,
    bank1: u8[32] = [0; 32],    // CLKOUT、ADJUST、アラームのレジスタ (書いた値)
    hz: u8 = 12,                // RESET の bit 3-2: %00 1 Hz + 16 Hz、%01 1 Hz、%10 16 Hz、%11 なし
    hz_high: bool = true,
    hz_stage: i32 = -1,
    hz_next: i64 = 0,
}
type ::X68kRTC = rtc::X68kRTC;

fn init(rtc: X68kRTC&, local_seconds: i64) {
    rtc = X68kRTC {};
    rtc.base = local_seconds;
}

// 先発グレゴリオ暦の日付の 1970-01-01 からの日数 (月は範囲外でもよい)。
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let m0 = month - 1;
    let y0 = year + div_euclid(m0, 12);
    let m = m0 % 12 + 1;
    let y = if m <= 2 { y0 - 1 } else { y0 };
    let era = div_euclid(y, 400);
    let yoe = y - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

// 1970-01-01 からの日数を 年, 月, 日 に直す。
fn civil_from_days(z0: i64) -> i64, i64, i64 {
    let z = z0 + 719468;
    let era = div_euclid(z, 146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + (if month <= 2 { 1 } else { 0 });
    return year, month, day;
}

fn seconds(rtc: X68kRTC&) -> i64 {
    guard rtc.running else { return rtc.base; }
    return rtc.base + div_euclid(rtc.now - rtc.run_origin, RTC_UNITS_PER_SEC);
}

// バンク 0 のカウンタの桁: 0 秒、1 10 秒、2 分、3 10 分、4 時、5 10 時、6 曜日、
// 7 日、8 10 日、9 月、10 10 月、11 年、12 10 年 (年 00 = 1980)。
fn digit(rtc: X68kRTC&, idx: i32) -> u8 {
    let sec = rtc.seconds();
    let days = div_euclid(sec, 86400);
    let tod = sec - days * 86400;
    var hour = tod / 3600;
    if rtc.rule == 0 && hour >= 12 { hour += 8; }
    let minute = (tod / 60) % 60;
    let second = tod % 60;
    let y, mo, d = civil_from_days(days);
    let yy = (y - 1980) % 100;
    let v = match idx {
        0 => second % 10,
        1 => second / 10,
        2 => minute % 10,
        3 => minute / 10,
        4 => hour % 10,
        5 => hour / 10,
        6 => (days + rtc.week_gap) % 7,
        7 => d % 10,
        8 => d / 10,
        9 => mo % 10,
        10 => mo / 10,
        11 => yy % 10,
        12 => yy / 10,
        _ => 0,
    };
    return v as u8;
}

fn add_seconds(rtc: X68kRTC&, delta: i64) {
    rtc.base += delta;
}

// 時刻はそのままで、日付を年 / 月 / 日の桁に合わせる。
fn set_date(rtc: X68kRTC&, year: i64, month: i64, day: i64) {
    let days = div_euclid(rtc.seconds(), 86400);
    rtc.base += (days_from_civil(year, month, day) - days) * 86400;
}

fn read(rtc: X68kRTC&, reg: i32) -> u8 {
    let r = reg & 31;
    if (r & 1) == 0 { return 0; }
    if r == 0x1B {
        var mode: u8 = rtc.bank;
        if rtc.running { mode |= 8; }
        if rtc.alarm_on { mode |= 4; }
        return mode;
    }
    if r == 0x1D { return rtc.test; }
    if r == 0x1F { return 0; }
    let idx = (r >> 1);
    if rtc.bank == 0 { return rtc.digit(idx); }
    if r == 0x15 { return rtc.rule; }
    if r == 0x17 {
        let y, mo, d = civil_from_days(div_euclid(rtc.seconds(), 86400));
        return ((y - 1980) % 4) as u8;
    }
    return rtc.bank1[r as i64] & 15;
}

fn write(rtc: X68kRTC&, reg: i32, val: u8) {
    let r = reg & 31;
    if (r & 1) == 0 { return; }
    if r == 0x1B {
        let start = !rtc.running && (val & 8) != 0;
        let stop = rtc.running && (val & 8) == 0;
        if stop { rtc.base = rtc.seconds(); }
        if start { rtc.run_origin = rtc.now; }
        rtc.running = (val & 8) != 0;
        rtc.alarm_on = (val & 4) != 0;
        rtc.bank = val & 1;
        return;
    }
    if r == 0x1D { rtc.test = val & 15; return; }
    if r == 0x1F { rtc.set_hz(val & 12); return; }
    let idx = (r >> 1);
    if rtc.bank == 1 {
        if r == 0x15 {
            let d: i64 = val & 1;
            if d != rtc.rule {
                // 12 / 24 時間の桁を残して、意味だけを読み替える。
                let h1: i64 = rtc.digit(5) >> 1;
                let old = if rtc.rule == 0 { 43200 } else { 72000 };
                let new = if d == 0 { 43200 } else { 72000 };
                rtc.add_seconds(h1 * (new - old));
                rtc.rule = d as u8;
            }
            return;
        }
        if r == 0x17 { return; } // うるう年カウンタは年のカウンタに従う
        rtc.bank1[r as i64] = val & 15;
        return;
    }
    let masks: u8[13] = [15, 7, 15, 7, 15, 3, 7, 15, 3, 15, 1, 15, 15];
    if idx > 12 { return; }
    let d: i64 = val & masks[idx];
    let cur: i64 = rtc.digit(idx);
    // 時刻の桁は秒へ直して足す。日付の桁 (月と年) は暦を組み直す。
    match idx {
        0 => { rtc.add_seconds(d - cur); },                // 秒の 1 の位
        1 => { rtc.add_seconds((d - cur) * 10); },         // 秒の 10 の位
        2 => { rtc.add_seconds((d - cur) * 60); },         // 分の 1 の位
        3 => { rtc.add_seconds((d - cur) * 600); },        // 分の 10 の位
        4 => { rtc.add_seconds((d - cur) * 3600); },       // 時の 1 の位
        5 => {                                              // 時の 10 の位 (12 時間制では午後の印も)
            let unit = if rtc.rule == 0 { 43200 } else { 72000 };
            rtc.add_seconds(((d >> 1) - (cur >> 1)) * unit + ((d & 1) - (cur & 1)) * 36000);
        },
        6 => { rtc.week_gap = (rtc.week_gap + d - cur) % 7; },   // 曜日
        7 => { rtc.add_seconds((d - cur) * 86400); },      // 日の 1 の位
        8 => { rtc.add_seconds((d - cur) * 864000); },     // 日の 10 の位
        _ => {                                              // 9, 10: 月、11, 12: 年 (1980 年から)
            let step: i64 = if idx == 9 || idx == 11 { 1 } else { 10 };
            var y = 1980 + (rtc.digit(12) as i64) * 10 + (rtc.digit(11));
            var mo = (rtc.digit(10) as i64) * 10 + (rtc.digit(9));
            let day = (rtc.digit(8) as i64) * 10 + (rtc.digit(7));
            if idx <= 10 { mo += (d - cur) * step; } else { y += (d - cur) * step; }
            rtc.set_date(y, mo, day);
        },
    }
}

// 1 Hz / 16 Hz の出力は有効にしたとき low から始まり、1/32 秒単位で進む (XEiJ RTC_HZ_TICKER)。
fn set_hz(rtc: X68kRTC&, hz: u8) {
    if rtc.hz == hz { return; }
    rtc.hz = hz;
    if hz < 12 {
        rtc.hz_high = false;
        rtc.hz_stage = if hz == 0 { 17 } else if hz == 4 { 16 } else { 1 };
        rtc.hz_next = rtc.now + RTC_HZ_UNIT * (rtc.hz_stage);
    } else {
        rtc.hz_high = true;
        rtc.hz_stage = -1;
    }
}

// ALARM 出力のレベル (true = high)。MFP の GPIP0 から読む。
fn alarm_pin(rtc: X68kRTC&) -> bool {
    if rtc.hz_stage < 0 { return true; }
    while rtc.hz_next <= rtc.now {
        rtc.hz_high = !rtc.hz_high;
        let length: i32 = if rtc.hz == 0 { if rtc.hz_stage == 0 { 17 } else { 1 } } else if rtc.hz == 4 { 16 } else { 1 };
        rtc.hz_stage += length;
        if rtc.hz_stage == 32 { rtc.hz_stage = 0; }
        rtc.hz_next += RTC_HZ_UNIT * (length);
    }
    return rtc.hz_high;
}
