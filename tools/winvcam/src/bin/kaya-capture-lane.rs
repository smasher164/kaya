//! The Windows lane's synthetic devices for the capture legs
//! (docs/capture-plan.md §7, docs/HACKING.md's capture install recipe):
//!
//!   kaya-capture-lane run <ready-file> <stop-file> <max-seconds>
//!       makes the two virtual cameras (MFCreateVirtualCamera, session
//!       lifetime, current user) and plays the stereo tone into the loopback
//!       cable's input (440 Hz left, 660 Hz right: OPEN B), writes the ready
//!       file once all three run, and stops when the stop file appears or
//!       the wall-clock deadline passes, whichever is first.
//!   kaya-capture-lane list
//!       what Media Foundation and the audio endpoints show (a measurement).
//!   kaya-capture-lane frame <camera name>
//!       one frame through a source reader: its subtype, size and centre.
//!   kaya-capture-lane listen
//!       one second of the cable's output: rate, channels, each channel's tone.
//!
//! Every device it opens is named by the lane's own names: a synthetic
//! camera or the VB-Audio cable, never another input (the VM's Line In may
//! be the host's microphone).

#[cfg(not(windows))]
fn main() {
    eprintln!("kaya-capture-lane runs on Windows only");
    std::process::exit(2);
}

#[cfg(windows)]
fn main() {
    std::process::exit(win::main());
}

#[cfg(windows)]
mod win {
    use std::time::{Duration, Instant};

    use kaya_winvcam::CAMERAS;
    use windows::core::{Interface, GUID, HSTRING, PWSTR};
    use windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
    use windows::Win32::Media::Audio::*;
    use windows::Win32::Media::MediaFoundation::*;
    use windows::Win32::System::Com::*;
    use windows::Win32::System::Com::StructuredStorage::PropVariantToStringAlloc;

    pub const CAMERA_NAMES: [&str; 2] = ["kaya Synthetic Camera 1", "kaya Synthetic Camera 2"];
    pub const CABLE_RENDER: &str = "CABLE Input";
    pub const CABLE_CAPTURE: &str = "CABLE Output";
    const TONES: [f64; 2] = [440.0, 660.0];

