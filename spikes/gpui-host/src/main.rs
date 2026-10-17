// GPUI substrate spike for Weaver. Measures what one process hosting N
// desktop-widget-shaped windows costs, to compare against docs/m4a-results.md
// and docs/m4b-results.md.
//
//   gpui-spike --mode clock|viz|canvas --windows N [--fps 60] [--slot K] [--desktop]
//
// --desktop applies weaver's desktop-layer recipe to GPUI's HWND from outside
// (runtime/native-sdk webview2_host.cpp attachDesktopWindow): WS_EX_NOACTIVATE
// + WS_EX_TOOLWINDOW, SetParent to the wallpaper WorkerW when the classic
// top-level WorkerW exists, then HWND_BOTTOM. Windows only; a no-op elsewhere.
//
// clock: 220x90 card, text changes once per second (weaver clock analogue).
// viz:   480x320 card, title text + 32 flex-div bars relaid out every frame.
// canvas: port of weaver examples/m4b-synthetic (card + 2 texts + 28 bars
//         drawn with paint_quad). The bar math runs in Rust here, in JS in Weaver.
//
// Frame counts are render() calls per window, printed every 5 s to stdout as
// the total plus the slowest and fastest window.

use std::{
    sync::{
        OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use gpui::{
    App, Bounds, Context, Window, WindowBackgroundAppearance, WindowBounds, WindowKind,
    WindowOptions, canvas, div, fill, point, prelude::*, px, rgba, size,
};
use gpui_platform::application;

// One render counter per window, sized from --windows at startup.
static FRAMES: OnceLock<Vec<AtomicU64>> = OnceLock::new();

fn frames() -> &'static [AtomicU64] {
    FRAMES.get().expect("frame counters are created before any window")
}

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Clock,
    Viz,
    Canvas,
}

struct Widget {
    index: usize,
    mode: Mode,
    seed: f32,
    started: Instant,
}

impl Widget {
    fn new(index: usize, mode: Mode, seed: f32, fps: u32, cx: &mut Context<Self>) -> Self {
        let tick = match mode {
            Mode::Clock => Duration::from_secs(1),
            Mode::Viz | Mode::Canvas => Duration::from_secs_f64(1.0 / fps as f64),
        };
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(tick).await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        })
        .detach();
        Self {
            index,
            mode,
            seed,
            started: Instant::now(),
        }
    }
}

fn clock_text() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let (h, m, s) = ((secs / 3600) % 24, (secs / 60) % 60, secs % 60);
    format!("{h:02}:{m:02}:{s:02}")
}

impl Render for Widget {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        frames()[self.index].fetch_add(1, Ordering::Relaxed);
        let card = div()
            .size_full()
            .flex()
            .flex_col()
            .p_5()
            .gap_2()
            .rounded_xl()
            .bg(rgba(0x101418d9))
            .text_color(rgba(0xf2f4f8ff));

        match self.mode {
            Mode::Clock => card
                .justify_center()
                .items_center()
                .child(div().text_3xl().child(clock_text()))
                .child(div().text_xs().text_color(rgba(0xf2f4f899)).child("UTC")),
            Mode::Viz => {
                let t = self.started.elapsed().as_secs_f32();
                card.child(div().text_lg().child("Now playing"))
                    .child(
                        div().text_xs().text_color(rgba(0xf2f4f899)).child("GPUI spike"),
                    )
                    .child(
                        div()
                            .flex_1()
                            .flex()
                            .flex_row()
                            .items_end()
                            .gap_1()
                            .children((0..32).map(|i| {
                                let f = i as f32;
                                let v = 0.5
                                    + 0.5 * (t * (1.3 + f * 0.11) + f * 0.7 + self.seed).sin();
                                div()
                                    .flex_1()
                                    .h(px(8.0 + v * 200.0))
                                    .rounded_t_sm()
                                    .bg(rgba(0x7aa2f7ff))
                            })),
                    )
            }
            Mode::Canvas => {
                // Same math as examples/m4b-synthetic/widget.tsx.
                const BARS: usize = 28;
                let step = (self.started.elapsed().as_secs_f32() * 60.0) as usize;
                div()
                    .size_full()
                    .flex()
                    .flex_col()
                    .p_4()
                    .gap_3()
                    .rounded_2xl()
                    .bg(rgba(0x10131cd9))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .justify_between()
                            .items_center()
                            .text_xs()
                            .child(
                                div()
                                    .text_color(rgba(0x94a3b8ff))
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child("SPECTRUM · SYNTHETIC 60"),
                            )
                            .child(div().text_color(rgba(0x64748bff)).child("GPUI")),
                    )
                    .child(
                        canvas(
                            |_, _, _| {},
                            move |bounds, _, window, _| {
                                let gap = 3.0;
                                let (cw, ch) = (f32::from(bounds.size.width), f32::from(bounds.size.height));
                                let w = (cw - gap * (BARS as f32 - 1.0)) / BARS as f32;
                                for i in 0..BARS {
                                    let hue = i as f32 / (BARS as f32 - 1.0);
                                    let red = (90.0 + 55.0 * (1.0 - hue)).round() as u32;
                                    let blue = (190.0 + 55.0 * hue).round() as u32;
                                    let color = rgba((red << 24) | (0x78 << 16) | (blue << 8) | 0xff);
                                    let phase = ((step * 7 + i * 37) % 97) as f32 / 96.0;
                                    let h = 8.0 + phase * (ch - 8.0);
                                    let origin = bounds.origin + point(px(i as f32 * (w + gap)), px(ch - h));
                                    window.paint_quad(
                                        fill(Bounds::new(origin, size(px(w), px(h))), color)
                                            .corner_radii(px(w / 2.0)),
                                    );
                                }
                            },
                        )
                        .w(px(448.0))
                        .h(px(265.0)),
                    )
            }
        }
    }
}

