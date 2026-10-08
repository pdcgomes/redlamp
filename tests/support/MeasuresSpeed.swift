import Darwin
import Testing

/// The machine the tests run on. Compiled into every package's tests.
enum TestMachine {
    /// Whether it's a virtual machine, as CI's hosted runner is: a few cores and a paravirtual GPU
    /// shared with the host's other machines, so a time measured there is mostly the host's load.
    static let isVirtual: Bool = {
        var present: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
    }()
}

extension Trait where Self == ConditionTrait {
    /// A test whose point is how fast something runs: it runs on a Mac, and is skipped on a virtual
    /// machine such as CI's runner, where it would measure the host instead of the code. A test of
    /// behaviour doesn't take it; it waits for the behaviour, with a deadline of seconds.
    static var measuresSpeed: Self {
        .disabled(if: TestMachine.isVirtual, "a virtual machine's times measure its host, not the code")
    }
}
