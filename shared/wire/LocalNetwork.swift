import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Adresy IPv4 tego urządzenia w sieci lokalnej i porównanie „czy jesteśmy w tej
/// samej sieci". Wspólne dla Maca i telefonu — Mac wysyła swoje adresy w
/// `hello`, telefon porównuje je ze swoimi i sam wybiera tryb.
///
/// DLACZEGO PREFIKS /24, A NIE MASKA SIECI. Interesuje nas „czy to ta sama
/// domowa sieć Wi-Fi", a nie poprawność sieciowa co do bitu. Domowe sieci to
/// praktycznie zawsze /24, a przy dzieleniu włosa na czworo (VPN, hotspot,
/// dwa pasma tego samego routera z różnymi podsieciami) i tak zostaje ręczny
/// przełącznik trybu. Zły wybór trybu nic nie psuje — obie strony rozmawiają
/// tym samym kanałem, zmienia się tylko układ ekranu.
enum LocalNetwork {

    /// Adresy IPv4 z aktywnych interfejsów, bez pętli zwrotnej i bez adresów
    /// link-local (169.254.x.x — te znaczy „nie dostałem adresu").
    static func ipv4Addresses() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: buffer)
            guard !address.hasPrefix("169.254."), address != "0.0.0.0" else { continue }
            addresses.append(address)
        }
        return addresses
    }

    /// Prefiks /24 adresu („192.168.1.20" → „192.168.1"). `nil` dla śmieci.
    static func subnet(_ address: String) -> String? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    /// Czy któryś z adresów `a` leży w tej samej podsieci co któryś z `b`.
    static func shareSubnet(_ a: [String], _ b: [String]) -> Bool {
        let left = Set(a.compactMap(subnet))
        guard !left.isEmpty else { return false }
        return b.compactMap(subnet).contains { left.contains($0) }
    }
}
