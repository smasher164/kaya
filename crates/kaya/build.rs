fn main() {
    // Hybrid CRT on msvc targets: static vcruntime (not an OS contract),
    // dynamic UCRT (OS-shipped and OS-serviced). No-op elsewhere.
    static_vcruntime::metabuild();
}