fn main() {
    let mut mode = Mode::Clock;
    let mut windows = 1u32;
    let mut fps = 60u32;
    let mut first_slot = 0u32;
    let mut desktop = false;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--mode" => {
                mode = match args.next().as_deref() {
                    Some("viz") => Mode::Viz,
                    Some("canvas") => Mode::Canvas,
                    _ => Mode::Clock,
                }
            }
            "--windows" => windows = args.next().unwrap().parse().unwrap(),
            "--fps" => fps = args.next().unwrap().parse().unwrap(),
            "--slot" => first_slot = args.next().unwrap().parse().unwrap(),
            "--desktop" => desktop = true,
            other => panic!("unknown arg {other}"),
        }
    }
    let (w, h) = match mode {
        Mode::Clock => (220.0, 90.0),
        Mode::Viz | Mode::Canvas => (480.0, 320.0),
    };

    FRAMES
        .set((0..windows).map(|_| AtomicU64::new(0)).collect())
        .expect("frame counters are created once");
    application().run(move |cx: &mut App| {
        // Gapless tiling on a 1920x1080 primary so every window is fully visible.
        let cols = (1920.0 / w) as u32;
        for i in 0..windows {
            let slot = first_slot + i;
            let origin = point(
                px((slot % cols) as f32 * w),
                px((slot / cols) as f32 * h),
            );
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        origin,
                        size(px(w), px(h)),
                    ))),
                    titlebar: None,
                    focus: false,
                    show: true,
                    kind: WindowKind::Normal,
                    is_resizable: false,
                    is_minimizable: false,
                    window_background: WindowBackgroundAppearance::Transparent,
                    inactive_frame_interval: None,
                    ..Default::default()
                },
                |window, cx| {
                    #[cfg(windows)]
                    if desktop {
                        desktop_layer::attach(window);
                    }
                    cx.new(|cx| Widget::new(i as usize, mode, i as f32 * 1.7, fps, cx))
                },
            )
            .unwrap();
        }

        cx.spawn(async move |cx| {
            let n = windows as usize;
            let read = || frames().iter().map(|f| f.load(Ordering::Relaxed)).collect::<Vec<_>>();
            let mut last = read();
            let mut at = Instant::now();
            loop {
                cx.background_executor().timer(Duration::from_secs(5)).await;
                let now = read();
                let dt = at.elapsed().as_secs_f64();
                let rates: Vec<f64> = (0..n).map(|i| (now[i] - last[i]) as f64 / dt).collect();
                let min = rates.iter().cloned().fold(f64::MAX, f64::min);
                let max = rates.iter().cloned().fold(0.0, f64::max);
                println!(
                    "renders/s total={:.1} per_window min={:.1} max={:.1}",
                    rates.iter().sum::<f64>(),
                    min,
                    max
                );
                last = now;
                at = Instant::now();
            }
        })
        .detach();
    });
}

#[cfg(windows)]
mod desktop_layer {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use windows_sys::Win32::{
        Foundation::{HWND, LPARAM, POINT, RECT},
        Graphics::Gdi::ScreenToClient,
        UI::WindowsAndMessaging::*,
    };

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    unsafe extern "system" fn find_worker(top: HWND, out: LPARAM) -> i32 {
        unsafe {
            let shell = FindWindowExW(top, std::ptr::null_mut(), wide("SHELLDLL_DefView").as_ptr(), std::ptr::null());
            if shell.is_null() {
                return 1;
            }
            let worker = FindWindowExW(std::ptr::null_mut(), top, wide("WorkerW").as_ptr(), std::ptr::null());
            if worker.is_null() {
                return 1;
            }
            *(out as *mut HWND) = worker;
            0
        }
    }

    pub fn attach(window: &gpui::Window) {
        let Ok(handle) = HasWindowHandle::window_handle(window) else { return };
        let RawWindowHandle::Win32(h) = handle.as_raw() else { return };
        let hwnd = h.hwnd.get() as HWND;
        unsafe {
            let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex | (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) as isize);
            let progman = FindWindowW(wide("Progman").as_ptr(), std::ptr::null());
            if !progman.is_null() {
                let mut ignored = 0usize;
                SendMessageTimeoutW(progman, 0x052C, 0, 0, SMTO_NORMAL, 1000, &mut ignored);
            }
            let mut worker: HWND = std::ptr::null_mut();
            EnumWindows(Some(find_worker), &mut worker as *mut HWND as LPARAM);
            let mut frame = RECT { left: 0, top: 0, right: 0, bottom: 0 };
            GetWindowRect(hwnd, &mut frame);
            let mut origin = POINT { x: frame.left, y: frame.top };
            if worker.is_null() {
                // Windows 11 26200 moved the wallpaper WorkerW under Progman;
                // this spike does not parent there. Bottom z-order only.
                eprintln!("desktop_layer: no top-level wallpaper WorkerW; HWND_BOTTOM only");
            } else {
                ScreenToClient(worker, &mut origin);
                SetParent(hwnd, worker);
            }
            SetWindowPos(hwnd, HWND_BOTTOM, origin.x, origin.y, 0, 0,
                SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
    }
}
