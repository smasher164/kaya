//! The voice output on WinUI (docs/capture-plan.md §5): WASAPI shared-mode
//! render on the default COMMUNICATIONS endpoint, the stream marked
//! AudioCategory_Communications, the path Windows' communications processing
//! (its echo canceller) takes as the far end. A render thread of its own,
//! event-driven, pulls the core's queue at the mix format the engine gives.

use super::*;
use crate::protocol::{VoiceId, VoiceRoute};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use windows::Win32::Media::Audio::{
    eCommunications, eRender, AudioCategory_Communications, AudioClientProperties, IAudioClient2, IAudioRenderClient,
    IMMDeviceEnumerator, MMDeviceEnumerator, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
    AUDCLNT_STREAMOPTIONS_NONE, WAVEFORMATEX, WAVEFORMATEXTENSIBLE,
};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED};
use windows::Win32::System::Threading::{CreateEventW, WaitForSingleObject};

/// The KSDATAFORMAT_SUBTYPE_IEEE_FLOAT GUID's bytes, read without the
/// kernel-streaming feature.
const IEEE_FLOAT: u128 = 0x00000003_0000_0010_8000_00aa00389b71;

thread_local! {
    static STOPS: std::cell::RefCell<HashMap<u64, Arc<AtomicBool>>> = std::cell::RefCell::new(HashMap::new());
}

fn report(core: &mut CoreState, id: u64, route: VoiceRoute, detail: String) {
    for occ in core.scene.voice_route(VoiceId(id), route, detail) {
        core.occurrences.send(occ);
    }
}

pub(super) fn create(id: u64) {
    let stop = Arc::new(AtomicBool::new(false));
    STOPS.with_borrow_mut(|s| s.insert(id, stop.clone()));
    let spawned = std::thread::Builder::new().name(format!("kaya voice {id}")).spawn(move || {
        if let Err(why) = render(id, &stop) {
            media::post(move |core| report(core, id, VoiceRoute::Failed, why));
        }
    });
    if let Err(e) = spawned {
        let why = format!("the render thread would not start: {e}");
        media::post(move |core| report(core, id, VoiceRoute::Failed, why));
    }
}

pub(super) fn release(id: u64) {
    if let Some(stop) = STOPS.with_borrow_mut(|s| s.remove(&id)) {
        stop.store(true, Ordering::Release);
    }
}

fn render(id: u64, stop: &AtomicBool) -> Result<(), String> {
    fn at(what: &'static str) -> impl Fn(windows_core::Error) -> String {
        move |e| format!("{what}: {e}")
    }
    // SAFETY: COM on this thread, which owns every interface below.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let devices: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(at("no device enumerator"))?;
        let device = devices
            .GetDefaultAudioEndpoint(eRender, eCommunications)
            .map_err(at("no default communications render endpoint"))?;
        let name = device.GetId().ok().map(|p| {
            let s = p.to_string().unwrap_or_default();
            CoTaskMemFree(Some(p.0 as *const _));
            s
        });
        let client: IAudioClient2 = device.Activate(CLSCTX_ALL, None).map_err(at("the endpoint gave no IAudioClient2"))?;
        let properties = AudioClientProperties {
            cbSize: std::mem::size_of::<AudioClientProperties>() as u32,
            bIsOffload: false.into(),
            eCategory: AudioCategory_Communications,
            Options: AUDCLNT_STREAMOPTIONS_NONE,
        };
        client.SetClientProperties(&properties).map_err(at("the Communications category was refused"))?;
        let mix = client.GetMixFormat().map_err(at("no mix format"))?;
        let format: WAVEFORMATEX = *mix;
        let float = format.wFormatTag == 3
            || (format.wFormatTag == 0xFFFE && {
                let ext = &*(mix as *const WAVEFORMATEXTENSIBLE);
                let g = ext.SubFormat;
                g.to_u128() == IEEE_FLOAT
            });
        let (rate, channels, bits) = (format.nSamplesPerSec, u32::from(format.nChannels), format.wBitsPerSample);
        if !(float && bits == 32) && bits != 16 {
            CoTaskMemFree(Some(mix as *const _));
            return Err(format!("the mix format is {bits}-bit {} at {rate} Hz, which kaya does not write", if float { "float" } else { "integer" }));
        }
        let initialized = client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 2_000_000, 0, mix, None);
        CoTaskMemFree(Some(mix as *const _));
        initialized.map_err(at("the stream would not initialize"))?;
        let event = CreateEventW(None, false, false, None).map_err(at("no event"))?;
        client.SetEventHandle(event).map_err(at("the stream took no event"))?;
        let frames = client.GetBufferSize().map_err(at("no buffer size"))?;
        let out: IAudioRenderClient = client.GetService().map_err(at("no render client"))?;
        client.Start().map_err(at("the stream would not start"))?;
        let detail = format!(
            "WASAPI shared render on the default communications endpoint {}, AudioCategory_Communications, {} {bits}-bit x{channels} at {rate} Hz",
            name.as_deref().unwrap_or("(unnamed)"),
            if float { "float" } else { "integer" }
        );
        media::post(move |core| report(core, id, VoiceRoute::Voice, detail));
        let mut pulled = vec![0f32; frames as usize * channels as usize];
        while !stop.load(Ordering::Acquire) {
            WaitForSingleObject(event, 200);
            let Ok(padding) = client.GetCurrentPadding() else { break };
            let free = frames.saturating_sub(padding);
            if free == 0 {
                continue;
            }
            let Ok(buffer) = out.GetBuffer(free) else { break };
            let n = free as usize * channels as usize;
            crate::farend::pull(VoiceId(id), rate, channels, &mut pulled[..n]);
            if float {
                std::ptr::copy_nonoverlapping(pulled.as_ptr(), buffer as *mut f32, n);
            } else {
                let dst = std::slice::from_raw_parts_mut(buffer as *mut i16, n);
                for (d, s) in dst.iter_mut().zip(&pulled[..n]) {
                    *d = (s * 32767.0).round().clamp(-32768.0, 32767.0) as i16;
                }
            }
            let _ = out.ReleaseBuffer(free, 0);
        }
        let _ = client.Stop();
        let _ = windows::Win32::Foundation::CloseHandle(event);
    }
    Ok(())
}
