use std::env;
use std::io::{self, Read, Write};
use std::mem;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use crossbeam_channel::{select, tick, unbounded, Receiver, Sender};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, size as terminal_size};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use signal_hook::consts::signal::SIGWINCH;
use signal_hook::iterator::Signals;
use vte::{Params, Perform};

const SECONDARY_ROWS: u16 = 9;
const DEFAULT_TOTAL_ROWS: u16 = 32;
const DEFAULT_MAIN_ROWS: u16 = DEFAULT_TOTAL_ROWS - SECONDARY_ROWS - 1;
const FLOOD_BATCH: usize = 1024 * 1024;
const BACKGROUND_FLUSH: Duration = Duration::from_millis(16);
const FLOOD_FLUSH: Duration = Duration::from_millis(8);
const SCROLLBACK_LINES: usize = 10_000;
const WHEEL_SCROLL_LINES: usize = 3;

#[derive(Debug, Parser)]
#[command(author, version, about)]
struct Args {
    #[arg(long)]
    main: String,
    #[arg(long)]
    secondary: String,

    #[arg(long, default_value = "auto", value_name = "TERM")]
    terminal_profile: String,

    #[arg(long, hide = true)]
    throughput_bench_bytes: Option<usize>,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum ColorLevel {
    Mono,
    Color8,
    Color256,
    Direct,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TerminalFeatures {
    color: ColorLevel,
    xterm_protocols: bool,
    mouse_sgr: bool,
    bracketed_paste: bool,
    xtgetcap: bool,
    xtversion: bool,
    osc_color_query: bool,
    osc52: bool,
    synchronized_updates: bool,
    kitty_keyboard: bool,
    kitty_graphics: bool,
}

impl TerminalFeatures {
    const fn minimal(color: ColorLevel) -> Self {
        Self {
            color,
            xterm_protocols: false,
            mouse_sgr: false,
            bracketed_paste: false,
            xtgetcap: false,
            xtversion: false,
            osc_color_query: false,
            osc52: false,
            synchronized_updates: false,
            kitty_keyboard: false,
            kitty_graphics: false,
        }
    }

    const fn xterm(color: ColorLevel) -> Self {
        Self {
            color,
            xterm_protocols: true,
            mouse_sgr: true,
            bracketed_paste: true,
            xtgetcap: true,
            xtversion: true,
            osc_color_query: true,
            osc52: true,
            synchronized_updates: false,
            kitty_keyboard: false,
            kitty_graphics: false,
        }
    }

    const fn with_synchronized_updates(mut self) -> Self {
        self.synchronized_updates = true;
        self
    }

    const fn with_kitty(mut self) -> Self {
        self.kitty_keyboard = true;
        self.kitty_graphics = true;
        self
    }

    fn supports(self, required: Self) -> bool {
        self.color >= required.color
            && supports_bool(self.xterm_protocols, required.xterm_protocols)
            && supports_bool(self.mouse_sgr, required.mouse_sgr)
            && supports_bool(self.bracketed_paste, required.bracketed_paste)
            && supports_bool(self.xtgetcap, required.xtgetcap)
            && supports_bool(self.xtversion, required.xtversion)
            && supports_bool(self.osc_color_query, required.osc_color_query)
            && supports_bool(self.osc52, required.osc52)
            && supports_bool(self.synchronized_updates, required.synchronized_updates)
            && supports_bool(self.kitty_keyboard, required.kitty_keyboard)
            && supports_bool(self.kitty_graphics, required.kitty_graphics)
    }
}

fn supports_bool(have: bool, required: bool) -> bool {
    have || !required
}

const IMPLEMENTED_FEATURES: TerminalFeatures = TerminalFeatures {
    color: ColorLevel::Direct,
    xterm_protocols: true,
    mouse_sgr: true,
    bracketed_paste: true,
    xtgetcap: true,
    xtversion: true,
    osc_color_query: true,
    osc52: true,
    synchronized_updates: true,
    kitty_keyboard: true,
    kitty_graphics: true,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TerminalProfile {
    term: &'static str,
    features: TerminalFeatures,
    required: TerminalFeatures,
}

impl TerminalProfile {
    const fn new(term: &'static str, features: TerminalFeatures) -> Self {
        Self {
            term,
            features,
            required: features,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TerminalConfig {
    advertised_profile: TerminalProfile,
}

impl TerminalConfig {
    fn detect(requested: &str) -> Result<Self> {
        let host_term = env::var("TERM").unwrap_or_else(|_| "xterm-256color".to_string());
        Self::select(requested, &host_term)
    }

    fn select(requested: &str, host_term: &str) -> Result<Self> {
        let outer_profile = profile_for_term(host_term).unwrap_or_else(profile_xterm_256color);
        let advertised_profile = if requested == "auto" {
            best_implemented_profile(outer_profile)
        } else {
            let requested_profile = profile_for_term(requested)
                .with_context(|| format!("unsupported terminal profile {requested:?}"))?;
            if !outer_profile.features.supports(requested_profile.required) {
                bail!(
                    "terminal profile {:?} requires features not advertised by outer TERM {:?}",
                    requested_profile.term,
                    host_term
                );
            }
            if !IMPLEMENTED_FEATURES.supports(requested_profile.required) {
                bail!(
                    "terminal profile {:?} requires protocols tinymux does not emulate yet",
                    requested_profile.term
                );
            }
            requested_profile
        };

        Ok(Self { advertised_profile })
    }

    fn term(&self) -> &'static str {
        self.advertised_profile.term
    }

    fn features(&self) -> TerminalFeatures {
        self.advertised_profile.features
    }
}

fn best_implemented_profile(outer: TerminalProfile) -> TerminalProfile {
    if IMPLEMENTED_FEATURES.supports(outer.required) {
        return outer;
    }
    if outer.features.color >= ColorLevel::Direct
        && IMPLEMENTED_FEATURES.color >= ColorLevel::Direct
    {
        return profile_xterm_direct();
    }
    if outer.features.color >= ColorLevel::Color256 {
        return profile_xterm_256color();
    }
    if outer.features.color >= ColorLevel::Color8 {
        return profile_xterm();
    }
    profile_vt100()
}

fn profile_for_term(term: &str) -> Option<TerminalProfile> {
    let normalized = term.trim().to_ascii_lowercase();
    let profile = match normalized.as_str() {
        "" | "auto" => return None,
        "dumb" => profile_dumb(),
        "vt100" | "vt100-nav" | "vt100-s" | "vt102" => profile_vt100(),
        "ansi" | "ansi.sys" | "ansi-generic" => profile_ansi(),
        "linux" | "linux-16color" | "linux-basic" => profile_linux(),
        "xterm" => profile_xterm(),
        "xterm-256color" => profile_xterm_256color(),
        "xterm-direct" => profile_xterm_direct(),
        "screen" | "screen.linux" | "screen.xterm-r6" => profile_screen(),
        "screen-256color" | "screen.xterm-256color" | "screen.vte-256color" => {
            profile_screen_256color()
        }
        "tmux" => profile_tmux(),
        "tmux-256color" => profile_tmux_256color(),
        "tmux-direct" => profile_tmux_direct(),
        "alacritty" => profile_alacritty(),
        "alacritty-direct" => profile_alacritty_direct(),
        "foot" => profile_foot(),
        "foot-direct" => profile_foot_direct(),
        "wezterm" => profile_wezterm(),
        "kitty" | "xterm-kitty" => profile_kitty(),
        "ghostty" | "xterm-ghostty" => profile_ghostty(),
        "rio" => profile_rio(),
        "rio-direct" => profile_rio_direct(),
        "contour" => profile_contour(),
        "contour-direct" => profile_contour_direct(),
        "st" | "st-256color" => profile_st_256color(),
        "st-direct" => profile_st_direct(),
        "rxvt" | "rxvt-unicode" => profile_rxvt(),
        "rxvt-256color" | "rxvt-unicode-256color" => profile_rxvt_256color(),
        "putty" => profile_putty(),
        "putty-256color" => profile_putty_256color(),
        "gnome" | "gnome-256color" => profile_gnome_256color(),
        "konsole" | "konsole-256color" => profile_konsole_256color(),
        "iterm.app" | "iterm2.app" => profile_iterm2(),
        "iterm2-direct" => profile_iterm2_direct(),
        "cygwin" => profile_cygwin(),
        _ if normalized.starts_with("xterm") && normalized.contains("direct") => {
            profile_xterm_direct()
        }
        _ if normalized.starts_with("xterm") && normalized.contains("256") => {
            profile_xterm_256color()
        }
        _ if normalized.starts_with("xterm") => profile_xterm(),
        _ if normalized.starts_with("screen") && normalized.contains("direct") => {
            profile_screen_direct()
        }
        _ if normalized.starts_with("screen") && normalized.contains("256") => {
            profile_screen_256color()
        }
        _ if normalized.starts_with("screen") => profile_screen(),
        _ if normalized.starts_with("tmux") && normalized.contains("direct") => {
            profile_tmux_direct()
        }
        _ if normalized.starts_with("tmux") && normalized.contains("256") => {
            profile_tmux_256color()
        }
        _ if normalized.starts_with("tmux") => profile_tmux(),
        _ if normalized.starts_with("vte") && normalized.contains("direct") => profile_vte_direct(),
        _ if normalized.starts_with("vte") => profile_vte_256color(),
        _ if normalized.starts_with("rxvt") && normalized.contains("256") => {
            profile_rxvt_256color()
        }
        _ if normalized.starts_with("rxvt") => profile_rxvt(),
        _ => return None,
    };
    Some(profile)
}

fn profile_dumb() -> TerminalProfile {
    TerminalProfile::new("dumb", TerminalFeatures::minimal(ColorLevel::Mono))
}

fn profile_vt100() -> TerminalProfile {
    TerminalProfile::new("vt100", TerminalFeatures::minimal(ColorLevel::Mono))
}

fn profile_ansi() -> TerminalProfile {
    TerminalProfile::new("ansi", TerminalFeatures::minimal(ColorLevel::Color8))
}

fn profile_linux() -> TerminalProfile {
    TerminalProfile::new("linux", TerminalFeatures::minimal(ColorLevel::Color8))
}

fn profile_xterm() -> TerminalProfile {
    TerminalProfile::new("xterm", TerminalFeatures::xterm(ColorLevel::Color8))
}

fn profile_xterm_256color() -> TerminalProfile {
    TerminalProfile::new(
        "xterm-256color",
        TerminalFeatures::xterm(ColorLevel::Color256),
    )
}

fn profile_xterm_direct() -> TerminalProfile {
    TerminalProfile::new("xterm-direct", TerminalFeatures::xterm(ColorLevel::Direct))
}

fn profile_screen() -> TerminalProfile {
    TerminalProfile::new("screen", TerminalFeatures::minimal(ColorLevel::Color8))
}

fn profile_screen_256color() -> TerminalProfile {
    TerminalProfile::new(
        "screen-256color",
        TerminalFeatures::minimal(ColorLevel::Color256),
    )
}

fn profile_screen_direct() -> TerminalProfile {
    TerminalProfile::new(
        "screen-direct",
        TerminalFeatures::minimal(ColorLevel::Direct),
    )
}

fn profile_tmux() -> TerminalProfile {
    TerminalProfile::new("tmux", TerminalFeatures::xterm(ColorLevel::Color8))
}

fn profile_tmux_256color() -> TerminalProfile {
    TerminalProfile::new(
        "tmux-256color",
        TerminalFeatures::xterm(ColorLevel::Color256),
    )
}

fn profile_tmux_direct() -> TerminalProfile {
    TerminalProfile::new("tmux-direct", TerminalFeatures::xterm(ColorLevel::Direct))
}

fn profile_alacritty() -> TerminalProfile {
    TerminalProfile::new("alacritty", TerminalFeatures::xterm(ColorLevel::Color256))
}

fn profile_alacritty_direct() -> TerminalProfile {
    TerminalProfile::new(
        "alacritty-direct",
        TerminalFeatures::xterm(ColorLevel::Direct),
    )
}

fn profile_foot() -> TerminalProfile {
    TerminalProfile::new("foot", TerminalFeatures::xterm(ColorLevel::Color256))
}

fn profile_foot_direct() -> TerminalProfile {
    TerminalProfile::new("foot-direct", TerminalFeatures::xterm(ColorLevel::Direct))
}

fn profile_wezterm() -> TerminalProfile {
    let features = TerminalFeatures::xterm(ColorLevel::Direct).with_synchronized_updates();
    TerminalProfile::new("wezterm", features)
}

fn profile_kitty() -> TerminalProfile {
    let features = TerminalFeatures::xterm(ColorLevel::Direct)
        .with_synchronized_updates()
        .with_kitty();
    TerminalProfile::new("xterm-kitty", features)
}

fn profile_ghostty() -> TerminalProfile {
    let features = TerminalFeatures::xterm(ColorLevel::Direct)
        .with_synchronized_updates()
        .with_kitty();
    TerminalProfile::new("xterm-ghostty", features)
}

fn profile_rio() -> TerminalProfile {
    TerminalProfile::new("rio", TerminalFeatures::xterm(ColorLevel::Color256))
}

fn profile_rio_direct() -> TerminalProfile {
    TerminalProfile::new("rio-direct", TerminalFeatures::xterm(ColorLevel::Direct))
}

fn profile_contour() -> TerminalProfile {
    TerminalProfile::new("contour", TerminalFeatures::xterm(ColorLevel::Color256))
}

fn profile_contour_direct() -> TerminalProfile {
    TerminalProfile::new(
        "contour-direct",
        TerminalFeatures::xterm(ColorLevel::Direct),
    )
}

fn profile_st_256color() -> TerminalProfile {
    TerminalProfile::new("st-256color", TerminalFeatures::xterm(ColorLevel::Color256))
}

fn profile_st_direct() -> TerminalProfile {
    TerminalProfile::new("st-direct", TerminalFeatures::xterm(ColorLevel::Direct))
}

fn profile_rxvt() -> TerminalProfile {
    TerminalProfile::new("rxvt", TerminalFeatures::minimal(ColorLevel::Color8))
}

fn profile_rxvt_256color() -> TerminalProfile {
    TerminalProfile::new(
        "rxvt-unicode-256color",
        TerminalFeatures::minimal(ColorLevel::Color256),
    )
}

fn profile_putty() -> TerminalProfile {
    TerminalProfile::new("putty", TerminalFeatures::minimal(ColorLevel::Color8))
}

fn profile_putty_256color() -> TerminalProfile {
    TerminalProfile::new(
        "putty-256color",
        TerminalFeatures::minimal(ColorLevel::Color256),
    )
}

fn profile_gnome_256color() -> TerminalProfile {
    TerminalProfile::new(
        "gnome-256color",
        TerminalFeatures::xterm(ColorLevel::Color256),
    )
}

fn profile_konsole_256color() -> TerminalProfile {
    TerminalProfile::new(
        "konsole-256color",
        TerminalFeatures::xterm(ColorLevel::Color256),
    )
}

fn profile_vte_256color() -> TerminalProfile {
    TerminalProfile::new(
        "vte-256color",
        TerminalFeatures::xterm(ColorLevel::Color256),
    )
}

fn profile_vte_direct() -> TerminalProfile {
    TerminalProfile::new("vte-direct", TerminalFeatures::xterm(ColorLevel::Direct))
}

fn profile_iterm2() -> TerminalProfile {
    TerminalProfile::new("iTerm2.app", TerminalFeatures::xterm(ColorLevel::Color256))
}

fn profile_iterm2_direct() -> TerminalProfile {
    TerminalProfile::new("iterm2-direct", TerminalFeatures::xterm(ColorLevel::Direct))
}

fn profile_cygwin() -> TerminalProfile {
    TerminalProfile::new("cygwin", TerminalFeatures::minimal(ColorLevel::Color8))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PaneId {
    Main,
    Secondary,
}

impl PaneId {
    fn index(self) -> usize {
        match self {
            PaneId::Main => 0,
            PaneId::Secondary => 1,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Layout {
    rows: u16,
    cols: u16,
    main_rows: u16,
    border_row: u16,
    secondary_rows: u16,
}

impl Layout {
    fn new(rows: u16, cols: u16) -> Self {
        if rows >= 3 {
            let main_rows = DEFAULT_MAIN_ROWS.min(rows.saturating_sub(2)).max(1);
            let secondary_rows = rows.saturating_sub(main_rows + 1).max(1);
            Self {
                rows,
                cols,
                main_rows,
                border_row: main_rows + 1,
                secondary_rows,
            }
        } else if rows == 2 {
            Self {
                rows,
                cols,
                main_rows: 1,
                border_row: 2,
                secondary_rows: 0,
            }
        } else {
            Self {
                rows: rows.max(1),
                cols,
                main_rows: rows.max(1),
                border_row: rows.max(1),
                secondary_rows: 0,
            }
        }
    }

    fn pane_rows(self, pane: PaneId) -> u16 {
        match pane {
            PaneId::Main => self.main_rows,
            PaneId::Secondary => self.secondary_rows.max(1),
        }
    }

    fn pane_top(self, pane: PaneId) -> u16 {
        match pane {
            PaneId::Main => 1,
            PaneId::Secondary => self.border_row + 1,
        }
    }
}

#[derive(Debug)]
enum Event {
    PaneOutput(PaneId, Vec<u8>),
    PaneEof(PaneId),
    PaneExit(PaneId, String),
    Input(Vec<u8>),
    Resize,
    Shutdown,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct KittyKeyboardState {
    flags: u16,
    stack: Vec<u16>,
}

impl KittyKeyboardState {
    fn flags(&self) -> u16 {
        self.flags
    }

    fn push(&mut self, flags: u16) {
        self.stack.push(self.flags);
        self.flags = flags;
    }

    fn pop(&mut self, count: u16) {
        for _ in 0..count.max(1) {
            self.flags = self.stack.pop().unwrap_or(0);
        }
    }
}

#[derive(Debug, Default, Eq, PartialEq)]
enum KittyGraphicsScanner {
    #[default]
    Ground,
    Esc,
    EscUnderscore,
    C1Apc,
    Capturing {
        bytes: Vec<u8>,
        pending_esc: bool,
    },
}

impl KittyGraphicsScanner {
    fn feed(&mut self, byte: u8) -> Option<Vec<u8>> {
        let state = mem::take(self);
        let mut completed = None;
        *self = match state {
            KittyGraphicsScanner::Ground => match byte {
                b'\x1b' => KittyGraphicsScanner::Esc,
                0x9f => KittyGraphicsScanner::C1Apc,
                _ => KittyGraphicsScanner::Ground,
            },
            KittyGraphicsScanner::Esc => match byte {
                b'_' => KittyGraphicsScanner::EscUnderscore,
                b'\x1b' => KittyGraphicsScanner::Esc,
                0x9f => KittyGraphicsScanner::C1Apc,
                _ => KittyGraphicsScanner::Ground,
            },
            KittyGraphicsScanner::EscUnderscore => match byte {
                b'G' => KittyGraphicsScanner::Capturing {
                    bytes: vec![b'\x1b', b'_', b'G'],
                    pending_esc: false,
                },
                b'\x1b' => KittyGraphicsScanner::Esc,
                0x9f => KittyGraphicsScanner::C1Apc,
                _ => KittyGraphicsScanner::Ground,
            },
            KittyGraphicsScanner::C1Apc => match byte {
                b'G' => KittyGraphicsScanner::Capturing {
                    bytes: vec![0x9f, b'G'],
                    pending_esc: false,
                },
                b'\x1b' => KittyGraphicsScanner::Esc,
                0x9f => KittyGraphicsScanner::C1Apc,
                _ => KittyGraphicsScanner::Ground,
            },
            KittyGraphicsScanner::Capturing {
                mut bytes,
                pending_esc,
            } => {
                bytes.push(byte);
                if byte == 0x9c || (pending_esc && byte == b'\\') {
                    completed = Some(bytes);
                    KittyGraphicsScanner::Ground
                } else {
                    KittyGraphicsScanner::Capturing {
                        bytes,
                        pending_esc: byte == b'\x1b',
                    }
                }
            }
        };
        completed
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PlacedKittyGraphic {
    sequence: Vec<u8>,
    cursor_position: (u16, u16),
}

struct ProtocolEngine {
    profile: TerminalProfile,
    parser: vte::Parser,
    dcs_capture: Option<DcsCapture>,
    keyboard: KittyKeyboardState,
    synchronized_update: bool,
}

impl ProtocolEngine {
    fn new(profile: TerminalProfile) -> Self {
        Self {
            profile,
            parser: vte::Parser::new(),
            dcs_capture: None,
            keyboard: KittyKeyboardState::default(),
            synchronized_update: false,
        }
    }

    fn kitty_keyboard_flags(&self) -> u16 {
        self.keyboard.flags()
    }

    fn synchronized_update(&self) -> bool {
        self.synchronized_update
    }

    fn process(&mut self, bytes: &[u8], cursor_position: (u16, u16)) -> TerminalEffects {
        let keyboard_before = self.keyboard.flags();
        let mut responder = ProtocolResponder {
            profile: self.profile,
            cursor_position,
            child_responses: Vec::new(),
            outer_passthrough: Vec::new(),
            dcs_capture: self.dcs_capture.take(),
            keyboard: self.keyboard.clone(),
            keyboard_changed: false,
            synchronized_update: self.synchronized_update,
        };
        self.parser.advance(&mut responder, bytes);
        self.dcs_capture = responder.dcs_capture.take();
        self.keyboard = responder.keyboard;
        self.synchronized_update = responder.synchronized_update;

        TerminalEffects {
            child_responses: responder.child_responses,
            outer_passthrough: responder.outer_passthrough,
            keyboard_flags: if responder.keyboard_changed
                && self.keyboard.flags() != keyboard_before
            {
                Some(self.keyboard.flags())
            } else {
                None
            },
        }
    }
}

#[derive(Default, Debug, Eq, PartialEq)]
struct TerminalEffects {
    child_responses: Vec<u8>,
    outer_passthrough: Vec<u8>,
    keyboard_flags: Option<u16>,
}

#[derive(Debug, Eq, PartialEq)]
struct DcsCapture {
    intermediates: Vec<u8>,
    action: char,
    payload: Vec<u8>,
}

struct ProtocolResponder {
    profile: TerminalProfile,
    cursor_position: (u16, u16),
    child_responses: Vec<u8>,
    outer_passthrough: Vec<u8>,
    dcs_capture: Option<DcsCapture>,
    keyboard: KittyKeyboardState,
    keyboard_changed: bool,
    synchronized_update: bool,
}

impl ProtocolResponder {
    fn features(&self) -> TerminalFeatures {
        self.profile.features
    }

    fn set_synchronized_update(&mut self, enabled: bool) {
        if self.features().synchronized_updates {
            self.synchronized_update = enabled;
        }
    }

    fn query_synchronized_update(&mut self) {
        if self.features().synchronized_updates {
            let value = if self.synchronized_update { 1 } else { 2 };
            self.child_responses
                .extend_from_slice(format!("\x1b[?2026;{value}$y").as_bytes());
        }
    }

    fn push_keyboard_flags(&mut self, flags: u16) {
        if self.features().kitty_keyboard {
            self.keyboard.push(flags);
            self.keyboard_changed = true;
        }
    }

    fn pop_keyboard_flags(&mut self, count: u16) {
        if self.features().kitty_keyboard {
            self.keyboard.pop(count);
            self.keyboard_changed = true;
        }
    }

    fn query_keyboard_flags(&mut self) {
        let flags = if self.features().kitty_keyboard {
            self.keyboard.flags()
        } else {
            0
        };
        self.child_responses
            .extend_from_slice(format!("\x1b[?{flags}u").as_bytes());
    }
}

impl Perform for ProtocolResponder {
    fn hook(&mut self, _params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        if !ignore && self.features().xtgetcap && intermediates == b"+" && action == 'q' {
            self.dcs_capture = Some(DcsCapture {
                intermediates: intermediates.to_vec(),
                action,
                payload: Vec::new(),
            });
        } else {
            self.dcs_capture = None;
        }
    }

    fn put(&mut self, byte: u8) {
        if let Some(capture) = &mut self.dcs_capture {
            capture.payload.push(byte);
        }
    }

    fn unhook(&mut self) {
        let Some(capture) = self.dcs_capture.take() else {
            return;
        };
        if self.features().xtgetcap && capture.intermediates == b"+" && capture.action == 'q' {
            self.child_responses.extend_from_slice(b"\x1bP0+r");
            self.child_responses.extend_from_slice(&capture.payload);
            self.child_responses.extend_from_slice(b"\x1b\\");
        }
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        if self.features().osc_color_query {
            append_osc_color_response(params, b"10", b"rgb:cd/d6/f4", &mut self.child_responses);
            append_osc_color_response(params, b"11", b"rgb:11/11/1b", &mut self.child_responses);
            append_osc_color_response(params, b"12", b"7", &mut self.child_responses);
        }
        if self.features().osc52 && matches_osc_command(params, b"52") {
            append_osc_sequence(&mut self.outer_passthrough, params, bell_terminated);
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        if ignore || !self.features().xterm_protocols {
            return;
        }

        match (intermediates, action) {
            (b"", 'c') if first_param_is(params, 0) => {
                self.child_responses.extend_from_slice(b"\x1b[?1;2c");
            }
            (b">", 'c') if first_param_is(params, 0) => {
                self.child_responses.extend_from_slice(b"\x1b[>0;95;0c");
            }
            (b"", 'n') if first_param_is(params, 6) => {
                let (row, col) = self.cursor_position;
                self.child_responses
                    .extend_from_slice(format!("\x1b[{};{}R", row + 1, col + 1).as_bytes());
            }
            (b"?", 'n') if first_param_is(params, 6) => {
                let (row, col) = self.cursor_position;
                self.child_responses
                    .extend_from_slice(format!("\x1b[?{};{}R", row + 1, col + 1).as_bytes());
            }
            (b"?", 'u') => {
                self.query_keyboard_flags();
            }
            (b">", 'u') => {
                self.push_keyboard_flags(first_param(params));
            }
            (b"<", 'u') => {
                self.pop_keyboard_flags(first_param(params).max(1));
            }
            (b"?", 'h') if first_param_is(params, 2026) => {
                self.set_synchronized_update(true);
            }
            (b"?", 'l') if first_param_is(params, 2026) => {
                self.set_synchronized_update(false);
            }
            (b"?$", 'p') if first_param_is(params, 2026) => {
                self.query_synchronized_update();
            }
            (b">", 'q') if self.features().xtversion && first_param_is(params, 0) => {
                self.child_responses
                    .extend_from_slice(b"\x1bP>|tinymux 0.1.0\x1b\\");
            }
            _ => {}
        }
    }
}

struct Pane {
    parser: vt100::Parser,
    protocol: ProtocolEngine,
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
    reader_eof: bool,
    exit_status: Option<String>,
    kitty_graphics: KittyGraphicsScanner,
    pending_kitty_graphics: Vec<PlacedKittyGraphic>,
}

impl Pane {
    fn spawn(
        id: PaneId,
        command: &str,
        layout: Layout,
        tx: Sender<Event>,
        terminal: &TerminalConfig,
    ) -> Result<Self> {
        let pty_system = native_pty_system();
        let rows = layout.pane_rows(id);
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols: layout.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("open pty")?;

        let shell = shell_path();
        let mut cmd = CommandBuilder::new(&shell);
        cmd.arg("-lc");
        cmd.arg(command);
        cmd.env("TERM", terminal.term());
        cmd.env("SHELL", &shell);
        if let Ok(home) = env::var("HOME") {
            cmd.env("HOME", home);
        }
        if let Ok(path) = env::var("PATH") {
            cmd.env("PATH", path);
        }
        if let Ok(terminfo) = env::var("TERMINFO") {
            cmd.env("TERMINFO", terminfo);
        }
        if let Ok(terminfo_dirs) = env::var("TERMINFO_DIRS") {
            cmd.env("TERMINFO_DIRS", terminfo_dirs);
        }
        if let Ok(colorterm) = env::var("COLORTERM") {
            cmd.env("COLORTERM", colorterm);
        } else if terminal.features().color >= ColorLevel::Direct {
            cmd.env("COLORTERM", "truecolor");
        }

        let child = pair
            .slave
            .spawn_command(cmd)
            .with_context(|| format!("spawn pane command with {}", shell))?;
        let mut reader = pair.master.try_clone_reader().context("clone pty reader")?;
        let writer = pair.master.take_writer().context("take pty writer")?;

        let output_tx = tx.clone();
        thread::Builder::new()
            .name(format!("tinymux-{id:?}-reader"))
            .spawn(move || {
                let mut buf = vec![0_u8; 256 * 1024];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            if output_tx
                                .send(Event::PaneOutput(id, buf[..n].to_vec()))
                                .is_err()
                            {
                                break;
                            }
                        }
                        Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    }
                }
                let _ = output_tx.send(Event::PaneEof(id));
            })
            .context("spawn pty reader thread")?;

        thread::Builder::new()
            .name(format!("tinymux-{id:?}-waiter"))
            .spawn(move || {
                let mut child = child;
                let status = match child.wait() {
                    Ok(status) => format!("{status:?}"),
                    Err(err) => format!("wait error: {err}"),
                };
                let _ = tx.send(Event::PaneExit(id, status));
            })
            .context("spawn child waiter thread")?;

        Ok(Self {
            parser: vt100::Parser::new(rows, layout.cols, SCROLLBACK_LINES),
            protocol: ProtocolEngine::new(terminal.advertised_profile),
            writer,
            master: pair.master,
            reader_eof: false,
            exit_status: None,
            kitty_graphics: KittyGraphicsScanner::default(),
            pending_kitty_graphics: Vec::new(),
        })
    }

    fn process_output(&mut self, bytes: &[u8]) -> Vec<PlacedKittyGraphic> {
        process_terminal_output(
            &mut self.parser,
            &mut self.kitty_graphics,
            self.protocol.profile.features.kitty_graphics,
            bytes,
        )
    }

    fn mouse_mode_enabled(&self) -> bool {
        self.parser.screen().mouse_protocol_mode() != vt100::MouseProtocolMode::None
    }

    fn scrollback(&self) -> usize {
        self.parser.screen().scrollback()
    }

    fn scroll_by(&mut self, delta: isize) -> bool {
        let before = self.scrollback();
        let next = if delta.is_negative() {
            before.saturating_sub(delta.unsigned_abs())
        } else {
            before.saturating_add(delta as usize)
        };
        self.parser.screen_mut().set_scrollback(next);
        self.scrollback() != before
    }

    fn scroll_to_live(&mut self) -> bool {
        self.scroll_by(-(self.scrollback() as isize))
    }

    fn is_complete(&self) -> bool {
        self.reader_eof && self.exit_status.is_some()
    }

    fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        self.master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("resize pane pty")?;

        self.parser.screen_mut().set_size(rows, cols);
        Ok(())
    }
}

struct TerminalGuard;

impl TerminalGuard {
    fn enter() -> Result<Self> {
        enable_raw_mode().context("enable raw mode")?;
        let mut stdout = io::stdout().lock();
        stdout.write_all(b"\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J")?;
        stdout.flush()?;
        Ok(Self)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ =
            io::stdout().write_all(b"\x1b[?1006l\x1b[?1000l\x1b[?2004l\x1b[?25h\x1b[m\x1b[?1049l");
        let _ = io::stdout().flush();
    }
}

struct App {
    layout: Layout,
    panes: [Option<Pane>; 2],
    focus: PaneId,
    prefix: PrefixState,
    scroll_mode: bool,
    rendered_once: bool,
    dirty: bool,
    pending_bytes: usize,
    input_pending: Vec<u8>,
    outer_passthrough: Vec<u8>,
    outer_post_render: Vec<u8>,
    outer_keyboard_layer_active: bool,
    outer_keyboard_flags: u16,
    close_after_render: [bool; 2],
    close_redraw_pending: bool,
    last_rows: Vec<Vec<u8>>,
}

impl App {
    fn new(args: &Args, tx: Sender<Event>) -> Result<Self> {
        let (cols, rows) = terminal_size().unwrap_or((100, 32));
        let layout = Layout::new(rows, cols);
        let terminal = TerminalConfig::detect(&args.terminal_profile)?;
        let main = Pane::spawn(PaneId::Main, &args.main, layout, tx.clone(), &terminal)?;
        let secondary = Pane::spawn(PaneId::Secondary, &args.secondary, layout, tx, &terminal)?;
        let outer_keyboard_layer_active = terminal.features().kitty_keyboard;
        let mut outer_passthrough = Vec::new();
        if outer_keyboard_layer_active {
            outer_passthrough.extend_from_slice(b"\x1b[>0u");
        }
        Ok(Self {
            layout,
            panes: [Some(main), Some(secondary)],
            focus: PaneId::Main,
            prefix: PrefixState::Idle,
            scroll_mode: false,
            rendered_once: false,
            dirty: true,
            pending_bytes: 0,
            input_pending: Vec::new(),
            outer_passthrough,
            outer_post_render: Vec::new(),
            outer_keyboard_layer_active,
            outer_keyboard_flags: 0,
            close_after_render: [false, false],
            close_redraw_pending: false,
            last_rows: Vec::new(),
        })
    }

    fn pane(&self, id: PaneId) -> Option<&Pane> {
        self.panes[id.index()].as_ref()
    }

    fn pane_mut(&mut self, id: PaneId) -> Option<&mut Pane> {
        self.panes[id.index()].as_mut()
    }

    fn both_panes_active(&self) -> bool {
        self.pane(PaneId::Main).is_some() && self.pane(PaneId::Secondary).is_some()
    }

    fn any_panes_active(&self) -> bool {
        self.pane(PaneId::Main).is_some() || self.pane(PaneId::Secondary).is_some()
    }

    fn focus_live_pane(&mut self) {
        if self.pane(self.focus).is_some() {
            return;
        }
        if self.pane(PaneId::Main).is_some() {
            self.focus = PaneId::Main;
        } else if self.pane(PaneId::Secondary).is_some() {
            self.focus = PaneId::Secondary;
        }
    }

    fn focused_keyboard_flags(&self) -> u16 {
        self.focused_pane()
            .map(|(_, pane)| pane.protocol.kitty_keyboard_flags())
            .unwrap_or(0)
    }

    fn pane_at_row(&self, row: u16) -> Option<PaneId> {
        if !self.both_panes_active() {
            return self.focused_pane().map(|(id, _)| id);
        }
        if row == 0 || row > self.layout.rows {
            return None;
        }
        if row <= self.layout.main_rows {
            Some(PaneId::Main)
        } else if row == self.layout.border_row {
            None
        } else {
            Some(PaneId::Secondary)
        }
    }

    fn pane_page_size(&self, id: PaneId) -> usize {
        let rows = if self.both_panes_active() {
            self.layout.pane_rows(id)
        } else {
            self.layout.rows
        };
        usize::from(rows.saturating_sub(1).max(1))
    }

    fn scroll_pane_by(&mut self, id: PaneId, delta: isize) -> bool {
        let changed = self
            .pane_mut(id)
            .map(|pane| pane.scroll_by(delta))
            .unwrap_or(false);
        if changed {
            self.dirty = true;
        }
        changed
    }

    fn scroll_focused_by(&mut self, delta: isize) -> bool {
        self.scroll_pane_by(self.focus, delta)
    }

    fn scroll_focused_page(&mut self, direction: ScrollDirection) -> bool {
        let amount = self.pane_page_size(self.focus) as isize;
        match direction {
            ScrollDirection::Up => self.scroll_focused_by(amount),
            ScrollDirection::Down => self.scroll_focused_by(-amount),
        }
    }

    fn exit_scroll_mode(&mut self) {
        self.scroll_mode = false;
        let changed = self
            .pane_mut(self.focus)
            .map(|pane| pane.scroll_to_live())
            .unwrap_or(false);
        if changed {
            self.dirty = true;
        }
    }

    fn sync_outer_keyboard(&mut self, target: u16) {
        if !self.outer_keyboard_layer_active || self.outer_keyboard_flags == target {
            return;
        }
        self.outer_passthrough.extend_from_slice(b"\x1b[<u");
        self.outer_passthrough
            .extend_from_slice(format!("\x1b[>{target}u").as_bytes());
        self.outer_keyboard_flags = target;
    }

    fn reset_outer_keyboard(&mut self) {
        if self.outer_keyboard_layer_active {
            self.outer_passthrough.extend_from_slice(b"\x1b[<u");
            self.outer_keyboard_layer_active = false;
            self.outer_keyboard_flags = 0;
        }
    }

    fn close_pane(&mut self, id: PaneId) -> Result<bool> {
        self.close_after_render[id.index()] = false;
        if self.panes[id.index()].take().is_some() {
            self.focus_live_pane();
            if !self.any_panes_active() {
                self.reset_outer_keyboard();
                return Ok(false);
            }
            self.sync_outer_keyboard(self.focused_keyboard_flags());
            self.resize_active_panes()?;
            self.rendered_once = false;
            self.dirty = true;
        }
        Ok(true)
    }

    fn defer_close_pane(&mut self, id: PaneId) {
        if self.pane(id).is_some() {
            self.close_after_render[id.index()] = true;
            self.dirty = true;
        }
    }

    fn close_deferred_panes(&mut self) -> Result<bool> {
        let mut closed = false;
        for id in [PaneId::Main, PaneId::Secondary] {
            if self.close_after_render[id.index()] {
                if !self.close_pane(id)? {
                    return Ok(false);
                }
                closed = true;
            }
        }
        if closed {
            self.close_redraw_pending = true;
        }
        Ok(true)
    }

    fn focused_pane(&self) -> Option<(PaneId, &Pane)> {
        self.pane(self.focus)
            .map(|pane| (self.focus, pane))
            .or_else(|| self.pane(PaneId::Main).map(|pane| (PaneId::Main, pane)))
            .or_else(|| {
                self.pane(PaneId::Secondary)
                    .map(|pane| (PaneId::Secondary, pane))
            })
    }

    fn resize_active_panes(&mut self) -> Result<()> {
        if self.both_panes_active() {
            let layout = self.layout;
            if let Some(pane) = self.pane_mut(PaneId::Main) {
                pane.resize(layout.main_rows.max(1), layout.cols)?;
            }
            if let Some(pane) = self.pane_mut(PaneId::Secondary) {
                pane.resize(layout.secondary_rows.max(1), layout.cols)?;
            }
        } else {
            let rows = self.layout.rows.max(1);
            let cols = self.layout.cols;
            for id in [PaneId::Main, PaneId::Secondary] {
                if let Some(pane) = self.pane_mut(id) {
                    pane.resize(rows, cols)?;
                }
            }
        }
        Ok(())
    }

    fn handle_event(&mut self, event: Event) -> Result<bool> {
        match event {
            Event::PaneOutput(id, bytes) => {
                if self.pane(id).is_none() {
                    return Ok(true);
                }
                self.pending_bytes += bytes.len();
                let (effects, placed_graphics) = {
                    let pane = self.pane_mut(id).expect("pane checked above");
                    let placed_graphics = pane.process_output(&bytes);
                    let cursor_position = pane.parser.screen().cursor_position();
                    (
                        pane.protocol.process(&bytes, cursor_position),
                        placed_graphics,
                    )
                };
                if !effects.child_responses.is_empty() {
                    let pane = self.pane_mut(id).expect("pane checked above");
                    pane.writer.write_all(&effects.child_responses)?;
                    pane.writer.flush()?;
                }
                self.outer_passthrough.extend(effects.outer_passthrough);
                if id == self.focus {
                    if let Some(flags) = effects.keyboard_flags {
                        self.sync_outer_keyboard(flags);
                    }
                }
                let mut graphics_to_render = Vec::new();
                let synchronized = {
                    let pane = self.pane_mut(id).expect("pane checked above");
                    pane.pending_kitty_graphics.extend(placed_graphics);
                    if pane.protocol.synchronized_update() {
                        true
                    } else {
                        graphics_to_render = mem::take(&mut pane.pending_kitty_graphics);
                        false
                    }
                };
                if !graphics_to_render.is_empty() {
                    self.queue_kitty_graphics(id, graphics_to_render)?;
                }
                if !synchronized {
                    self.dirty = true;
                }
            }
            Event::PaneEof(id) => {
                let should_close = if let Some(pane) = self.pane_mut(id) {
                    pane.reader_eof = true;
                    pane.is_complete()
                } else {
                    false
                };
                if should_close {
                    self.defer_close_pane(id);
                }
            }
            Event::PaneExit(id, status) => {
                let should_close = if let Some(pane) = self.pane_mut(id) {
                    pane.exit_status = Some(status);
                    pane.is_complete()
                } else {
                    false
                };
                if should_close {
                    self.defer_close_pane(id);
                }
            }
            Event::Input(bytes) => {
                self.handle_input(&bytes)?;
            }
            Event::Resize => {
                self.resize()?;
            }
            Event::Shutdown => return Ok(false),
        }
        Ok(true)
    }

    fn handle_input(&mut self, bytes: &[u8]) -> Result<()> {
        self.input_pending.extend_from_slice(bytes);
        let pending = mem::take(&mut self.input_pending);
        let mut idx = 0;
        while idx < pending.len() {
            match parse_sgr_mouse(&pending[idx..]) {
                ParseResult::Complete(len, event) => {
                    if self.handle_mouse_event(event)? {
                        idx += len;
                        continue;
                    }
                }
                ParseResult::Incomplete => break,
                ParseResult::NoMatch => {}
            }

            if self.scroll_mode {
                match parse_scroll_mode_input(&pending[idx..]) {
                    ParseResult::Complete(len, action) => {
                        self.handle_scroll_action(action);
                        idx += len;
                        continue;
                    }
                    ParseResult::Incomplete => break,
                    ParseResult::NoMatch => {
                        idx += 1;
                        continue;
                    }
                }
            }

            let byte = pending[idx];
            idx += 1;
            self.handle_input_byte(byte)?;
        }
        if idx < pending.len() {
            self.input_pending.extend_from_slice(&pending[idx..]);
        }
        if let Some(pane) = self.pane_mut(self.focus) {
            pane.writer.flush()?;
        }
        Ok(())
    }

    fn handle_input_byte(&mut self, byte: u8) -> Result<()> {
        match self.prefix.feed(byte) {
            PrefixAction::None => {}
            PrefixAction::Forward(data) => {
                let scrolled = if let Some(pane) = self.pane_mut(self.focus) {
                    let scrolled = pane.scroll_to_live();
                    pane.writer.write_all(&data)?;
                    scrolled
                } else {
                    false
                };
                if scrolled {
                    self.dirty = true;
                }
            }
            PrefixAction::Focus(id) => {
                if self.pane(id).is_some() {
                    self.focus = id;
                    self.sync_outer_keyboard(self.focused_keyboard_flags());
                    self.dirty = true;
                }
            }
            PrefixAction::EnterScrollMode => {
                self.scroll_mode = true;
                self.dirty = true;
            }
        }
        Ok(())
    }

    fn handle_mouse_event(&mut self, event: SgrMouseEvent) -> Result<bool> {
        if !event.pressed {
            return Ok(false);
        }
        let Some(direction) = event.wheel_direction() else {
            return Ok(false);
        };
        let Some(id) = self.pane_at_row(event.row) else {
            return Ok(true);
        };
        if self
            .pane(id)
            .map(|pane| pane.mouse_mode_enabled())
            .unwrap_or(false)
        {
            return Ok(false);
        }
        let amount = WHEEL_SCROLL_LINES as isize;
        match direction {
            ScrollDirection::Up => {
                self.scroll_pane_by(id, amount);
            }
            ScrollDirection::Down => {
                self.scroll_pane_by(id, -amount);
            }
        }
        Ok(true)
    }

    fn handle_scroll_action(&mut self, action: ScrollAction) {
        match action {
            ScrollAction::LineUp => {
                self.scroll_focused_by(1);
            }
            ScrollAction::LineDown => {
                self.scroll_focused_by(-1);
            }
            ScrollAction::PageUp => {
                self.scroll_focused_page(ScrollDirection::Up);
            }
            ScrollAction::PageDown => {
                self.scroll_focused_page(ScrollDirection::Down);
            }
            ScrollAction::Exit => self.exit_scroll_mode(),
        }
    }

    fn resize(&mut self) -> Result<()> {
        let (cols, rows) = terminal_size().unwrap_or((self.layout.cols, self.layout.rows));
        let layout = Layout::new(rows, cols);
        self.layout = layout;
        self.resize_active_panes()?;
        self.rendered_once = false;
        self.dirty = true;
        Ok(())
    }

    fn queue_kitty_graphics(
        &mut self,
        id: PaneId,
        graphics: Vec<PlacedKittyGraphic>,
    ) -> Result<()> {
        let pane_top = pane_top(self.layout, id, self.both_panes_active());
        for graphic in graphics {
            let (row, col) = graphic.cursor_position;
            let global_row = pane_top.saturating_add(row).min(self.layout.rows.max(1));
            let global_col = col.saturating_add(1).min(self.layout.cols.max(1));
            write!(self.outer_post_render, "\x1b[{global_row};{global_col}H")?;
            self.outer_post_render.extend(graphic.sequence);
        }
        Ok(())
    }

    fn needs_render(&self) -> bool {
        self.dirty || !self.outer_passthrough.is_empty() || !self.outer_post_render.is_empty()
    }

    fn should_flush_immediately(&self, event: &Event) -> bool {
        if self.close_redraw_pending {
            return false;
        }
        matches!(event, Event::PaneOutput(id, _) if *id == self.focus)
            && self.pending_bytes < FLOOD_BATCH
            || matches!(
                event,
                Event::Input(_) | Event::Resize | Event::PaneEof(_) | Event::PaneExit(_, _)
            )
    }

    fn render<W: Write>(&mut self, out: &mut W) -> Result<()> {
        if !self.needs_render() {
            return Ok(());
        }
        let had_dirty = self.dirty;
        let had_post_render = !self.outer_post_render.is_empty();
        if !self.outer_passthrough.is_empty() {
            out.write_all(&self.outer_passthrough)?;
            self.outer_passthrough.clear();
        }
        if had_dirty && !self.rendered_once {
            out.write_all(b"\x1b[H\x1b[2J")?;
            self.rendered_once = true;
            self.last_rows.clear();
        }
        if had_dirty {
            let rows = compose_rows(
                self.layout,
                self.pane(PaneId::Main),
                self.pane(PaneId::Secondary),
                self.focus,
            );
            for (idx, row) in rows.iter().enumerate() {
                let changed = self
                    .last_rows
                    .get(idx)
                    .map(|previous| previous.as_slice() != row.as_slice())
                    .unwrap_or(true);
                if changed {
                    write!(out, "\x1b[{};1H", idx + 1)?;
                    out.write_all(row)?;
                    out.write_all(b"\x1b[m\x1b[K")?;
                }
            }
            if self.last_rows.len() > rows.len() {
                for idx in rows.len()..self.last_rows.len() {
                    write!(out, "\x1b[{};1H\x1b[m\x1b[K", idx + 1)?;
                }
            }
            self.last_rows = rows;
        }
        if !self.outer_post_render.is_empty() {
            out.write_all(&self.outer_post_render)?;
            self.outer_post_render.clear();
        }
        if had_dirty || had_post_render {
            if let Some((id, pane)) = self.focused_pane() {
                render_focused_cursor(
                    out,
                    self.layout,
                    pane,
                    pane_top(self.layout, id, self.both_panes_active()),
                )?;
                render_input_modes(out, pane)?;
            }
        }
        out.flush()?;
        if had_dirty {
            self.dirty = false;
            self.close_redraw_pending = false;
            self.pending_bytes = 0;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum PrefixState {
    Idle,
    SawPrefix,
    SawEsc,
    SawEscBracket,
}

#[derive(Debug, Eq, PartialEq)]
enum PrefixAction {
    None,
    Forward(Vec<u8>),
    Focus(PaneId),
    EnterScrollMode,
}

impl PrefixState {
    fn feed(&mut self, byte: u8) -> PrefixAction {
        match self {
            PrefixState::Idle if byte == 0x02 => {
                *self = PrefixState::SawPrefix;
                PrefixAction::None
            }
            PrefixState::Idle => PrefixAction::Forward(vec![byte]),
            PrefixState::SawPrefix if byte == b'\x1b' => {
                *self = PrefixState::SawEsc;
                PrefixAction::None
            }
            PrefixState::SawPrefix if byte == b'[' => {
                *self = PrefixState::Idle;
                PrefixAction::EnterScrollMode
            }
            PrefixState::SawPrefix => {
                *self = PrefixState::Idle;
                let mut data = vec![0x02, byte];
                PrefixAction::Forward(std::mem::take(&mut data))
            }
            PrefixState::SawEsc if byte == b'[' => {
                *self = PrefixState::SawEscBracket;
                PrefixAction::None
            }
            PrefixState::SawEsc => {
                *self = PrefixState::Idle;
                PrefixAction::Forward(vec![0x02, b'\x1b', byte])
            }
            PrefixState::SawEscBracket => {
                *self = PrefixState::Idle;
                match byte {
                    b'A' => PrefixAction::Focus(PaneId::Main),
                    b'B' => PrefixAction::Focus(PaneId::Secondary),
                    other => PrefixAction::Forward(vec![0x02, b'\x1b', b'[', other]),
                }
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ScrollDirection {
    Up,
    Down,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ScrollAction {
    LineUp,
    LineDown,
    PageUp,
    PageDown,
    Exit,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SgrMouseEvent {
    button: u16,
    col: u16,
    row: u16,
    pressed: bool,
}

impl SgrMouseEvent {
    fn wheel_direction(self) -> Option<ScrollDirection> {
        match self.button & !0x1c {
            64 => Some(ScrollDirection::Up),
            65 => Some(ScrollDirection::Down),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ParseResult<T> {
    Complete(usize, T),
    Incomplete,
    NoMatch,
}

fn parse_sgr_mouse(input: &[u8]) -> ParseResult<SgrMouseEvent> {
    const PREFIX: &[u8] = b"\x1b[<";
    if !input.starts_with(PREFIX) {
        return ParseResult::NoMatch;
    }
    let Some(end) = input.iter().position(|byte| matches!(*byte, b'M' | b'm')) else {
        return ParseResult::Incomplete;
    };
    let final_byte = input[end];
    let body = &input[PREFIX.len()..end];
    let Some((button, col, row)) = parse_sgr_mouse_body(body) else {
        return ParseResult::NoMatch;
    };
    ParseResult::Complete(
        end + 1,
        SgrMouseEvent {
            button,
            col,
            row,
            pressed: final_byte == b'M',
        },
    )
}

fn parse_sgr_mouse_body(body: &[u8]) -> Option<(u16, u16, u16)> {
    let mut parts = body.split(|byte| *byte == b';');
    let button = parse_u16_ascii(parts.next()?)?;
    let col = parse_u16_ascii(parts.next()?)?;
    let row = parse_u16_ascii(parts.next()?)?;
    if parts.next().is_some() {
        return None;
    }
    Some((button, col, row))
}

fn parse_u16_ascii(bytes: &[u8]) -> Option<u16> {
    if bytes.is_empty() {
        return None;
    }
    let mut value = 0_u16;
    for byte in bytes {
        if !byte.is_ascii_digit() {
            return None;
        }
        value = value.checked_mul(10)?.checked_add(u16::from(byte - b'0'))?;
    }
    Some(value)
}

fn parse_scroll_mode_input(input: &[u8]) -> ParseResult<ScrollAction> {
    for (sequence, action) in [
        (&b"\x1b[5~"[..], ScrollAction::PageUp),
        (&b"\x1b[6~"[..], ScrollAction::PageDown),
        (&b"\x1b[A"[..], ScrollAction::LineUp),
        (&b"\x1b[B"[..], ScrollAction::LineDown),
    ] {
        if input.starts_with(sequence) {
            return ParseResult::Complete(sequence.len(), action);
        }
        if sequence.starts_with(input) {
            return ParseResult::Incomplete;
        }
    }
    match input.first().copied() {
        Some(b'q' | b'\x1b' | b'\x03') => ParseResult::Complete(1, ScrollAction::Exit),
        Some(b'k') => ParseResult::Complete(1, ScrollAction::LineUp),
        Some(b'j') => ParseResult::Complete(1, ScrollAction::LineDown),
        Some(b'u') => ParseResult::Complete(1, ScrollAction::PageUp),
        Some(b'd') => ParseResult::Complete(1, ScrollAction::PageDown),
        Some(_) => ParseResult::NoMatch,
        None => ParseResult::Incomplete,
    }
}

fn compose_rows(
    layout: Layout,
    main: Option<&Pane>,
    secondary: Option<&Pane>,
    focus: PaneId,
) -> Vec<Vec<u8>> {
    let mut rows = Vec::with_capacity(layout.rows as usize);
    match (main, secondary) {
        (Some(main), Some(secondary)) => {
            append_pane_rows(&mut rows, layout.main_rows, layout.cols, main);
            if layout.rows >= 2 {
                rows.push(border_row_body(layout, focus));
            }
            if layout.secondary_rows > 0 {
                append_pane_rows(&mut rows, layout.secondary_rows, layout.cols, secondary);
            }
        }
        (Some(pane), None) | (None, Some(pane)) => {
            append_pane_rows(&mut rows, layout.rows, layout.cols, pane);
        }
        (None, None) => {}
    }
    rows.truncate(layout.rows as usize);
    rows
}

fn append_pane_rows(rows: &mut Vec<Vec<u8>>, height: u16, cols: u16, pane: &Pane) {
    if height == 0 {
        return;
    }
    for bytes in pane
        .parser
        .screen()
        .rows_formatted(0, cols)
        .take(height as usize)
    {
        rows.push(bytes);
    }
}

fn border_row_body(layout: Layout, focus: PaneId) -> Vec<u8> {
    let mut body = Vec::with_capacity(layout.cols as usize * 3 + 32);
    let active_len = layout.cols / 2 + 1;
    let drawn_cols = if layout.cols % 2 == 1 {
        layout.cols.saturating_sub(1)
    } else {
        layout.cols
    };
    for col in 0..drawn_cols {
        if col == 0 {
            if focus == PaneId::Main {
                body.extend_from_slice(b"\x1b[32m");
            } else {
                body.extend_from_slice(b"\x1b[39m");
            }
        } else if col == active_len {
            if focus == PaneId::Secondary {
                body.extend_from_slice(b"\x1b[32m");
            } else {
                body.extend_from_slice(b"\x1b[39m");
            }
        }
        body.extend_from_slice("─".as_bytes());
    }
    if drawn_cols < layout.cols {
        body.push(b' ');
    }
    body
}

fn pane_top(layout: Layout, id: PaneId, both_panes_active: bool) -> u16 {
    if !both_panes_active {
        return 1;
    }
    layout.pane_top(id)
}

fn render_focused_cursor<W: Write>(
    out: &mut W,
    layout: Layout,
    pane: &Pane,
    pane_top: u16,
) -> Result<()> {
    let screen = pane.parser.screen();
    let (row, col) = screen.cursor_position();
    let global_row = pane_top.saturating_add(row).min(layout.rows.max(1));
    let global_col = col.saturating_add(1).min(layout.cols.max(1));
    if screen.hide_cursor() || screen.scrollback() > 0 {
        out.write_all(b"\x1b[?25l")?;
    } else {
        out.write_all(b"\x1b[?25h")?;
    }
    write!(out, "\x1b[{};{}H", global_row, global_col)?;
    Ok(())
}

fn render_input_modes<W: Write>(out: &mut W, pane: &Pane) -> Result<()> {
    out.write_all(&pane.parser.screen().input_mode_formatted())?;
    Ok(())
}

fn process_terminal_output(
    parser: &mut vt100::Parser,
    graphics_scanner: &mut KittyGraphicsScanner,
    kitty_graphics: bool,
    bytes: &[u8],
) -> Vec<PlacedKittyGraphic> {
    if !kitty_graphics {
        parser.process(bytes);
        return Vec::new();
    }

    let mut graphics = Vec::new();
    let mut segment_start = 0;
    for (idx, byte) in bytes.iter().enumerate() {
        let Some(sequence) = graphics_scanner.feed(*byte) else {
            continue;
        };
        parser.process(&bytes[segment_start..=idx]);
        graphics.push(PlacedKittyGraphic {
            sequence,
            cursor_position: parser.screen().cursor_position(),
        });
        segment_start = idx + 1;
    }
    if segment_start < bytes.len() {
        parser.process(&bytes[segment_start..]);
    }
    graphics
}

fn first_param(params: &Params) -> u16 {
    params
        .iter()
        .next()
        .and_then(|param| param.first())
        .copied()
        .unwrap_or(0)
}

fn first_param_is(params: &Params, expected: u16) -> bool {
    first_param(params) == expected
}

fn matches_osc_command(params: &[&[u8]], command: &[u8]) -> bool {
    matches!(params.first(), Some(param) if *param == command)
}

fn append_osc_color_response(
    params: &[&[u8]],
    index: &[u8],
    value: &[u8],
    responses: &mut Vec<u8>,
) {
    if matches_osc_command(params, index) && matches!(params.get(1), Some(param) if *param == b"?")
    {
        responses.extend_from_slice(b"\x1b]");
        responses.extend_from_slice(index);
        responses.extend_from_slice(b";");
        responses.extend_from_slice(value);
        responses.extend_from_slice(b"\x1b\\");
    }
}

fn append_osc_sequence(output: &mut Vec<u8>, params: &[&[u8]], bell_terminated: bool) {
    output.extend_from_slice(b"\x1b]");
    for (idx, param) in params.iter().enumerate() {
        if idx > 0 {
            output.push(b';');
        }
        output.extend_from_slice(param);
    }
    if bell_terminated {
        output.push(0x07);
    } else {
        output.extend_from_slice(b"\x1b\\");
    }
}

fn shell_path() -> String {
    env::var("SHELL")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "/bin/sh".to_string())
}

fn install_input_thread(tx: Sender<Event>) -> Result<()> {
    thread::Builder::new()
        .name("tinymux-stdin".to_string())
        .spawn(move || {
            let mut stdin = io::stdin().lock();
            let mut buf = [0_u8; 8192];
            loop {
                match stdin.read(&mut buf) {
                    Ok(0) => {
                        let _ = tx.send(Event::Shutdown);
                        break;
                    }
                    Ok(n) => {
                        if tx.send(Event::Input(buf[..n].to_vec())).is_err() {
                            break;
                        }
                    }
                    Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => {
                        let _ = tx.send(Event::Shutdown);
                        break;
                    }
                }
            }
        })
        .context("spawn stdin thread")?;
    Ok(())
}

fn install_resize_thread(tx: Sender<Event>) -> Result<()> {
    let mut signals = Signals::new([SIGWINCH]).context("install SIGWINCH handler")?;
    thread::Builder::new()
        .name("tinymux-sigwinch".to_string())
        .spawn(move || {
            for _ in signals.forever() {
                if tx.send(Event::Resize).is_err() {
                    break;
                }
            }
        })
        .context("spawn resize thread")?;
    Ok(())
}

fn run(args: Args) -> Result<()> {
    if let Some(bytes) = args.throughput_bench_bytes {
        return run_throughput_bench(bytes);
    }

    let _guard = TerminalGuard::enter()?;
    let (tx, rx) = unbounded();
    install_input_thread(tx.clone())?;
    install_resize_thread(tx.clone())?;
    let mut app = App::new(&args, tx)?;
    event_loop(rx, &mut app)
}

fn event_loop(rx: Receiver<Event>, app: &mut App) -> Result<()> {
    let bg_tick = tick(BACKGROUND_FLUSH);
    let flood_tick = tick(FLOOD_FLUSH);
    let resize_tick = tick(Duration::from_millis(4));
    let mut stdout = io::stdout().lock();
    app.render(&mut stdout)?;
    if !app.close_deferred_panes()? {
        app.reset_outer_keyboard();
        app.render(&mut stdout)?;
        return Ok(());
    }
    let mut last_flush = Instant::now();

    loop {
        select! {
            recv(rx) -> msg => {
                let event = msg.map_err(|_| anyhow!("event channel closed"))?;
                let immediate = app.should_flush_immediately(&event);
                if !app.handle_event(event)? {
                    break;
                }
                if immediate {
                    app.render(&mut stdout)?;
                    if !app.close_deferred_panes()? {
                        break;
                    }
                    last_flush = Instant::now();
                }
            }
            recv(bg_tick) -> _ => {
                if app.needs_render() && last_flush.elapsed() >= BACKGROUND_FLUSH {
                    app.render(&mut stdout)?;
                    if !app.close_deferred_panes()? {
                        break;
                    }
                    last_flush = Instant::now();
                }
            }
            recv(flood_tick) -> _ => {
                if app.needs_render() && app.pending_bytes >= FLOOD_BATCH {
                    app.render(&mut stdout)?;
                    if !app.close_deferred_panes()? {
                        break;
                    }
                    last_flush = Instant::now();
                }
            }
            recv(resize_tick) -> _ => {
                if let Ok((cols, rows)) = terminal_size() {
                    if cols != app.layout.cols || rows != app.layout.rows {
                        app.resize()?;
                        app.render(&mut stdout)?;
                        if !app.close_deferred_panes()? {
                            break;
                        }
                        last_flush = Instant::now();
                    }
                }
            }
        }
    }
    app.reset_outer_keyboard();
    app.render(&mut stdout)?;
    Ok(())
}

fn run_throughput_bench(bytes: usize) -> Result<()> {
    let (processed, elapsed, mbps) = measure_parser_throughput(bytes);
    println!(
        "processed={} elapsed_ms={} mbps={:.2}",
        processed,
        elapsed.as_millis(),
        mbps
    );
    if mbps < 100.0 {
        bail!("throughput below target: {mbps:.2} MB/s");
    }
    Ok(())
}

fn measure_parser_throughput(bytes: usize) -> (usize, Duration, f64) {
    let mut parser = vt100::Parser::new(24, 80, 0);
    let chunk = b"abcdefghijklmnopqrstuvwxyz0123456789 throughput bench line\n";
    let mut processed = 0_usize;
    let started = Instant::now();
    while processed < bytes {
        let n = chunk.len().min(bytes - processed);
        parser.process(&chunk[..n]);
        processed += n;
    }
    let elapsed = started.elapsed();
    let mbps = processed as f64 / 1_000_000.0 / elapsed.as_secs_f64();
    (processed, elapsed, mbps)
}

fn main() -> Result<()> {
    let args = Args::parse();
    run(args)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_defaults_to_nine_secondary_rows() {
        let layout = Layout::new(32, 100);
        assert_eq!(layout.main_rows, 22);
        assert_eq!(layout.border_row, 23);
        assert_eq!(layout.secondary_rows, 9);
    }

    #[test]
    fn layout_gives_extra_height_to_secondary_like_tmux() {
        let layout = Layout::new(33, 100);
        assert_eq!(layout.main_rows, 22);
        assert_eq!(layout.border_row, 23);
        assert_eq!(layout.secondary_rows, 10);
    }

    #[test]
    fn layout_clamps_small_terminals() {
        let layout = Layout::new(3, 40);
        assert_eq!(layout.main_rows, 1);
        assert_eq!(layout.border_row, 2);
        assert_eq!(layout.secondary_rows, 1);
    }

    #[test]
    fn prefix_switches_focus() {
        let mut state = PrefixState::Idle;
        assert_eq!(state.feed(0x02), PrefixAction::None);
        assert_eq!(state.feed(b'\x1b'), PrefixAction::None);
        assert_eq!(state.feed(b'['), PrefixAction::None);
        assert_eq!(state.feed(b'B'), PrefixAction::Focus(PaneId::Secondary));
    }

    #[test]
    fn unknown_prefix_forwards_losslessly() {
        let mut state = PrefixState::Idle;
        assert_eq!(state.feed(0x02), PrefixAction::None);
        assert_eq!(state.feed(b'x'), PrefixAction::Forward(vec![0x02, b'x']));
    }

    #[test]
    fn throughput_bench_path_processes_requested_bytes() {
        let (processed, _, _) = measure_parser_throughput(1024 * 1024);
        assert_eq!(processed, 1024 * 1024);
    }

    #[test]
    fn pane_parser_keeps_scrollback_rows_available() {
        let mut parser = vt100::Parser::new(3, 24, SCROLLBACK_LINES);
        parser.process(b"line 1\r\nline 2\r\nline 3\r\nline 4\r\nline 5\r\n");
        assert_eq!(parser.screen().scrollback(), 0);
        let live = parser.screen().contents();

        parser.screen_mut().set_scrollback(2);

        assert_eq!(parser.screen().scrollback(), 2);
        assert_ne!(parser.screen().contents(), live);
    }

    #[test]
    fn sgr_wheel_events_are_parsed_with_coordinates() {
        assert_eq!(
            parse_sgr_mouse(b"\x1b[<64;9;12M"),
            ParseResult::Complete(
                11,
                SgrMouseEvent {
                    button: 64,
                    col: 9,
                    row: 12,
                    pressed: true,
                }
            )
        );
        assert_eq!(parse_sgr_mouse(b"\x1b[<65;9"), ParseResult::Incomplete);
    }

    #[test]
    fn terminal_responder_answers_fish_startup_queries() {
        let output = b"\x1b[?u\x1b[>0q\x1b]11;?\x1b\\\x1b[0c\x1bP+q696e646e\x1b\\";
        let mut protocol = ProtocolEngine::new(profile_xterm_256color());
        let effects = protocol.process(output, (4, 7));
        let responses = effects.child_responses;
        assert!(responses
            .windows(b"\x1b[?0u".len())
            .any(|w| w == b"\x1b[?0u"));
        assert!(responses
            .windows(b"\x1bP>|tinymux 0.1.0\x1b\\".len())
            .any(|w| w == b"\x1bP>|tinymux 0.1.0\x1b\\"));
        assert!(responses
            .windows(b"\x1b]11;rgb:11/11/1b\x1b\\".len())
            .any(|w| w == b"\x1b]11;rgb:11/11/1b\x1b\\"));
        assert!(responses
            .windows(b"\x1b[?1;2c".len())
            .any(|w| w == b"\x1b[?1;2c"));
        assert!(responses
            .windows(b"\x1bP0+r696e646e\x1b\\".len())
            .any(|w| w == b"\x1bP0+r696e646e\x1b\\"));
        assert!(effects.outer_passthrough.is_empty());
    }

    #[test]
    fn terminal_responder_reports_pane_local_cursor_position() {
        let mut protocol = ProtocolEngine::new(profile_xterm_256color());
        let effects = protocol.process(b"\x1b[6n\x1b[?6n", (2, 3));
        let responses = effects.child_responses;
        assert!(responses
            .windows(b"\x1b[3;4R".len())
            .any(|w| w == b"\x1b[3;4R"));
        assert!(responses
            .windows(b"\x1b[?3;4R".len())
            .any(|w| w == b"\x1b[?3;4R"));
    }

    #[test]
    fn terminal_responder_forwards_osc52_to_outer_terminal() {
        let mut protocol = ProtocolEngine::new(profile_xterm_256color());
        let effects = protocol.process(b"\x1b]52;c;SGVsbG8=\x1b\\", (0, 0));

        assert!(effects.child_responses.is_empty());
        assert_eq!(effects.outer_passthrough, b"\x1b]52;c;SGVsbG8=\x1b\\");
    }

    #[test]
    fn kitty_keyboard_queries_and_mode_stack_are_tracked() {
        let mut protocol = ProtocolEngine::new(profile_kitty());

        let initial = protocol.process(b"\x1b[?u", (0, 0));
        assert_eq!(initial.child_responses, b"\x1b[?0u");
        assert_eq!(initial.keyboard_flags, None);
        assert_eq!(protocol.kitty_keyboard_flags(), 0);

        let enabled = protocol.process(b"\x1b[>1u\x1b[?u", (0, 0));
        assert_eq!(enabled.child_responses, b"\x1b[?1u");
        assert_eq!(enabled.keyboard_flags, Some(1));
        assert_eq!(protocol.kitty_keyboard_flags(), 1);

        let restored = protocol.process(b"\x1b[<u\x1b[?u", (0, 0));
        assert_eq!(restored.child_responses, b"\x1b[?0u");
        assert_eq!(restored.keyboard_flags, Some(0));
        assert_eq!(protocol.kitty_keyboard_flags(), 0);
    }

    #[test]
    fn synchronized_update_mode_is_reported_and_tracked() {
        let mut protocol = ProtocolEngine::new(profile_kitty());

        let reset = protocol.process(b"\x1b[?2026$p", (0, 0));
        assert_eq!(reset.child_responses, b"\x1b[?2026;2$y");
        assert!(!protocol.synchronized_update());

        let enabled = protocol.process(b"\x1b[?2026h\x1b[?2026$p", (0, 0));
        assert_eq!(enabled.child_responses, b"\x1b[?2026;1$y");
        assert!(protocol.synchronized_update());

        let disabled = protocol.process(b"\x1b[?2026l\x1b[?2026$p", (0, 0));
        assert_eq!(disabled.child_responses, b"\x1b[?2026;2$y");
        assert!(!protocol.synchronized_update());
    }

    #[test]
    fn kitty_graphics_apc_is_placed_at_terminator_cursor() {
        let mut parser = vt100::Parser::new(5, 20, SCROLLBACK_LINES);
        let mut scanner = KittyGraphicsScanner::default();
        let sequence = b"\x1b_Ga=t,f=24;AAAA\x1b\\";
        let mut input = b"\x1b[3;5H".to_vec();
        input.extend_from_slice(sequence);
        input.extend_from_slice(b"\x1b[1;1H");
        let graphics = process_terminal_output(&mut parser, &mut scanner, true, &input);

        assert_eq!(
            graphics,
            vec![PlacedKittyGraphic {
                sequence: sequence.to_vec(),
                cursor_position: (2, 4),
            }]
        );
        assert_eq!(parser.screen().cursor_position(), (0, 0));
    }

    #[test]
    fn split_kitty_graphics_apc_is_placed_after_terminator() {
        let mut parser = vt100::Parser::new(5, 20, SCROLLBACK_LINES);
        let mut scanner = KittyGraphicsScanner::default();

        let first =
            process_terminal_output(&mut parser, &mut scanner, true, b"\x1b[2;4H\x1b_Ga=t;");
        assert!(first.is_empty());

        let second =
            process_terminal_output(&mut parser, &mut scanner, true, b"AAAA\x1b\\\x1b[1;1H");
        assert_eq!(
            second,
            vec![PlacedKittyGraphic {
                sequence: b"\x1b_Ga=t;AAAA\x1b\\".to_vec(),
                cursor_position: (1, 3),
            }]
        );
        assert_eq!(parser.screen().cursor_position(), (0, 0));
    }

    #[test]
    fn auto_keeps_implemented_common_profiles() {
        assert_eq!(
            TerminalConfig::select("auto", "xterm-256color")
                .unwrap()
                .term(),
            "xterm-256color"
        );
        assert_eq!(
            TerminalConfig::select("auto", "foot-direct")
                .unwrap()
                .term(),
            "foot-direct"
        );
        assert_eq!(
            TerminalConfig::select("auto", "tmux-256color")
                .unwrap()
                .term(),
            "tmux-256color"
        );
    }

    #[test]
    fn auto_keeps_implemented_fancy_profiles() {
        assert_eq!(
            TerminalConfig::select("auto", "xterm-ghostty")
                .unwrap()
                .term(),
            "xterm-ghostty"
        );
        assert_eq!(
            TerminalConfig::select("auto", "xterm-kitty")
                .unwrap()
                .term(),
            "xterm-kitty"
        );
    }

    #[test]
    fn forced_profiles_require_outer_support() {
        assert_eq!(
            TerminalConfig::select("xterm-ghostty", "xterm-ghostty")
                .unwrap()
                .term(),
            "xterm-ghostty"
        );

        let unsupported_by_outer = TerminalConfig::select("xterm-256color", "vt100")
            .unwrap_err()
            .to_string();
        assert!(unsupported_by_outer.contains("requires features"));
    }

    #[test]
    fn common_terminfo_aliases_are_normalized() {
        assert_eq!(
            profile_for_term("screen.xterm-256color").unwrap().term,
            "screen-256color"
        );
        assert_eq!(profile_for_term("kitty").unwrap().term, "xterm-kitty");
        assert_eq!(profile_for_term("iTerm2.app").unwrap().term, "iTerm2.app");
        assert_eq!(profile_for_term("vte-direct").unwrap().term, "vte-direct");
    }
}
