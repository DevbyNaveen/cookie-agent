//! The recorder — two channels, kept apart.
//!
//! The call comes from the system (ScreenCaptureKit, audio only); the person
//! comes from the microphone. Each is encoded to Opus in an Ogg stream and
//! posted to the gateway a minute at a time, exactly as the extension does
//! from a browser tab. (Adapted from Enkeon's desktop app,
//! thinkingrootdbcloud/apps/desktop/src-tauri/src/audio.rs.) Mixing them would throw away the one thing no
//! speaker model gives back: which side said it.
//!
//! Pages are self-contained, so a chunk cut at a page boundary appends into
//! one valid file on the gateway's spool.

use ogg::writing::{PacketWriteEndInfo, PacketWriter};
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

pub const RATE: u32 = 48_000;
pub const FRAME: usize = 960; // 20 ms at 48 kHz
const PRESKIP: u16 = 312;

/// Bytes the writer has produced and nobody has taken yet.
#[derive(Clone, Default)]
struct Sink(Arc<Mutex<Vec<u8>>>);

impl Write for Sink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Mono 48 kHz PCM → Opus packets → Ogg pages, in memory.
pub struct OggOpus {
    enc: opus::Encoder,
    writer: PacketWriter<'static, Sink>,
    sink: Sink,
    serial: u32,
    pending: Vec<f32>,
    granule: u64,
    scratch: Vec<u8>,
}

impl OggOpus {
    pub fn new(serial: u32) -> Result<Self, String> {
        let mut enc = opus::Encoder::new(RATE, opus::Channels::Mono, opus::Application::Voip).map_err(|e| format!("opus: {e}"))?;
        enc.set_bitrate(opus::Bitrate::Bits(32_000)).map_err(|e| format!("opus bitrate: {e}"))?;
        let sink = Sink::default();
        let mut writer = PacketWriter::new(sink.clone());
        // OpusHead
        let mut head = Vec::with_capacity(19);
        head.extend_from_slice(b"OpusHead");
        head.push(1); // version
        head.push(1); // channels
        head.extend_from_slice(&PRESKIP.to_le_bytes());
        head.extend_from_slice(&RATE.to_le_bytes());
        head.extend_from_slice(&0i16.to_le_bytes()); // output gain
        head.push(0); // mapping family
        writer.write_packet(head, serial, PacketWriteEndInfo::EndPage, 0).map_err(|e| format!("ogg head: {e}"))?;
        // OpusTags
        let vendor = b"cookie-recorder";
        let mut tags = Vec::new();
        tags.extend_from_slice(b"OpusTags");
        tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
        tags.extend_from_slice(vendor);
        tags.extend_from_slice(&0u32.to_le_bytes());
        writer.write_packet(tags, serial, PacketWriteEndInfo::EndPage, 0).map_err(|e| format!("ogg tags: {e}"))?;
        Ok(Self { enc, writer, sink, serial, pending: Vec::with_capacity(FRAME * 4), granule: PRESKIP as u64, scratch: vec![0u8; 4000] })
    }

    /// Feed mono samples; whole 20 ms frames are encoded as they complete.
    pub fn push(&mut self, samples: &[f32]) -> Result<(), String> {
        self.pending.extend_from_slice(samples);
        while self.pending.len() >= FRAME {
            let frame: Vec<f32> = self.pending.drain(..FRAME).collect();
            let n = self.enc.encode_float(&frame, &mut self.scratch).map_err(|e| format!("opus encode: {e}"))?;
            self.granule += FRAME as u64;
            self.writer
                .write_packet(self.scratch[..n].to_vec(), self.serial, PacketWriteEndInfo::NormalPacket, self.granule)
                .map_err(|e| format!("ogg packet: {e}"))?;
        }
        Ok(())
    }

    /// Close the current page and take every byte written so far — one
    /// chunk. `end` = the stream is over (the last page is marked).
    pub fn take(&mut self, end: bool) -> Result<Vec<u8>, String> {
        if end && !self.pending.is_empty() {
            // Pad the tail to a whole frame so the last words are not dropped.
            self.pending.resize(FRAME, 0.0);
            let frame = std::mem::take(&mut self.pending);
            let n = self.enc.encode_float(&frame, &mut self.scratch).map_err(|e| format!("opus encode: {e}"))?;
            self.granule += FRAME as u64;
            self.writer
                .write_packet(self.scratch[..n].to_vec(), self.serial, PacketWriteEndInfo::EndStream, self.granule)
                .map_err(|e| format!("ogg packet: {e}"))?;
        } else {
            // A silent frame that ends the page: cheap, and the gateway's
            // spool gets a page boundary exactly here.
            let silent = vec![0f32; FRAME];
            let n = self.enc.encode_float(&silent, &mut self.scratch).map_err(|e| format!("opus encode: {e}"))?;
            self.granule += FRAME as u64;
            let info = if end { PacketWriteEndInfo::EndStream } else { PacketWriteEndInfo::EndPage };
            self.writer
                .write_packet(self.scratch[..n].to_vec(), self.serial, info, self.granule)
                .map_err(|e| format!("ogg packet: {e}"))?;
        }
        Ok(std::mem::take(&mut *self.sink.0.lock().unwrap()))
    }
}

