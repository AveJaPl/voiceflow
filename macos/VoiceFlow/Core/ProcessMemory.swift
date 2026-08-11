import Foundation

/// RSS (Resident Set Size) bieżącego procesu — do logowania skoku pamięci po
/// załadowaniu modelu whisper.cpp (kryterium weryfikacji #5,
/// docs/plans/whisper-local-engine-pl.md): skok powinien być rzędu wielkości
/// modelu (~148 MB), nie setek MB ponad to.
enum ProcessMemory {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }
}
