// Ricoh RP5C15 real-time clock ($E8A000-$E8BFFF, odd bytes; 16 registers repeating every 32 bytes).
//
// The counters are kept as seconds since 1970-01-01 in local time plus emulated time, so the
// clock runs with the machine and replays identically. Writes to a digit shift the clock by
// the difference, as XEiJ does, and unnormalized values read back normalized. The ALARM pin
// (MFP GPIP0) is the NOR of the alarm match and the 1 Hz / 16 Hz outputs; as in XEiJ the
// alarm match itself is not modelled.

import std;

let RTC_UNITS_PER_SEC: i64 = 10000000; // emulated time unit: 0.1 us
let RTC_HZ_UNIT: i64 = 312500;         // 1/32 s
let RTC_EPOCH_2026: i64 = 1767225600;  // 2026-01-01 00:00:00, XEiJ's ARCL clock origin

struct X68kRTC {
    now: i64 = 0,               // emulated time since power-on, 0.1 us
    base: i64 = 1767225600,     // counter value in seconds at run_origin
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
    hz_next: i64 = 0
}

fn rtc_init(rtc: X68kRTC&, local_seconds: i64) {
    rtc = X68kRTC {};
    rtc.base = local_seconds;
}

fn rtc_fdiv(a: i64, b: i64) -> i64 {
    let q = a / b;
    if (a % b != 0) && ((a < 0) != (b < 0)) { return q - 1; }
    return q;
}

fn rtc_fmod(a: i64, b: i64) -> i64 {
    return a - rtc_fdiv(a, b) * b;
}

// Days since 1970-01-01 for a proleptic Gregorian date (month may be out of range).
fn rtc_days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let m0 = month - 1;
    let y0 = year + rtc_fdiv(m0, 12);
    let m = rtc_fmod(m0, 12) + 1;
    let y = if m <= 2 { y0 - 1 } else { y0 };
    let era = rtc_fdiv(y, 400);
    let yoe = y - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