/// Peak of one buffer, 0..1 — the level meter.
pub fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0f32, |m, s| m.max(s.abs())).min(1.0)
}

/// Linear resample to 48 kHz. Good enough for speech; the microphone on
/// most Macs already runs at 48 kHz and this is then a copy.
pub fn to_48k(input: &[f32], rate: u32) -> Vec<f32> {
    if rate == RATE || input.is_empty() {
        return input.to_vec();
    }
    let ratio = rate as f64 / RATE as f64;
    let n = ((input.len() as f64) / ratio).floor() as usize;
    (0..n)
        .map(|i| {
            let pos = i as f64 * ratio;
            let j = pos.floor() as usize;
            let t = (pos - j as f64) as f32;
            let a = input[j.min(input.len() - 1)];
            let b = input[(j + 1).min(input.len() - 1)];
            a + (b - a) * t
        })
        .collect()
}

/// Downmix interleaved frames to mono.
pub fn mono(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    interleaved.chunks(channels).map(|c| c.iter().sum::<f32>() / channels as f32).collect()
}

pub struct Handles {
    pub stop: Arc<AtomicBool>,
    /// f32 bits of the microphone's last peak.
    pub level: Arc<AtomicU32>,
    pub threads: Vec<std::thread::JoinHandle<()>>,
}

