import Foundation

@main
enum KayaSelftestAdmissionProbe {
    static func main() {
        var failures = 0

        func expect(
            _ name: String,
            _ state: KayaSelftestAdmissionState,
            mounted: Bool,
            hasNodes: Bool,
            graceExpired: Bool,
            startupExpired: Bool = false,
            _ wantState: KayaSelftestAdmissionState,
            _ wantEffect: KayaSelftestAdmissionEffect
        ) {
            let got = kayaSelftestAdmissionTransition(
                state,
                mounted: mounted,
                hasNodes: hasNodes,
                graceExpired: graceExpired,
                startupExpired: startupExpired)
            if got.0 != wantState || got.1 != wantEffect {
                print("swiftui-selftest-admission: FAIL — \(name)")
                failures += 1
            }
        }

        expect(
            "an empty initial model keeps waiting",
            .waiting, mounted: false, hasNodes: false, graceExpired: false,
            .waiting, .none)
        expect(
            "the startup deadline rescues a batchless guest from silence",
            .waiting, mounted: false, hasNodes: false, graceExpired: false,
            startupExpired: true,
            .started, .start)
        expect(
            "the startup deadline also closes an expired-less grace wait",
            .grace, mounted: false, hasNodes: true, graceExpired: false,
            startupExpired: true,
            .started, .start)
        expect(
            "a started run ignores the late startup deadline",
            .started, mounted: false, hasNodes: false, graceExpired: false,
            startupExpired: true,
            .started, .none)
        expect(
            "an unmounted node batch arms one grace period",
            .waiting, mounted: false, hasNodes: true, graceExpired: false,
            .grace, .armGrace)
        expect(
            "another unmounted batch does not arm a second timer",
            .grace, mounted: false, hasNodes: true, graceExpired: false,
            .grace, .none)
        expect(
            "a mounted initial batch starts immediately",
            .waiting, mounted: true, hasNodes: true, graceExpired: false,
            .started, .start)
        expect(
            "a mounted surface outranks an empty node census",
            .waiting, mounted: true, hasNodes: false, graceExpired: false,
            .started, .start)
        expect(
            "a later mount wins during grace",
            .grace, mounted: true, hasNodes: true, graceExpired: false,
            .started, .start)
        expect(
            "grace expiry starts the diagnostic path",
            .grace, mounted: false, hasNodes: true, graceExpired: true,
            .started, .start)
        expect(
            "a spurious expiry cannot start an empty model",
            .waiting, mounted: false, hasNodes: false, graceExpired: true,
            .waiting, .none)
        expect(
            "started is terminal",
            .started, mounted: true, hasNodes: true, graceExpired: true,
            .started, .none)

        if failures == 0 {
            print("swiftui-selftest-admission: OK")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