fn rtc_civil_from_days(z0: i64, year: i64&, month: i64&, day: i64&) {
    let z = z0 + 719468;
    let era = rtc_fdiv(z, 146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    day = doy - (153 * mp + 2) / 5 + 1;
    month = if mp < 10 { mp + 3 } else { mp - 9 };
    year = yoe + era * 400 + (if month <= 2 { 1 } else { 0 });
}

fn rtc_seconds(rtc: X68kRTC&) -> i64 {
    if !rtc.running { return rtc.base; }
    return rtc.base + rtc_fdiv(rtc.now - rtc.run_origin, RTC_UNITS_PER_SEC);
}

// Bank 0 counter digits: 0 sec, 1 10 sec, 2 min, 3 10 min, 4 hour, 5 10 hour, 6 weekday,
// 7 day, 8 10 day, 9 month, 10 10 month, 11 year, 12 10 year (year 00 = 1980).
fn rtc_digit(rtc: X68kRTC&, idx: i32) -> u8 {
    let sec = rtc_seconds(rtc);
    let days = rtc_fdiv(sec, 86400);
    let tod = sec - days * 86400;
    var hour = tod / 3600;
    if rtc.rule == 0 && hour >= 12 { hour += 8; }
    let minute = (tod / 60) % 60;
    let second = tod % 60;
    var y: i64 = 0;
    var mo: i64 = 0;
    var d: i64 = 0;
    rtc_civil_from_days(days, y, mo, d);
    let yy = rtc_fmod(y - 1980, 100);
    var v: i64 = 0;
    if idx == 0 { v = second % 10; }
    else if idx == 1 { v = second / 10; }
    else if idx == 2 { v = minute % 10; }
    else if idx == 3 { v = minute / 10; }
    else if idx == 4 { v = hour % 10; }
    else if idx == 5 { v = hour / 10; }
    else if idx == 6 { v = rtc_fmod(days + rtc.week_gap, 7); }
    else if idx == 7 { v = d % 10; }
    else if idx == 8 { v = d / 10; }
    else if idx == 9 { v = mo % 10; }
    else if idx == 10 { v = mo / 10; }
    else if idx == 11 { v = yy % 10; }
    else if idx == 12 { v = yy / 10; }
    return v as u8;
}

fn rtc_add_seconds(rtc: X68kRTC&, delta: i64) {
    rtc.base += delta;
}

// Re-date the clock to year/month/day digits, keeping the time of day.
fn rtc_set_date(rtc: X68kRTC&, year: i64, month: i64, day: i64) {
    let days = rtc_fdiv(rtc_seconds(rtc), 86400);
    rtc.base += (rtc_days_from_civil(year, month, day) - days) * 86400;
}

fn rtc_read(rtc: X68kRTC&, reg: i32) -> u8 {
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
    let idx = (r >> 1) as i32;
    if rtc.bank == 0 { return rtc_digit(rtc, idx); }
    if r == 0x15 { return rtc.rule; }
    if r == 0x17 {
        var y: i64 = 0;
        var mo: i64 = 0;
        var d: i64 = 0;
        rtc_civil_from_days(rtc_fdiv(rtc_seconds(rtc), 86400), y, mo, d);
        return rtc_fmod(y - 1980, 4) as u8;
    }
    return rtc.bank1[r as i64] & 15;
}

fn rtc_write(rtc: X68kRTC&, reg: i32, val: u8) {
    let r = reg & 31;
    if (r & 1) == 0 { return; }
    if r == 0x1B {
        let start = !rtc.running && (val & 8) != 0;
        let stop = rtc.running && (val & 8) == 0;
        if stop { rtc.base = rtc_seconds(rtc); }
        if start { rtc.run_origin = rtc.now; }
        rtc.running = (val & 8) != 0;
        rtc.alarm_on = (val & 4) != 0;
        rtc.bank = val & 1;
        return;
    }
    if r == 0x1D { rtc.test = val & 15; return; }
    if r == 0x1F { rtc_set_hz(rtc, val & 12); return; }
    let idx = (r >> 1) as i32;
    if rtc.bank == 1 {
        if r == 0x15 {
            let d = (val & 1) as i64;
            if d != rtc.rule as i64 {
                // Keep the 12/20-hour digit and reinterpret it.
                let h1 = (rtc_digit(rtc, 5) >> 1) as i64;
                let old = if rtc.rule == 0 { 43200 } else { 72000 };
                let new = if d == 0 { 43200 } else { 72000 };
                rtc_add_seconds(rtc, h1 * (new - old));
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
    let d = (val & masks[idx]) as i64;
    let cur = rtc_digit(rtc, idx) as i64;
    if idx == 0 { rtc_add_seconds(rtc, d - cur); }
    else if idx == 1 { rtc_add_seconds(rtc, (d - cur) * 10); }
    else if idx == 2 { rtc_add_seconds(rtc, (d - cur) * 60); }
    else if idx == 3 { rtc_add_seconds(rtc, (d - cur) * 600); }
    else if idx == 4 { rtc_add_seconds(rtc, (d - cur) * 3600); }
    else if idx == 5 {
        let unit = if rtc.rule == 0 { 43200 } else { 72000 };
        rtc_add_seconds(rtc, ((d >> 1) - (cur >> 1)) * unit + ((d & 1) - (cur & 1)) * 36000);
    }
    else if idx == 6 { rtc.week_gap = rtc_fmod(rtc.week_gap + d - cur, 7); }
    else if idx == 7 { rtc_add_seconds(rtc, (d - cur) * 86400); }
    else if idx == 8 { rtc_add_seconds(rtc, (d - cur) * 864000); }
    else {
        var y = 1980 + (rtc_digit(rtc, 12) as i64) * 10 + (rtc_digit(rtc, 11) as i64);
        var mo = (rtc_digit(rtc, 10) as i64) * 10 + (rtc_digit(rtc, 9) as i64);
        let day = (rtc_digit(rtc, 8) as i64) * 10 + (rtc_digit(rtc, 7) as i64);
        if idx == 9 { mo = mo - cur + d; }
        else if idx == 10 { mo = mo - cur * 10 + d * 10; }
        else if idx == 11 { y = y - cur + d; }
        else { y = y - cur * 10 + d * 10; }
        rtc_set_date(rtc, y, mo, day);
    }
}

// 1 Hz / 16 Hz outputs start low when enabled and step in 1/32 s units (XEiJ RTC_HZ_TICKER).
fn rtc_set_hz(rtc: X68kRTC&, hz: u8) {
    if rtc.hz == hz { return; }
    rtc.hz = hz;
    if hz < 12 {
        rtc.hz_high = false;
        rtc.hz_stage = if hz == 0 { 17 } else if hz == 4 { 16 } else { 1 };
        rtc.hz_next = rtc.now + RTC_HZ_UNIT * (rtc.hz_stage as i64);
    } else {
        rtc.hz_high = true;
        rtc.hz_stage = -1;
    }
}

// ALARM output level (true = high). Read through MFP GPIP0.
fn rtc_alarm_pin(rtc: X68kRTC&) -> bool {
    if rtc.hz_stage < 0 { return true; }
    while rtc.hz_next <= rtc.now {
        rtc.hz_high = !rtc.hz_high;
        let length: i32 = if rtc.hz == 0 { if rtc.hz_stage == 0 { 17 } else { 1 } } else if rtc.hz == 4 { 16 } else { 1 };
        rtc.hz_stage += length;
        if rtc.hz_stage == 32 { rtc.hz_stage = 0; }
        rtc.hz_next += RTC_HZ_UNIT * (length as i64);
    }
    return rtc.hz_high;
}