/// Start both captures. Each delivers 48 kHz mono chunks on its channel.
/// The system capture is optional: a Mac with no permission for it records
/// the microphone alone, and says so.
pub fn start(mic_tx: mpsc::Sender<Vec<f32>>, sys_tx: mpsc::Sender<Vec<f32>>) -> Result<(Handles, Option<String>), String> {
    let stop = Arc::new(AtomicBool::new(false));
    let level = Arc::new(AtomicU32::new(0));
    let mut threads = Vec::new();

    // The microphone — cpal owns the stream on its own thread.
    {
        let stop = stop.clone();
        let level = level.clone();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
        threads.push(std::thread::spawn(move || {
            use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
            let host = cpal::default_host();
            let Some(device) = host.default_input_device() else {
                let _ = ready_tx.send(Err("no microphone found".into()));
                return;
            };
            let config = match device.default_input_config() {
                Ok(c) => c,
                Err(e) => {
                    let _ = ready_tx.send(Err(format!("microphone: {e}")));
                    return;
                }
            };
            let rate: u32 = config.sample_rate();
            let channels = config.channels() as usize;
            let stream = device.build_input_stream(
                &config.into(),
                move |data: &[f32], _| {
                    let m = mono(data, channels);
                    let m = to_48k(&m, rate);
                    level.store(peak(&m).to_bits(), Ordering::Relaxed);
                    let _ = mic_tx.send(m);
                },
                |e| crate::emit(&crate::error_line(&format!("microphone stream: {e}"))),
                None,
            );
            let stream = match stream {
                Ok(s) => s,
                Err(e) => {
                    let _ = ready_tx.send(Err(format!("microphone: {e}")));
                    return;
                }
            };
            if let Err(e) = stream.play() {
                let _ = ready_tx.send(Err(format!("microphone: {e}")));
                return;
            }
            let _ = ready_tx.send(Ok(()));
            while !stop.load(Ordering::Relaxed) {
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            drop(stream);
        }));
        ready_rx.recv().map_err(|_| "microphone thread died".to_string())??;
    }

    // The call — what the speakers play, from ScreenCaptureKit, sound only.
    let sys_warning = match sys::start(sys_tx, stop.clone()) {
        Ok(t) => {
            threads.push(t);
            None
        }
        Err(e) => Some(e),
    };

    Ok((Handles { stop, level, threads }, sys_warning))
}

mod sys {
    //! ScreenCaptureKit, sound only, through the objc2 bindings. The
    //! stream wants a display filter even for audio; we ask for a
    //! two-pixel frame once a second and never look at it.
    use super::*;
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::{NSObjectProtocol, ProtocolObject};
    use objc2::{define_class, msg_send, AnyThread, DefinedClass};
    use objc2_core_media::CMSampleBuffer;
    use objc2_foundation::{NSArray, NSError, NSObject};
    use objc2_screen_capture_kit::{SCContentFilter, SCShareableContent, SCStream, SCStreamConfiguration, SCStreamOutput, SCStreamOutputType};
    use std::ffi::c_void;

    #[repr(C)]
    struct AudioBuffer {
        number_channels: u32,
        data_byte_size: u32,
        data: *mut c_void,
    }
    #[repr(C)]
    struct AudioBufferList {
        number_buffers: u32,
        buffers: [AudioBuffer; 8],
    }

    #[link(name = "CoreMedia", kind = "framework")]
    extern "C" {
        fn CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sbuf: *const c_void,
            size_needed_out: *mut usize,
            list_out: *mut AudioBufferList,
            list_size: usize,
            structure_allocator: *const c_void,
            block_allocator: *const c_void,
            flags: u32,
            block_buffer_out: *mut *const c_void,
        ) -> i32;
        fn CFRelease(cf: *const c_void);
    }
    const ASSURE_16_BYTE_ALIGNMENT: u32 = 1;

    /// The mono 48 kHz samples in one buffer. SCK hands out 32-bit float
    /// PCM: one buffer per channel (planar) or one interleaved buffer.
    fn samples_of(sample: &CMSampleBuffer) -> Vec<f32> {
        let mut list = AudioBufferList { number_buffers: 0, buffers: std::array::from_fn(|_| AudioBuffer { number_channels: 0, data_byte_size: 0, data: std::ptr::null_mut() }) };
        let mut block: *const c_void = std::ptr::null();
        let status = unsafe {
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample as *const CMSampleBuffer as *const c_void,
                std::ptr::null_mut(),
                &mut list,
                std::mem::size_of::<AudioBufferList>(),
                std::ptr::null(),
                std::ptr::null(),
                ASSURE_16_BYTE_ALIGNMENT,
                &mut block,
            )
        };
        if status != 0 || block.is_null() {
            return Vec::new();
        }
        let n = (list.number_buffers as usize).min(8);
        let floats = |b: &AudioBuffer| -> &[f32] {
            if b.data.is_null() {
                return &[];
            }
            unsafe { std::slice::from_raw_parts(b.data as *const f32, (b.data_byte_size / 4) as usize) }
        };
        let out: Vec<f32> = if n >= 2 {
            let chans: Vec<&[f32]> = list.buffers[..n].iter().map(floats).collect();
            let len = chans.iter().map(|c| c.len()).min().unwrap_or(0);
            (0..len).map(|i| chans.iter().map(|c| c[i]).sum::<f32>() / chans.len() as f32).collect()
        } else if n == 1 {
            let b = &list.buffers[0];
            mono(floats(b), b.number_channels.max(1) as usize)
        } else {
            Vec::new()
        };
        unsafe { CFRelease(block) };
        out
    }

    struct Ivars {
        tx: mpsc::Sender<Vec<f32>>,
    }

    define_class!(
        #[unsafe(super(NSObject))]
        #[thread_kind = AnyThread]
        #[name = "TRAudioOutput"]
        #[ivars = Ivars]
        struct Output;

        unsafe impl NSObjectProtocol for Output {}

        unsafe impl SCStreamOutput for Output {
            #[unsafe(method(stream:didOutputSampleBuffer:ofType:))]
            fn did_output(&self, _stream: &SCStream, sample: &CMSampleBuffer, ty: SCStreamOutputType) {
                if ty != SCStreamOutputType::Audio {
                    return;
                }
                let out = samples_of(sample);
                if !out.is_empty() {
                    let _ = self.ivars().tx.send(out);
                }
            }
        }
    );

    impl Output {
        fn new(tx: mpsc::Sender<Vec<f32>>) -> Retained<Self> {
            let this = Self::alloc().set_ivars(Ivars { tx });
            unsafe { msg_send![super(this), init] }
        }
    }

    /// Objective-C objects crossing to our thread. ScreenCaptureKit's
    /// objects are documented thread-safe; the compiler cannot know that.
    struct Crossing<T>(T);
    unsafe impl<T> Send for Crossing<T> {}

    fn err_text(e: *mut NSError) -> String {
        if e.is_null() {
            return String::new();
        }
        unsafe { (*e).localizedDescription().to_string() }
    }

    pub fn start(tx: mpsc::Sender<Vec<f32>>, stop: Arc<AtomicBool>) -> Result<std::thread::JoinHandle<()>, String> {
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
        let t = std::thread::spawn(move || {
            // What can be captured — the call that asks for permission.
            let (ctx, crx) = mpsc::channel::<Result<Crossing<Retained<SCShareableContent>>, String>>();
            let block = RcBlock::new(move |content: *mut SCShareableContent, err: *mut NSError| {
                let r = if content.is_null() {
                    Err(format!("system audio: {}", err_text(err)))
                } else {
                    Ok(Crossing(unsafe { Retained::retain(content) }.expect("content")))
                };
                let _ = ctx.send(r);
            });
            unsafe { SCShareableContent::getShareableContentWithCompletionHandler(&block) };
            let content = match crx.recv_timeout(Duration::from_secs(20)) {
                Ok(Ok(c)) => c.0,
                Ok(Err(e)) => {
                    let _ = ready_tx.send(Err(e));
                    return;
                }
                Err(_) => {
                    let _ = ready_tx.send(Err("system audio: no answer from ScreenCaptureKit".into()));
                    return;
                }
            };
            let displays = unsafe { content.displays() };
            let Some(display) = displays.iter().next() else {
                let _ = ready_tx.send(Err("system audio: no display".into()));
                return;
            };
            let (stream, _output) = unsafe {
                let filter = SCContentFilter::initWithDisplay_excludingWindows(SCContentFilter::alloc(), &display, &NSArray::new());
                let config = SCStreamConfiguration::new();
                config.setCapturesAudio(true);
                config.setExcludesCurrentProcessAudio(true);
                config.setSampleRate(RATE as isize);
                config.setChannelCount(2);
                config.setWidth(2);
                config.setHeight(2);
                config.setShowsCursor(false);
                let stream = SCStream::initWithFilter_configuration_delegate(SCStream::alloc(), &filter, &config, None);
                let output = Output::new(tx);
                if let Err(e) = stream.addStreamOutput_type_sampleHandlerQueue_error(ProtocolObject::from_ref(&*output), SCStreamOutputType::Audio, None) {
                    let _ = ready_tx.send(Err(format!("system audio: {}", e.localizedDescription())));
                    return;
                }
                (stream, output)
            };
            let (stx, srx) = mpsc::channel::<String>();
            let started = RcBlock::new(move |err: *mut NSError| {
                let _ = stx.send(err_text(err));
            });
            unsafe { stream.startCaptureWithCompletionHandler(Some(&started)) };
            match srx.recv_timeout(Duration::from_secs(20)) {
                Ok(e) if e.is_empty() => {}
                Ok(e) => {
                    let _ = ready_tx.send(Err(format!("system audio: {e}")));
                    return;
                }
                Err(_) => {
                    let _ = ready_tx.send(Err("system audio: capture did not start".into()));
                    return;
                }
            }
            let _ = ready_tx.send(Ok(()));
            while !stop.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(100));
            }
            let (etx, erx) = mpsc::channel::<()>();
            let ended = RcBlock::new(move |_err: *mut NSError| {
                let _ = etx.send(());
            });
            unsafe { stream.stopCaptureWithCompletionHandler(Some(&ended)) };
            let _ = erx.recv_timeout(Duration::from_secs(5));
        });
        ready_rx.recv().map_err(|_| "system audio thread died".to_string())??;
        Ok(t)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ogg_opus_stream_starts_with_its_headers_and_cuts_on_page_boundaries() {
        let mut o = OggOpus::new(7).unwrap();
        o.push(&vec![0.0; FRAME * 3]).unwrap();
        let first = o.take(false).unwrap();
        assert_eq!(&first[0..4], b"OggS");
        assert!(first.windows(8).any(|w| w == b"OpusHead"));
        assert!(first.windows(8).any(|w| w == b"OpusTags"));
        o.push(&vec![0.0; FRAME]).unwrap();
        let second = o.take(true).unwrap();
        assert_eq!(&second[0..4], b"OggS", "every chunk begins on a page");
        // The end-of-stream flag on the last page's header.
        let last_page = second.windows(4).rposition(|w| w == b"OggS").unwrap();
        assert_eq!(second[last_page + 5] & 0x04, 0x04);
    }

    /// The chain the gateway will feed to ffmpeg and Transcribe: a real
    /// Ogg/Opus file, decoded by the ffprobe on this machine. Skips where
    /// there is none.
    #[test]
    fn an_ogg_opus_file_decodes_with_ffprobe() {
        let Ok(probe) = std::process::Command::new("ffprobe").arg("-version").output() else { return };
        if !probe.status.success() {
            return;
        }
        let mut o = OggOpus::new(3).unwrap();
        // Two seconds of a 440 Hz tone, chunked the way a meeting is.
        let tone: Vec<f32> = (0..RATE as usize * 2).map(|i| (i as f32 * 440.0 * 2.0 * std::f32::consts::PI / RATE as f32).sin() * 0.3).collect();
        let mut file = Vec::new();
        for half in tone.chunks(RATE as usize) {
            o.push(half).unwrap();
            file.extend(o.take(false).unwrap());
        }
        file.extend(o.take(true).unwrap());
        let path = std::env::temp_dir().join("tr-desktop-test.ogg");
        std::fs::write(&path, &file).unwrap();
        let out = std::process::Command::new("ffprobe")
            .args(["-v", "error", "-show_entries", "stream=codec_name,sample_rate,channels:format=duration", "-of", "default=nw=1", path.to_str().unwrap()])
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(text.contains("codec_name=opus"), "{text}");
        assert!(text.contains("sample_rate=48000"), "{text}");
        assert!(text.contains("channels=1"), "{text}");
        let dur: f64 = text.lines().find_map(|l| l.strip_prefix("duration=")).and_then(|d| d.parse().ok()).unwrap_or(0.0);
        assert!((dur - 2.0).abs() < 0.2, "duration {dur}");
    }

    /// Read the chunks back with the ogg crate as the gateway's spool sees
    /// them (appended): the two header packets on their own pages at
    /// granule 0, then audio whose granule grows by 960 per 20 ms frame
    /// from the preskip, and exactly one end-of-stream.
    #[test]
    fn appended_chunks_decode_back_as_one_ogg_opus_stream() {
        use ogg::reading::PacketReader;
        let mut o = OggOpus::new(42).unwrap();
        let mut file = Vec::new();
        for _ in 0..3 {
            o.push(&vec![0.1; FRAME * 10 + 17]).unwrap();
            let c = o.take(false).unwrap();
            assert_eq!(&c[..4], b"OggS", "every chunk begins on a page");
            file.extend(c);
        }
        file.extend(o.take(true).unwrap());

        let mut r = PacketReader::new(std::io::Cursor::new(&file));
        let head = r.read_packet_expected().unwrap();
        assert!(head.data.starts_with(b"OpusHead"));
        assert_eq!(head.data.len(), 19);
        assert_eq!(head.data[9], 1, "mono");
        assert_eq!(u16::from_le_bytes([head.data[10], head.data[11]]), PRESKIP);
        assert_eq!(u32::from_le_bytes(head.data[12..16].try_into().unwrap()), RATE);
        assert!(head.first_in_stream() && head.last_in_page());
        assert_eq!(head.absgp_page(), 0);
        let tags = r.read_packet_expected().unwrap();
        assert!(tags.data.starts_with(b"OpusTags"));
        assert!(tags.last_in_page());
        assert_eq!(tags.absgp_page(), 0);

        let (mut packets, mut last_gp, mut eos) = (0u64, 0u64, false);
        while let Some(p) = r.read_packet().unwrap() {
            assert_eq!(p.stream_serial(), 42);
            assert!(!eos, "nothing after end-of-stream");
            assert!(p.absgp_page() >= last_gp, "granule never goes back");
            last_gp = p.absgp_page();
            packets += 1;
            eos = p.last_in_stream();
        }
        assert!(eos);
        // 3 × (10 frames + 17 samples) = 30 whole frames + 51 samples padded
        // into one tail frame, plus one silent page-closing frame per cut.
        assert_eq!(packets, 30 + 1 + 3);
        assert_eq!(last_gp, PRESKIP as u64 + packets * FRAME as u64);
    }

    #[test]
    fn resample_and_downmix_do_the_arithmetic() {
        assert_eq!(mono(&[1.0, 3.0, 2.0, 4.0], 2), vec![2.0, 3.0]);
        assert_eq!(to_48k(&[1.0, 2.0, 3.0], 48_000), vec![1.0, 2.0, 3.0]);
        let up = to_48k(&[0.0; 441], 44_100);
        assert_eq!(up.len(), 480);
        assert_eq!(peak(&[0.1, -0.7, 0.3]), 0.7);
    }
}