    pub fn main() -> i32 {
        let args: Vec<String> = std::env::args().collect();
        unsafe {
            if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
                eprintln!("kaya-capture-lane: CoInitializeEx failed");
                return 1;
            }
            if let Err(e) = MFStartup(MF_VERSION, MFSTARTUP_FULL) {
                eprintln!("kaya-capture-lane: MFStartup failed: {e}");
                return 1;
            }
        }
        let result = match args.get(1).map(String::as_str) {
            Some("run") if args.len() == 5 => run(&args[2], &args[3], args[4].parse().unwrap_or(1800)),
            Some("list") => list(),
            Some("frame") if args.len() == 3 => frame(&args[2]),
            Some("listen") => listen(),
            _ => Err("usage: kaya-capture-lane run <ready> <stop> <max-seconds> | list | frame <name> | listen".to_owned()),
        };
        match result {
            Ok(()) => 0,
            Err(why) => {
                eprintln!("kaya-capture-lane: {why}");
                1
            }
        }
    }

    fn hr(what: &str) -> impl Fn(windows::core::Error) -> String + '_ {
        move |e| format!("{what}: {:#010X} {}", e.code().0 as u32, e.message())
    }

    // ---- run -----------------------------------------------------------------

    fn run(ready: &str, stop: &str, max_seconds: u64) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(max_seconds);
        let _ = std::fs::remove_file(stop);
        let _ = std::fs::remove_file(ready);
        let mut cameras = Vec::new();
        for ((clsid, _), name) in CAMERAS.iter().zip(CAMERA_NAMES) {
            let source = format!("{{{clsid:?}}}");
            let cam = unsafe {
                MFCreateVirtualCamera(
                    MFVirtualCameraType_SoftwareCameraSource,
                    MFVirtualCameraLifetime_Session,
                    MFVirtualCameraAccess_CurrentUser,
                    &HSTRING::from(name),
                    &HSTRING::from(source.as_str()),
                    None,
                )
            }
            .map_err(hr(&format!("MFCreateVirtualCamera {name} {source}")))?;
            unsafe { cam.Start(None) }.map_err(hr(&format!("IMFVirtualCamera::Start {name}")))?;
            println!("kaya-capture-lane: camera {name:?} started ({source})");
            cameras.push(cam);
        }
        let tone_stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let flag = tone_stop.clone();
        let tone = std::thread::spawn(move || {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            }
            play_tone(&flag, &started_tx)
        });
        match started_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(format)) => println!("kaya-capture-lane: tone playing into {CABLE_RENDER:?} ({format})"),
            Ok(Err(why)) => return Err(why),
            Err(_) => return Err("the tone did not start within 10 s".to_owned()),
        }
        std::fs::write(ready, format!("cameras {CAMERA_NAMES:?}, tone into {CABLE_RENDER:?}\r\n"))
            .map_err(|e| format!("writing {ready}: {e}"))?;
        println!("kaya-capture-lane: ready");
        // What this console session lists now, for a red capture leg's bundle.
        if let Err(why) = list() {
            println!("kaya-capture-lane: listing the devices failed: {why}");
        }
        let why = loop {
            if std::path::Path::new(stop).exists() {
                break "the stop file appeared";
            }
            if Instant::now() >= deadline {
                break "the wall-clock deadline passed";
            }
            if tone.is_finished() {
                break "the tone thread ended";
            }
            std::thread::sleep(Duration::from_millis(100));
        };
        println!("kaya-capture-lane: stopping: {why}");
        tone_stop.store(true, std::sync::atomic::Ordering::SeqCst);
        let tone_result = tone.join().unwrap_or_else(|_| Err("the tone thread panicked".to_owned()));
        for cam in cameras {
            unsafe {
                let _ = cam.Stop();
                let _ = cam.Shutdown();
            }
        }
        let _ = std::fs::remove_file(ready);
        let _ = std::fs::remove_file(stop);
        println!("kaya-capture-lane: stopped");
        tone_result
    }

    fn endpoint(flow: EDataFlow, wanted: &str) -> Result<IMMDevice, String> {
        unsafe {
            let enumerator: IMMDeviceEnumerator =
                CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(hr("MMDeviceEnumerator"))?;
            let all = enumerator.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE).map_err(hr("EnumAudioEndpoints"))?;
            let mut names = Vec::new();
            for i in 0..all.GetCount().map_err(hr("GetCount"))? {
                let device = all.Item(i).map_err(hr("Item"))?;
                let name = friendly(&device);
                if name.starts_with(wanted) {
                    return Ok(device);
                }
                names.push(name);
            }
            Err(format!("no active audio endpoint named {wanted:?}; the endpoints are {names:?} (is VB-CABLE installed? docs/HACKING.md)"))
        }
    }

    pub fn friendly(device: &IMMDevice) -> String {
        unsafe {
            let Ok(store) = device.OpenPropertyStore(STGM_READ) else { return String::new() };
            let Ok(value) = store.GetValue(&PKEY_Device_FriendlyName) else { return String::new() };
            PropVariantToStringAlloc(&value).ok().and_then(|p| p.to_string().ok()).unwrap_or_default()
        }
    }

    struct Mix {
        rate: u32,
        channels: u16,
        float: bool,
        bits: u16,
    }

    unsafe fn mix_of(format: *const WAVEFORMATEX) -> Mix {
        let f = unsafe { &*format };
        let mut float = f.wFormatTag == 3;
        if f.wFormatTag == 0xFFFE {
            let ext = unsafe { &*(format as *const WAVEFORMATEXTENSIBLE) };
            let sub = ext.SubFormat;
            float = sub == GUID::from_u128(0x00000003_0000_0010_8000_00aa00389b71);
        }
        Mix { rate: f.nSamplesPerSec, channels: f.nChannels, float, bits: f.wBitsPerSample }
    }

    fn play_tone(stop: &std::sync::atomic::AtomicBool, started: &std::sync::mpsc::Sender<Result<String, String>>) -> Result<(), String> {
        let go = || -> Result<(IAudioClient, IAudioRenderClient, Mix, u32), String> {
            let device = endpoint(eRender, CABLE_RENDER)?;
            unsafe {
                let client: IAudioClient = device.Activate(CLSCTX_ALL, None).map_err(hr("IAudioClient"))?;
                let format = client.GetMixFormat().map_err(hr("GetMixFormat"))?;
                let mix = mix_of(format);
                client
                    .Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 2_000_000, 0, format, None)
                    .map_err(hr("IAudioClient::Initialize"))?;
                CoTaskMemFree(Some(format as *const _));
                let frames = client.GetBufferSize().map_err(hr("GetBufferSize"))?;
                let render: IAudioRenderClient = client.GetService().map_err(hr("IAudioRenderClient"))?;
                client.Start().map_err(hr("IAudioClient::Start"))?;
                Ok((client, render, mix, frames))
            }
        };
        let (client, render, mix, frames) = match go() {
            Ok(v) => v,
            Err(why) => {
                let _ = started.send(Err(why.clone()));
                return Err(why);
            }
        };
        let _ = started.send(Ok(format!(
            "{} Hz, {} channels, {}",
            mix.rate,
            mix.channels,
            if mix.float { format!("float{}", mix.bits) } else { format!("int{}", mix.bits) }
        )));
        let mut at: u64 = 0;
        while !stop.load(std::sync::atomic::Ordering::SeqCst) {
            let padding = unsafe { client.GetCurrentPadding() }.map_err(hr("GetCurrentPadding"))?;
            let free = frames - padding;
            if free > 0 {
                unsafe {
                    let data = render.GetBuffer(free).map_err(hr("GetBuffer"))?;
                    for i in 0..free as u64 {
                        for c in 0..mix.channels as u64 {
                            let hz = TONES[(c as usize).min(1)];
                            let x = (2.0 * std::f64::consts::PI * hz * (at + i) as f64 / f64::from(mix.rate)).sin() * 0.5;
                            let slot = (i * u64::from(mix.channels) + c) as usize;
                            if mix.float && mix.bits == 32 {
                                *(data as *mut f32).add(slot) = x as f32;
                            } else if mix.bits == 16 {
                                *(data as *mut i16).add(slot) = (x * 32767.0) as i16;
                            } else {
                                *(data as *mut i32).add(slot) = (x * 2_147_483_647.0) as i32;
                            }
                        }
                    }
                    render.ReleaseBuffer(free, 0).map_err(hr("ReleaseBuffer"))?;
                }
                at += u64::from(free);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        unsafe {
            let _ = client.Stop();
        }
        Ok(())
    }

    // ---- measurements --------------------------------------------------------

    fn sources(kind: GUID) -> Result<Vec<(String, String, IMFActivate)>, String> {
        unsafe {
            let mut attributes = None;
            MFCreateAttributes(&mut attributes, 1).map_err(hr("MFCreateAttributes"))?;
            let attributes = attributes.unwrap();
            attributes.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &kind).map_err(hr("SetGUID"))?;
            let mut list = std::ptr::null_mut();
            let mut count = 0u32;
            MFEnumDeviceSources(&attributes, &mut list, &mut count).map_err(hr("MFEnumDeviceSources"))?;
            let mut out = Vec::new();
            for i in 0..count as usize {
                let Some(a) = (*list.add(i)).take() else { continue };
                let get = |key: &GUID| {
                    let mut p = PWSTR::null();
                    let mut n = 0;
                    a.GetAllocatedString(key, &mut p, &mut n).ok().map(|()| {
                        let s = p.to_string().unwrap_or_default();
                        CoTaskMemFree(Some(p.0 as *const _));
                        s
                    })
                };
                let name = get(&MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME).unwrap_or_default();
                let link = if kind == MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID {
                    get(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK)
                } else {
                    get(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_ENDPOINT_ID)
                }
                .unwrap_or_default();
                out.push((name, link, a));
            }
            CoTaskMemFree(Some(list as *const _));
            Ok(out)
        }
    }

    fn list() -> Result<(), String> {
        for (name, link, _) in sources(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)? {
            println!("video capture: {name:?} {link}");
        }
        for (name, link, _) in sources(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_GUID)? {
            println!("audio capture: {name:?} {link}");
        }
        unsafe {
            let enumerator: IMMDeviceEnumerator =
                CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(hr("MMDeviceEnumerator"))?;
            for (flow, label) in [(eRender, "render"), (eCapture, "capture")] {
                let all = enumerator.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE).map_err(hr("EnumAudioEndpoints"))?;
                for i in 0..all.GetCount().map_err(hr("GetCount"))? {
                    let device = all.Item(i).map_err(hr("Item"))?;
                    let id = device.GetId().ok().and_then(|p| p.to_string().ok()).unwrap_or_default();
                    println!("endpoint {label}: {:?} {id}", friendly(&device));
                }
            }
        }
        Ok(())
    }

    fn frame(name: &str) -> Result<(), String> {
        if !CAMERA_NAMES.iter().any(|n| name.starts_with(n)) {
            return Err(format!("{name:?} is not one of the lane's synthetic cameras {CAMERA_NAMES:?}"));
        }
        let found = sources(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)?;
        let (_, link, activate) = found
            .into_iter()
            .find(|(n, ..)| n.starts_with(name))
            .ok_or_else(|| format!("no video capture device named {name:?}"))?;
        println!("opening {name:?} {link}");
        unsafe {
            let source: IMFMediaSource = activate.ActivateObject().map_err(hr("ActivateObject"))?;
            let reader = MFCreateSourceReaderFromMediaSource(&source, None).map_err(hr("MFCreateSourceReaderFromMediaSource"))?;
            let stream = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
            let mut i = 0;
            while let Ok(t) = reader.GetNativeMediaType(stream, i) {
                let sub = t.GetGUID(&MF_MT_SUBTYPE).unwrap_or_default();
                let size = t.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or(0);
                let rate = t.GetUINT64(&MF_MT_FRAME_RATE).unwrap_or(0);
                println!("native type {i}: {sub:?} {}x{} @ {}/{}", size >> 32, size as u32, rate >> 32, rate as u32);
                i += 1;
            }
            let started = Instant::now();
            loop {
                let mut flags = 0u32;
                let mut sample = None;
                reader
                    .ReadSample(stream, 0, None, Some(&mut flags), None, Some(&mut sample))
                    .map_err(hr("ReadSample"))?;
                if let Some(sample) = sample {
                    let t = reader.GetCurrentMediaType(stream).map_err(hr("GetCurrentMediaType"))?;
                    let sub = t.GetGUID(&MF_MT_SUBTYPE).unwrap_or_default();
                    let size = t.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or(0);
                    let (w, h) = ((size >> 32) as usize, (size as u32) as usize);
                    let buffer = sample.ConvertToContiguousBuffer().map_err(hr("ConvertToContiguousBuffer"))?;
                    let mut data = std::ptr::null_mut();
                    let mut len = 0u32;
                    buffer.Lock(&mut data, None, Some(&mut len)).map_err(hr("Lock"))?;
                    let y = *data.add((h / 2) * w + w / 2);
                    let uv = data.add(w * h + (h / 4) * w + (w / 4) * 2);
                    let (u, v) = (*uv, *uv.add(1));
                    let _ = buffer.Unlock();
                    println!(
                        "frame after {} ms: subtype {sub:?} {w}x{h}, {len} bytes, centre Y {y} U {u} V {v}",
                        started.elapsed().as_millis()
                    );
                    let _ = source.Shutdown();
                    return Ok(());
                }
                if started.elapsed() > Duration::from_secs(10) {
                    let _ = source.Shutdown();
                    return Err("no frame within 10 s".to_owned());
                }
            }
        }
    }

    fn listen() -> Result<(), String> {
        let device = endpoint(eCapture, CABLE_CAPTURE)?;
        unsafe {
            let client: IAudioClient = device.Activate(CLSCTX_ALL, None).map_err(hr("IAudioClient"))?;
            let format = client.GetMixFormat().map_err(hr("GetMixFormat"))?;
            let mix = mix_of(format);
            client
                .Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 2_000_000, 0, format, None)
                .map_err(hr("Initialize"))?;
            CoTaskMemFree(Some(format as *const _));
            let capture: IAudioCaptureClient = client.GetService().map_err(hr("IAudioCaptureClient"))?;
            client.Start().map_err(hr("Start"))?;
            let channels = mix.channels as usize;
            let mut samples: Vec<Vec<f64>> = vec![Vec::new(); channels];
            let started = Instant::now();
            while started.elapsed() < Duration::from_millis(1200) {
                std::thread::sleep(Duration::from_millis(10));
                loop {
                    let mut data = std::ptr::null_mut();
                    let mut frames = 0u32;
                    let mut flags = 0u32;
                    if capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None).is_err() || frames == 0 {
                        break;
                    }
                    for i in 0..frames as usize {
                        for c in 0..channels {
                            let x = if mix.float { f64::from(*(data as *const f32).add(i * channels + c)) } else { 0.0 };
                            samples[c].push(x);
                        }
                    }
                    let _ = capture.ReleaseBuffer(frames);
                }
            }
            let _ = client.Stop();
            println!("cable output: {} Hz, {} channels, float {} bits {}", mix.rate, channels, mix.float, mix.bits);
            for (c, s) in samples.iter().enumerate() {
                let n = s.len().min(mix.rate as usize);
                let tail = &s[s.len() - n..];
                let crossings = tail.windows(2).filter(|w| w[0] < 0.0 && w[1] >= 0.0).count();
                let rms = (tail.iter().map(|x| x * x).sum::<f64>() / n.max(1) as f64).sqrt();
                println!(
                    "channel {c}: {} samples, rms {rms:.3}, {:.0} Hz",
                    s.len(),
                    crossings as f64 * f64::from(mix.rate) / n.max(1) as f64
                );
            }
        }
        Ok(())
    }

    #[allow(dead_code)]
    fn _assert_interface<T: Interface>() {}
}
