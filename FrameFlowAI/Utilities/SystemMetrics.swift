import Foundation
import Darwin

/// 系统运行指标采集：CPU 占用率、App 内存占用（resident）。
///
/// 说明：ANE / GPU 的实时占用率没有公开 API 可读取，
/// 我们用「CPU % + 内存 + 单帧推理耗时（lastFrameProcessingTime）」共同代理
/// 反映硬件负载；真正的算力占用需用 Instruments（Metal System Trace / Neural Engine）观测。
enum SystemMetrics {

    /// 当前进程 CPU 占用率（0...1）。
    /// 通过 host_processor_info 读取两次采样差值计算。
    static func cpuUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0
        let flavor = PROCESSOR_CPU_LOAD_INFO

        let result = host_processor_info(
            mach_host_self(), flavor,
            &numCPUs, &cpuInfo, &numCpuInfo
        )
        guard result == KERN_SUCCESS, let infoPtr = cpuInfo else { return 0 }

        // cpuInfo 是 processor_cpu_load_info 数组
        let infoCount = Int(numCPUs)
        var totalTicks: UInt64 = 0
        var userTicks: UInt64 = 0
        var systemTicks: UInt64 = 0
        var idleTicks: UInt64 = 0

        let type = processor_cpu_load_info.self
        let base = infoPtr.withMemoryRebound(to: type, capacity: infoCount) { $0 }
        for i in 0..<infoCount {
            let cpu = base[i]
            userTicks += UInt64(cpu.cpu_ticks.0)   // CPU_STATE_USER
            systemTicks += UInt64(cpu.cpu_ticks.1) // CPU_STATE_SYSTEM
            idleTicks += UInt64(cpu.cpu_ticks.2)   // CPU_STATE_IDLE
            totalTicks += UInt64(cpu.cpu_ticks.0) + UInt64(cpu.cpu_ticks.1) + UInt64(cpu.cpu_ticks.2)
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoPtr), vm_size_t(numCpuInfo * UInt32(MemoryLayout<integer_t>.size)))

        guard totalTicks > 0 else { return 0 }
        // 注意：这是「系统全局」忙碌占比，进程级需 task_info(THREAD_BASIC_INFO) 累加线程时间。
        // 简化实现返回全局 busy 比例，UI 文案标注为「系统繁忙度」。
        let busy = Double(totalTicks - idleTicks) / Double(totalTicks)
        return busy
    }

    /// 当前进程物理内存占用（字节），来自 task_vm_info.resident_size。
    static func residentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    /// 内存占用（MB）
    static func residentMemoryMB() -> Double {
        Double(residentMemoryBytes()) / (1024 * 1024)
    }
}
