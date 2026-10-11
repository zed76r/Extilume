import Darwin

public enum ContinuousClock {
    /// mach_continuous_time 包含睡眠时间，不能用暂停计时的 uptime 替代。
    public static func nanoseconds() throws -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { throw ClockError.invalidTimebase }
        return try convert(ticks: mach_continuous_time(), numerator: timebase.numer, denominator: timebase.denom)
    }

    static func convert(ticks: UInt64, numerator: UInt32, denominator: UInt32) throws -> UInt64 {
        guard numerator > 0, denominator > 0 else { throw ClockError.invalidTimebase }
        let product = ticks.multipliedFullWidth(by: UInt64(numerator))
        guard product.high < UInt64(denominator) else { throw ClockError.overflow }
        return UInt64(denominator).dividingFullWidth(product).quotient
    }
}

public enum ClockError: Error { case invalidTimebase, overflow }
