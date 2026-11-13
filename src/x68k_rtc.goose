// Ricoh RP5C15 real-time clock ($E8A000-$E8BFFF, odd bytes; 16 registers repeating every 32 bytes).
//
// The counters are kept as seconds since 1970-01-01 in local time plus emulated time, so the
// clock runs with the machine and replays identically. Writes to a digit shift the clock by
// the difference, as XEiJ does, and unnormalized values read back normalized. The ALARM pin
// (MFP GPIP0) is the NOR of the alarm match and the 1 Hz / 16 Hz outputs; as in XEiJ the
// alarm match itself is not modelled.

import std;
namespace rtc;

let ::RTC_UNITS_PER_SEC: i64 = 10000000; // emulated time unit: 0.1 us
let ::RTC_HZ_UNIT: i64 = 312500;         // 1/32 s
let ::RTC_EPOCH_2026: i64 = 1767225600;  // 2026-01-01 00:00:00, XEiJ's ARCL clock origin

struct X68kRTC {
    now: i64 = 0,               // emulated time since power-on, 0.1 us
    base: i64 = RTC_EPOCH_2026,     // counter value in seconds at run_origin
    run_origin: i64 = 0,
    running: bool = true,
    alarm_on: bool = false,
    bank: u8 = 0,
    rule: u8 = 1,               // 0 = 12-hour, 1 = 24-hour
    week_gap: i64 = 4,          // weekday = (days since 1970 + week_gap) mod 7
    test: u8 = 0,
    bank1: u8[32] = [0; 32],    // CLKOUT, ADJUST and alarm registers as written
    hz: u8 = 12,                // RESET bits 3-2: %00 1 Hz + 16 Hz, %01 1 Hz, %10 16 Hz, %11 off
    hz_high: bool = true,
    hz_stage: i32 = -1,
    hz_next: i64 = 0,
}
type ::X68kRTC = rtc::X68kRTC;

fn init(rtc: X68kRTC&, local_seconds: i64) {
    rtc = X68kRTC {};
    rtc.base = local_seconds;
}

// Days since 1970-01-01 for a proleptic Gregorian date (month may be out of range).
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
    if !rtc.running { return rtc.base; }
    return rtc.base + div_euclid(rtc.now - rtc.run_origin, RTC_UNITS_PER_SEC);
}

// Bank 0 counter digits: 0 sec, 1 10 sec, 2 min, 3 10 min, 4 hour, 5 10 hour, 6 weekday,
// 7 day, 8 10 day, 9 month, 10 10 month, 11 year, 12 10 year (year 00 = 1980).
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

// Re-date the clock to year/month/day digits, keeping the time of day.
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
                // Keep the 12/20-hour digit and reinterpret it.
                let h1: i64 = rtc.digit(5) >> 1;
                let old = if rtc.rule == 0 { 43200 } else { 72000 };
                let new = if d == 0 { 43200 } else { 72000 };
                rtc.add_seconds(h1 * (new - old));
                rtc.rule = d as u8;
            }
            return;
        }
        if r == 0x17 { return; } // leap counter follows the year counter
        rtc.bank1[r as i64] = val & 15;
        return;
    }
    let masks: u8[13] = [15, 7, 15, 7, 15, 3, 7, 15, 3, 15, 1, 15, 15];
    if idx > 12 { return; }
    let d: i64 = val & masks[idx];
    let cur: i64 = rtc.digit(idx);
    if idx == 0 { rtc.add_seconds(d - cur); }
    else if idx == 1 { rtc.add_seconds((d - cur) * 10); }
    else if idx == 2 { rtc.add_seconds((d - cur) * 60); }
    else if idx == 3 { rtc.add_seconds((d - cur) * 600); }
    else if idx == 4 { rtc.add_seconds((d - cur) * 3600); }
    else if idx == 5 {
        let unit = if rtc.rule == 0 { 43200 } else { 72000 };
        rtc.add_seconds(((d >> 1) - (cur >> 1)) * unit + ((d & 1) - (cur & 1)) * 36000);
    }
    else if idx == 6 { rtc.week_gap = (rtc.week_gap + d - cur) % 7; }
    else if idx == 7 { rtc.add_seconds((d - cur) * 86400); }
    else if idx == 8 { rtc.add_seconds((d - cur) * 864000); }
    else {
        var y = 1980 + (rtc.digit(12) as i64) * 10 + (rtc.digit(11));
        var mo = (rtc.digit(10) as i64) * 10 + (rtc.digit(9));
        let day = (rtc.digit(8) as i64) * 10 + (rtc.digit(7));
        if idx == 9 { mo = mo - cur + d; }
        else if idx == 10 { mo = mo - cur * 10 + d * 10; }
        else if idx == 11 { y = y - cur + d; }
        else { y = y - cur * 10 + d * 10; }
        rtc.set_date(y, mo, day);
    }
}

// 1 Hz / 16 Hz outputs start low when enabled and step in 1/32 s units (XEiJ RTC_HZ_TICKER).
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

// ALARM output level (true = high). Read through MFP GPIP0.
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
