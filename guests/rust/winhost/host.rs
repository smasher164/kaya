// The windows lane's host executables (tools/lib/lanes/win.py, HOST_DIR).
macro_rules! host {
    ($($name:ident = $path:literal),* $(,)?) => {
        $(
            #[cfg(windows)]
            #[path = $path]
            mod $name;
        )*

        #[cfg(windows)]
        fn main() {
            let exe = std::env::current_exe().expect("winhost: the process names no executable");
            let stem = exe.file_stem().and_then(|s| s.to_str()).unwrap_or_default().to_owned();
            match stem.as_str() {
                $(stringify!($name) => kaya::run($name::app),)*
                other => panic!(
                    "winhost: {} runs as {other:?}, a scene {} does not carry; the windows lane copies \
                     each host to its scenes' names (tools/lib/lanes/win.py, host_refusal)",
                    exe.display(),
                    file!()
                ),
            }
        }

        #[cfg(not(windows))]
        fn main() {}
    };
}
