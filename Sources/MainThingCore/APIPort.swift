/// Which port the API listens on. 80 first, so URLs need no port, then 7788 when 80 is taken
/// or refused. An override (`MAINTHING_PORT` in the environment, or `port` in the app's defaults)
/// is tried alone.
public enum APIPort {
    public static let preferred: UInt16 = 80
    public static let fallback: UInt16 = 7788

    /// The ports to try, in order.
    public static func candidates(environment: String?, defaultsValue: Int) -> [UInt16] {
        if let override = valid(environment.flatMap(Int.init)) { return [override] }
        if let override = valid(defaultsValue) { return [override] }
        return [preferred, fallback]
    }

    private static func valid(_ value: Int?) -> UInt16? {
        guard let value, (1...65535).contains(value) else { return nil }
        return UInt16(value)
    }
}
