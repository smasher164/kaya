//! The mac side of tools/ios/gpuprobe: the same measurement on the host,
//! one mode or all (`cargo run --release -- timing|breakdown|fills|classic`).
fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("timing") => kaya_gpuprobe::timing(),
        Some("breakdown") => kaya_gpuprobe::breakdown(),
        Some("fills") => kaya_gpuprobe::fills(),
        Some("classic") => kaya_gpuprobe::classic(),
        _ => kaya_gpuprobe::run_all(),
    }
}
