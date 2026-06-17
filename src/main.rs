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
use unicode_width::UnicodeWidthChar as _;
use vte::{Params, Perform};

const SECONDARY_ROWS: u16 = 9;
const DEFAULT_TOTAL_ROWS: u16 = 32;
const DEFAULT_MAIN_ROWS: u16 = DEFAULT_TOTAL_ROWS - SECONDARY_ROWS - 1;
const FLOOD_BATCH: usize = 1024 * 1024;
const BACKGROUND_FLUSH: Duration = Duration::from_millis(16);
const FLOOD_FLUSH: Duration = Duration::from_millis(8);
const SCROLLBACK_LINES: usize = 10_000;
const WHEEL_SCROLL_LINES: usize = 3;
const RICH_TERMINAL_ENV_VARS: &[&str] = &[
    "ALACRITTY_LOG",
    "ALACRITTY_SOCKET",
    "ALACRITTY_WINDOW_ID",
    "GHOSTTY_BIN_DIR",
    "GHOSTTY_RESOURCES_DIR",
    "ITERM2_COOKIE",
    "ITERM2_SQUELCH_MARK",
    "ITERM_PROFILE",
    "ITERM_SESSION_ID",
    "KITTY_INSTALLATION_DIR",
    "KITTY_LISTEN_ON",
    "KITTY_PID",
    "KITTY_WINDOW_ID",
    "KONSOLE_DBUS_SESSION",
    "KONSOLE_DBUS_SERVICE",
    "KONSOLE_DBUS_WINDOW",
    "KONSOLE_PROFILE_NAME",
    "KONSOLE_VERSION",
    "LC_TERMINAL",
    "LC_TERMINAL_VERSION",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "VTE_VERSION",
    "WEZTERM_CONFIG_FILE",
    "WEZTERM_EXECUTABLE",
    "WEZTERM_PANE",
    "WEZTERM_UNIX_SOCKET",
    "WT_PROFILE_ID",
    "WT_SESSION",
];

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

    #[arg(long, hide = true)]
    experimental_bottom_primary: bool,
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

fn non_graphics_profile_for(outer: TerminalProfile) -> TerminalProfile {
    if outer.features.color >= ColorLevel::Direct {
        profile_xterm_direct()
    } else if outer.features.color >= ColorLevel::Color256 {
        profile_xterm_256color()
    } else if outer.features.color >= ColorLevel::Color8 {
        profile_xterm()
    } else {
        profile_vt100()
    }
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
        let cols = cols.max(1);
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RenderMode {
    Composed,
    BottomPrimaryRegionProxy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TerminalRegion {
    top: u16,
    rows: u16,
    cols: u16,
}

impl TerminalRegion {
    fn for_pane(layout: Layout, id: PaneId, both_panes_active: bool) -> Self {
        let top = pane_top(layout, id, both_panes_active);
        let rows = if both_panes_active {
            layout.pane_rows(id)
        } else {
            layout.rows.max(1)
        };
        Self {
            top,
            rows: rows.max(1),
            cols: layout.cols,
        }
    }

    fn bottom(self) -> u16 {
        self.top.saturating_add(self.rows).saturating_sub(1)
    }

    fn map_row(self, local_row: u16) -> u16 {
        self.top
            .saturating_add(local_row.min(self.rows.saturating_sub(1)))
    }

    fn map_col(self, local_col: u16) -> u16 {
        local_col.saturating_add(1).min(self.cols.max(1))
    }
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct KittyGraphicsCursorMovement {
    rows: u16,
    cols: u16,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct KittyGraphicsPlacement {
    cursor_movement: Option<KittyGraphicsCursorMovement>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct KittyGraphicsCommand {
    placement: Option<KittyGraphicsPlacement>,
    more_chunks: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct KittyGraphicsCursorTracker {
    pending_placement: Option<KittyGraphicsPlacement>,
}

impl KittyGraphicsCursorTracker {
    fn complete_command(&mut self, sequence: &[u8]) -> Option<KittyGraphicsPlacement> {
        let command = parse_kitty_graphics_command(sequence)?;
        if command.more_chunks {
            if command.placement.is_some() {
                self.pending_placement = command.placement;
            }
            None
        } else {
            let placement = command.placement.or(self.pending_placement);
            self.pending_placement = None;
            placement
        }
    }
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

#[derive(Clone, Debug, Eq, PartialEq)]
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

#[derive(Default, Debug, Eq, PartialEq)]
struct BottomProxyOutput {
    host_bytes: Vec<u8>,
    child_responses: Vec<u8>,
    keyboard_flags: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct BottomRegionState {
    profile: TerminalProfile,
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    pending_wrap: bool,
    scroll_top: u16,
    scroll_bottom: u16,
    origin_mode: bool,
    saved_cursor: (u16, u16),
    alternate_screen: bool,
    mouse_tracking: bool,
    sgr_mouse: bool,
    bracketed_paste: bool,
    dcs_capture: Option<DcsCapture>,
    keyboard: KittyKeyboardState,
    keyboard_changed: bool,
    synchronized_update: bool,
}

impl BottomRegionState {
    fn new(profile: TerminalProfile, rows: u16, cols: u16) -> Self {
        let rows = rows.max(1);
        Self {
            profile,
            rows,
            cols: cols.max(1),
            cursor_row: 0,
            cursor_col: 0,
            pending_wrap: false,
            scroll_top: 0,
            scroll_bottom: rows - 1,
            origin_mode: false,
            saved_cursor: (0, 0),
            alternate_screen: false,
            mouse_tracking: false,
            sgr_mouse: false,
            bracketed_paste: false,
            dcs_capture: None,
            keyboard: KittyKeyboardState::default(),
            keyboard_changed: false,
            synchronized_update: false,
        }
    }

    fn resize(&mut self, rows: u16, cols: u16) {
        self.rows = rows.max(1);
        self.cols = cols.max(1);
        self.cursor_row = self.cursor_row.min(self.rows - 1);
        self.cursor_col = self.cursor_col.min(self.cols - 1);
        self.scroll_top = self.scroll_top.min(self.rows - 1);
        self.scroll_bottom = self.scroll_bottom.min(self.rows - 1);
        if self.scroll_bottom < self.scroll_top {
            self.scroll_top = 0;
            self.scroll_bottom = self.rows - 1;
        }
    }

    fn features(&self) -> TerminalFeatures {
        self.profile.features
    }

    fn mouse_mode_enabled(&self) -> bool {
        self.mouse_tracking
    }

    fn clamp_cursor(&mut self) {
        self.cursor_row = self.cursor_row.min(self.rows - 1);
        self.cursor_col = self.cursor_col.min(self.cols - 1);
    }

    fn set_cursor(&mut self, row: u16, col: u16) {
        self.pending_wrap = false;
        let base = if self.origin_mode { self.scroll_top } else { 0 };
        self.cursor_row = base.saturating_add(row).min(self.rows - 1);
        self.cursor_col = col.min(self.cols - 1);
    }

    fn linefeed(&mut self) {
        self.pending_wrap = false;
        if self.cursor_row == self.scroll_bottom {
            return;
        }
        self.cursor_row = self.cursor_row.saturating_add(1).min(self.rows - 1);
    }

    fn reverse_index(&mut self) {
        self.pending_wrap = false;
        if self.cursor_row == self.scroll_top {
            return;
        }
        self.cursor_row = self.cursor_row.saturating_sub(1);
    }

    fn carriage_return(&mut self) {
        self.pending_wrap = false;
        self.cursor_col = 0;
    }

    fn put_printed_char(&mut self, c: char) {
        let width = c.width().unwrap_or(0) as u16;
        if width == 0 {
            return;
        }
        if self.pending_wrap {
            self.cursor_col = 0;
            self.linefeed();
        }
        if self.cursor_col.saturating_add(width) >= self.cols {
            self.cursor_col = self.cols - 1;
            self.pending_wrap = true;
        } else {
            self.cursor_col += width;
            self.pending_wrap = false;
        }
    }

    fn apply_kitty_graphics_cursor_movement(&mut self, movement: KittyGraphicsCursorMovement) {
        if movement.rows == 0 || movement.cols == 0 {
            return;
        }
        self.pending_wrap = false;
        let (row, col) = kitty_graphics_cursor_after(self.cursor(), self.rows, self.cols, movement);
        self.cursor_row = row;
        self.cursor_col = col;
    }

    fn reset_local(&mut self) {
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.pending_wrap = false;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.origin_mode = false;
        self.saved_cursor = (0, 0);
        self.alternate_screen = false;
        self.mouse_tracking = false;
        self.sgr_mouse = false;
        self.bracketed_paste = false;
        self.keyboard = KittyKeyboardState::default();
        self.keyboard_changed = true;
        self.synchronized_update = false;
        self.dcs_capture = None;
    }

    fn input_mode_formatted(&self) -> Vec<u8> {
        let mut output = Vec::new();
        output.extend_from_slice(if self.mouse_tracking {
            b"\x1b[?1000h"
        } else {
            b"\x1b[?1000l"
        });
        output.extend_from_slice(if self.sgr_mouse {
            b"\x1b[?1006h"
        } else {
            b"\x1b[?1006l"
        });
        output.extend_from_slice(if self.bracketed_paste {
            b"\x1b[?2004h"
        } else {
            b"\x1b[?2004l"
        });
        output
    }
}

struct BottomRegionProxy {
    parser: vte::Parser,
    model: vt100::Parser,
    state: BottomRegionState,
    kitty_graphics: KittyGraphicsScanner,
    kitty_graphics_cursor: KittyGraphicsCursorTracker,
}

impl BottomRegionProxy {
    fn new(profile: TerminalProfile, region: TerminalRegion) -> Self {
        Self {
            parser: vte::Parser::new(),
            model: vt100::Parser::new(region.rows, region.cols, SCROLLBACK_LINES),
            state: BottomRegionState::new(profile, region.rows, region.cols),
            kitty_graphics: KittyGraphicsScanner::default(),
            kitty_graphics_cursor: KittyGraphicsCursorTracker::default(),
        }
    }

    fn resize(&mut self, region: TerminalRegion) {
        self.state.resize(region.rows, region.cols);
        self.model.screen_mut().set_size(region.rows, region.cols);
    }

    fn mouse_mode_enabled(&self) -> bool {
        self.state.mouse_mode_enabled()
    }

    fn keyboard_flags(&self) -> u16 {
        self.state.keyboard.flags()
    }

    fn input_mode_formatted(&self) -> Vec<u8> {
        self.state.input_mode_formatted()
    }

    fn process(&mut self, region: TerminalRegion, bytes: &[u8]) -> BottomProxyOutput {
        self.resize(region);
        let keyboard_before = self.state.keyboard.flags();
        let initial_cursor = self.state.cursor();
        let initial_scroll_region = self.state.scroll_region();
        let was_alternate_screen = self.model.screen().alternate_screen();
        let mut body = Vec::new();
        let mut child_responses = Vec::new();
        let mut segment_start = 0;
        for (idx, byte) in bytes.iter().enumerate() {
            let Some(sequence) = self.kitty_graphics.feed(*byte) else {
                continue;
            };
            self.advance_plain(
                region,
                &bytes[segment_start..=idx],
                &mut body,
                &mut child_responses,
            );
            if self.state.features().kitty_graphics {
                body.extend_from_slice(&sequence);
                if let Some(placement) = self.kitty_graphics_cursor.complete_command(&sequence) {
                    if let Some(movement) = placement.cursor_movement {
                        self.state.apply_kitty_graphics_cursor_movement(movement);
                        move_model_cursor(&mut self.model, self.state.cursor());
                    }
                }
            }
            segment_start = idx + 1;
        }
        self.advance_plain(
            region,
            &bytes[segment_start..],
            &mut body,
            &mut child_responses,
        );
        if was_alternate_screen && !self.model.screen().alternate_screen() {
            render_model_region(region, &self.model, &mut body);
        }

        BottomProxyOutput {
            host_bytes: wrap_region_output(
                region,
                initial_scroll_region,
                initial_cursor,
                self.state.cursor(),
                body,
            ),
            child_responses,
            keyboard_flags: if self.state.keyboard_changed
                && self.state.keyboard.flags() != keyboard_before
            {
                self.state.keyboard_changed = false;
                Some(self.state.keyboard.flags())
            } else {
                self.state.keyboard_changed = false;
                None
            },
        }
    }

    fn advance_plain(
        &mut self,
        region: TerminalRegion,
        bytes: &[u8],
        body: &mut Vec<u8>,
        child_responses: &mut Vec<u8>,
    ) {
        if bytes.is_empty() {
            return;
        }
        self.model.process(bytes);
        let mut responder = BottomRegionResponder {
            region,
            state: self.state.clone(),
            body: Vec::new(),
            child_responses: Vec::new(),
        };
        self.parser.advance(&mut responder, bytes);
        self.state = responder.state;
        body.extend(responder.body);
        child_responses.extend(responder.child_responses);
    }
}

impl BottomRegionState {
    fn cursor(&self) -> (u16, u16) {
        (self.cursor_row, self.cursor_col)
    }

    fn scroll_region(&self) -> (u16, u16) {
        (self.scroll_top, self.scroll_bottom)
    }
}

struct BottomRegionResponder {
    region: TerminalRegion,
    state: BottomRegionState,
    body: Vec<u8>,
    child_responses: Vec<u8>,
}

impl BottomRegionResponder {
    fn emit_cursor(&mut self) {
        let (row, col) = self.state.cursor();
        write!(
            self.body,
            "\x1b[{};{}H",
            self.region.map_row(row),
            self.region.map_col(col)
        )
        .expect("write to vec");
    }

    fn emit_clear_region(&mut self) {
        for row in self.region.top..=self.region.bottom() {
            write!(self.body, "\x1b[{row};1H\x1b[K").expect("write to vec");
        }
        self.emit_cursor();
    }

    fn emit_erase_display(&mut self, mode: u16) {
        match mode {
            0 => {
                let start = self.state.cursor_row;
                self.emit_cursor();
                self.body.extend_from_slice(b"\x1b[K");
                for row in start.saturating_add(1)..self.state.rows {
                    write!(self.body, "\x1b[{};1H\x1b[K", self.region.map_row(row))
                        .expect("write to vec");
                }
                self.emit_cursor();
            }
            1 => {
                for row in 0..self.state.cursor_row {
                    write!(self.body, "\x1b[{};1H\x1b[K", self.region.map_row(row))
                        .expect("write to vec");
                }
                self.emit_cursor();
                self.body.extend_from_slice(b"\x1b[1K");
                self.emit_cursor();
            }
            _ => self.emit_clear_region(),
        }
    }

    fn emit_scroll_region(&mut self) {
        let (top, bottom) = self.state.scroll_region();
        write!(
            self.body,
            "\x1b[{};{}r",
            self.region.map_row(top),
            self.region.map_row(bottom)
        )
        .expect("write to vec");
        self.emit_cursor();
    }

    fn set_mode(&mut self, params: &Params, enabled: bool) {
        for value in param_values(params) {
            match value {
                6 => {
                    self.state.origin_mode = enabled;
                    self.state.set_cursor(0, 0);
                    self.emit_cursor();
                }
                47 | 1047 | 1049 => {
                    self.state.alternate_screen = enabled;
                    self.state.set_cursor(0, 0);
                    self.emit_clear_region();
                }
                1000 | 1002 | 1003 => {
                    self.state.mouse_tracking = enabled;
                }
                1006 => {
                    self.state.sgr_mouse = enabled;
                }
                2004 => {
                    self.state.bracketed_paste = enabled;
                }
                2026 => {
                    self.state.synchronized_update = enabled;
                    append_csi_sequence(
                        &mut self.body,
                        params,
                        b"?",
                        if enabled { 'h' } else { 'l' },
                    );
                }
                _ => {}
            }
        }
    }

    fn respond_cursor_position(&mut self, private: bool) {
        let prefix = if private { "\x1b[?" } else { "\x1b[" };
        write!(
            self.child_responses,
            "{prefix}{};{}R",
            self.state.cursor_row + 1,
            self.state.cursor_col + 1
        )
        .expect("write to vec");
    }

    fn query_synchronized_update(&mut self) {
        let value = if self.state.synchronized_update { 1 } else { 2 };
        write!(self.child_responses, "\x1b[?2026;{value}$y").expect("write to vec");
    }

    fn query_keyboard_flags(&mut self) {
        let flags = if self.state.features().kitty_keyboard {
            self.state.keyboard.flags()
        } else {
            0
        };
        write!(self.child_responses, "\x1b[?{flags}u").expect("write to vec");
    }
}

impl Perform for BottomRegionResponder {
    fn print(&mut self, c: char) {
        let mut buf = [0_u8; 4];
        self.body
            .extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        self.state.put_printed_char(c);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            b'\x07' => self.body.push(byte),
            b'\x08' => {
                self.state.pending_wrap = false;
                self.state.cursor_col = self.state.cursor_col.saturating_sub(1);
                self.body.push(byte);
            }
            b'\x09' => {
                self.state.pending_wrap = false;
                let next_tab = ((self.state.cursor_col / 8) + 1) * 8;
                self.state.cursor_col = next_tab.min(self.state.cols - 1);
                self.body.push(byte);
            }
            b'\n' | 0x0b | 0x0c => {
                self.state.linefeed();
                self.body.push(byte);
            }
            b'\r' => {
                self.state.carriage_return();
                self.body.push(byte);
            }
            _ => {}
        }
    }

    fn hook(&mut self, _params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        if !ignore && self.state.features().xtgetcap && intermediates == b"+" && action == 'q' {
            self.state.dcs_capture = Some(DcsCapture {
                intermediates: intermediates.to_vec(),
                action,
                payload: Vec::new(),
            });
        } else {
            self.state.dcs_capture = None;
        }
    }

    fn put(&mut self, byte: u8) {
        if let Some(capture) = &mut self.state.dcs_capture {
            capture.payload.push(byte);
        }
    }

    fn unhook(&mut self) {
        let Some(capture) = self.state.dcs_capture.take() else {
            return;
        };
        if self.state.features().xtgetcap && capture.intermediates == b"+" && capture.action == 'q'
        {
            self.child_responses.extend_from_slice(b"\x1bP0+r");
            self.child_responses.extend_from_slice(&capture.payload);
            self.child_responses.extend_from_slice(b"\x1b\\");
        }
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        if self.state.features().osc_color_query {
            append_osc_color_response(params, b"10", b"rgb:cd/d6/f4", &mut self.child_responses);
            append_osc_color_response(params, b"11", b"rgb:11/11/1b", &mut self.child_responses);
            append_osc_color_response(params, b"12", b"7", &mut self.child_responses);
        }
        if self.state.features().osc52 && matches_osc_command(params, b"52") {
            append_osc_sequence(&mut self.body, params, bell_terminated);
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        if ignore || !self.state.features().xterm_protocols {
            return;
        }

        match (intermediates, action) {
            (b"", 'm') => append_csi_sequence(&mut self.body, params, intermediates, action),
            (b"", 'H' | 'f') => {
                let row = param_or(params, 0, 1).saturating_sub(1);
                let col = param_or(params, 1, 1).saturating_sub(1);
                self.state.set_cursor(row, col);
                self.emit_cursor();
            }
            (b"", 'A') => {
                let amount = param_or(params, 0, 1);
                self.state.pending_wrap = false;
                self.state.cursor_row = self.state.cursor_row.saturating_sub(amount);
                self.emit_cursor();
            }
            (b"", 'B') => {
                let amount = param_or(params, 0, 1);
                self.state.pending_wrap = false;
                self.state.cursor_row = self
                    .state
                    .cursor_row
                    .saturating_add(amount)
                    .min(self.state.rows - 1);
                self.emit_cursor();
            }
            (b"", 'C') => {
                let amount = param_or(params, 0, 1);
                self.state.pending_wrap = false;
                self.state.cursor_col = self
                    .state
                    .cursor_col
                    .saturating_add(amount)
                    .min(self.state.cols - 1);
                self.emit_cursor();
            }
            (b"", 'D') => {
                let amount = param_or(params, 0, 1);
                self.state.pending_wrap = false;
                self.state.cursor_col = self.state.cursor_col.saturating_sub(amount);
                self.emit_cursor();
            }
            (b"", 'E') => {
                let amount = param_or(params, 0, 1);
                self.state.pending_wrap = false;
                self.state.cursor_row = self
                    .state
                    .cursor_row
                    .saturating_add(amount)
                    .min(self.state.rows - 1);
                self.state.cursor_col = 0;
                self.emit_cursor();
            }
            (b"", 'F') => {
                let amount = param_or(params, 0, 1);
                self.state.pending_wrap = false;
                self.state.cursor_row = self.state.cursor_row.saturating_sub(amount);
                self.state.cursor_col = 0;
                self.emit_cursor();
            }
            (b"", 'G') => {
                self.state.pending_wrap = false;
                self.state.cursor_col = param_or(params, 0, 1)
                    .saturating_sub(1)
                    .min(self.state.cols - 1);
                self.emit_cursor();
            }
            (b"", 'd') => {
                self.state.pending_wrap = false;
                self.state.cursor_row = param_or(params, 0, 1)
                    .saturating_sub(1)
                    .min(self.state.rows - 1);
                self.emit_cursor();
            }
            (b"", 'J') => self.emit_erase_display(first_param(params)),
            (b"", 'K') => {
                self.emit_cursor();
                append_csi_sequence(&mut self.body, params, intermediates, action);
                self.emit_cursor();
            }
            (b"", 'r') => {
                let top = param_or(params, 0, 1)
                    .saturating_sub(1)
                    .min(self.state.rows - 1);
                let bottom = param_or(params, 1, self.state.rows)
                    .saturating_sub(1)
                    .min(self.state.rows - 1);
                if top < bottom {
                    self.state.scroll_top = top;
                    self.state.scroll_bottom = bottom;
                } else {
                    self.state.scroll_top = 0;
                    self.state.scroll_bottom = self.state.rows - 1;
                }
                self.state.set_cursor(0, 0);
                self.emit_scroll_region();
            }
            (b"", 's') => self.state.saved_cursor = self.state.cursor(),
            (b"", 'u') => {
                let (row, col) = self.state.saved_cursor;
                self.state.cursor_row = row;
                self.state.cursor_col = col;
                self.state.pending_wrap = false;
                self.state.clamp_cursor();
                self.emit_cursor();
            }
            (b"", 'c') if first_param_is(params, 0) => {
                self.child_responses.extend_from_slice(b"\x1b[?1;2c");
            }
            (b">", 'c') if first_param_is(params, 0) => {
                self.child_responses.extend_from_slice(b"\x1b[>0;95;0c");
            }
            (b"", 'n') if first_param_is(params, 6) => self.respond_cursor_position(false),
            (b"?", 'n') if first_param_is(params, 6) => self.respond_cursor_position(true),
            (b"?", 'h') => self.set_mode(params, true),
            (b"?", 'l') => self.set_mode(params, false),
            (b"?", 'u') => self.query_keyboard_flags(),
            (b">", 'u') if self.state.features().kitty_keyboard => {
                self.state.keyboard.push(first_param(params));
                self.state.keyboard_changed = true;
            }
            (b"<", 'u') if self.state.features().kitty_keyboard => {
                self.state.keyboard.pop(first_param(params).max(1));
                self.state.keyboard_changed = true;
            }
            (b"?$", 'p') if first_param_is(params, 2026) => self.query_synchronized_update(),
            (b">", 'q') if self.state.features().xtversion && first_param_is(params, 0) => {
                self.child_responses
                    .extend_from_slice(b"\x1bP>|tinymux 0.1.0\x1b\\");
            }
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
        if ignore || !intermediates.is_empty() {
            return;
        }
        match byte {
            b'7' => self.state.saved_cursor = self.state.cursor(),
            b'8' => {
                let (row, col) = self.state.saved_cursor;
                self.state.cursor_row = row;
                self.state.cursor_col = col;
                self.state.pending_wrap = false;
                self.state.clamp_cursor();
                self.emit_cursor();
            }
            b'D' => {
                self.state.linefeed();
                self.body.extend_from_slice(b"\x1bD");
            }
            b'E' => {
                self.state.linefeed();
                self.state.carriage_return();
                self.body.extend_from_slice(b"\x1bE");
            }
            b'M' => {
                self.state.reverse_index();
                self.body.extend_from_slice(b"\x1bM");
            }
            b'c' => {
                self.state.reset_local();
                self.emit_clear_region();
            }
            _ => {}
        }
    }
}

fn configure_pane_command_environment(
    cmd: &mut CommandBuilder,
    profile: TerminalProfile,
    shell: &str,
) {
    cmd.env("TERM", profile.term);
    cmd.env("SHELL", shell);
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
    } else if profile.features.color >= ColorLevel::Direct {
        cmd.env("COLORTERM", "truecolor");
    }

    if !profile.features.kitty_graphics {
        for name in RICH_TERMINAL_ENV_VARS {
            cmd.env_remove(name);
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
    kitty_graphics_cursor: KittyGraphicsCursorTracker,
    pending_kitty_graphics: Vec<PlacedKittyGraphic>,
}

impl Pane {
    fn spawn(
        id: PaneId,
        command: &str,
        layout: Layout,
        tx: Sender<Event>,
        profile: TerminalProfile,
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
        configure_pane_command_environment(&mut cmd, profile, &shell);

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
            protocol: ProtocolEngine::new(profile),
            writer,
            master: pair.master,
            reader_eof: false,
            exit_status: None,
            kitty_graphics: KittyGraphicsScanner::default(),
            kitty_graphics_cursor: KittyGraphicsCursorTracker::default(),
            pending_kitty_graphics: Vec::new(),
        })
    }

    fn process_output(&mut self, bytes: &[u8]) -> Vec<PlacedKittyGraphic> {
        process_terminal_output(
            &mut self.parser,
            &mut self.kitty_graphics,
            &mut self.kitty_graphics_cursor,
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
    render_mode: RenderMode,
    layout: Layout,
    panes: [Option<Pane>; 2],
    bottom_proxy: Option<BottomRegionProxy>,
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
        let render_mode = if args.experimental_bottom_primary {
            RenderMode::BottomPrimaryRegionProxy
        } else {
            RenderMode::Composed
        };
        let main_profile = match render_mode {
            RenderMode::Composed => terminal.advertised_profile,
            RenderMode::BottomPrimaryRegionProxy => {
                non_graphics_profile_for(terminal.advertised_profile)
            }
        };
        let secondary_profile = terminal.advertised_profile;
        let main = Pane::spawn(PaneId::Main, &args.main, layout, tx.clone(), main_profile)?;
        let secondary = Pane::spawn(
            PaneId::Secondary,
            &args.secondary,
            layout,
            tx,
            secondary_profile,
        )?;
        let bottom_proxy = match render_mode {
            RenderMode::Composed => None,
            RenderMode::BottomPrimaryRegionProxy => Some(BottomRegionProxy::new(
                secondary_profile,
                TerminalRegion::for_pane(layout, PaneId::Secondary, true),
            )),
        };
        let outer_keyboard_layer_active =
            main_profile.features.kitty_keyboard || secondary_profile.features.kitty_keyboard;
        let mut outer_passthrough = Vec::new();
        if outer_keyboard_layer_active {
            outer_passthrough.extend_from_slice(b"\x1b[>0u");
        }
        Ok(Self {
            render_mode,
            layout,
            panes: [Some(main), Some(secondary)],
            bottom_proxy,
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
        if self.render_mode == RenderMode::BottomPrimaryRegionProxy
            && self.focus == PaneId::Secondary
        {
            return self
                .bottom_proxy
                .as_ref()
                .map(BottomRegionProxy::keyboard_flags)
                .unwrap_or(0);
        }
        self.focused_pane()
            .map(|(_, pane)| pane.protocol.kitty_keyboard_flags())
            .unwrap_or(0)
    }

    fn region_for_pane(&self, id: PaneId) -> TerminalRegion {
        TerminalRegion::for_pane(self.layout, id, self.both_panes_active())
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
            if id == PaneId::Secondary {
                self.bottom_proxy = None;
            }
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
        let secondary_region = self.region_for_pane(PaneId::Secondary);
        if let Some(proxy) = &mut self.bottom_proxy {
            proxy.resize(secondary_region);
        }
        Ok(())
    }

    fn handle_event(&mut self, event: Event) -> Result<bool> {
        match event {
            Event::PaneOutput(id, bytes) => {
                if self.pane(id).is_none() {
                    return Ok(true);
                }
                if self.render_mode == RenderMode::BottomPrimaryRegionProxy
                    && id == PaneId::Secondary
                {
                    self.handle_bottom_primary_output(&bytes)?;
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

    fn handle_bottom_primary_output(&mut self, bytes: &[u8]) -> Result<()> {
        self.pending_bytes += bytes.len();
        if let Some(pane) = self.pane_mut(PaneId::Secondary) {
            pane.parser.process(bytes);
        }
        let region = self.region_for_pane(PaneId::Secondary);
        let Some(proxy) = &mut self.bottom_proxy else {
            return Ok(());
        };
        let output = proxy.process(region, bytes);
        if !output.child_responses.is_empty() {
            let pane = self
                .pane_mut(PaneId::Secondary)
                .expect("secondary pane checked above");
            pane.writer.write_all(&output.child_responses)?;
            pane.writer.flush()?;
        }
        self.outer_passthrough.extend(output.host_bytes);
        if self.focus == PaneId::Secondary {
            if let Some(flags) = output.keyboard_flags {
                self.sync_outer_keyboard(flags);
            }
        }
        Ok(())
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
        let Some(id) = self.pane_at_row(event.row) else {
            return Ok(true);
        };
        if self.render_mode == RenderMode::BottomPrimaryRegionProxy
            && id == PaneId::Secondary
            && self
                .bottom_proxy
                .as_ref()
                .map(BottomRegionProxy::mouse_mode_enabled)
                .unwrap_or(false)
        {
            let region = self.region_for_pane(PaneId::Secondary);
            let local_row = event.row.saturating_sub(region.top).saturating_add(1);
            let local_event = SgrMouseEvent {
                row: local_row.min(region.rows),
                ..event
            };
            if let Some(pane) = self.pane_mut(PaneId::Secondary) {
                pane.writer.write_all(&encode_sgr_mouse(local_event))?;
            }
            return Ok(true);
        }
        let Some(direction) = event.wheel_direction() else {
            return Ok(false);
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
        let had_passthrough = !self.outer_passthrough.is_empty();
        let had_post_render = !self.outer_post_render.is_empty();
        if !self.outer_passthrough.is_empty() {
            out.write_all(&self.outer_passthrough)?;
            self.outer_passthrough.clear();
        }
        let bottom_primary_active = self.render_mode == RenderMode::BottomPrimaryRegionProxy
            && self.pane(PaneId::Secondary).is_some();
        if had_dirty && !self.rendered_once && !bottom_primary_active {
            out.write_all(b"\x1b[H\x1b[2J")?;
            self.rendered_once = true;
            self.last_rows.clear();
        }
        if had_dirty {
            if !self.rendered_once {
                self.rendered_once = true;
                self.last_rows.clear();
            }
            let rows = if bottom_primary_active {
                compose_top_region_rows(self.layout, self.pane(PaneId::Main), self.focus)
            } else {
                compose_rows(
                    self.layout,
                    self.pane(PaneId::Main),
                    self.pane(PaneId::Secondary),
                    self.focus,
                )
            };
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
        if had_dirty || had_passthrough || had_post_render {
            if let Some((id, pane)) = self.focused_pane() {
                if self.render_mode == RenderMode::BottomPrimaryRegionProxy
                    && id == PaneId::Secondary
                {
                    if let Some(proxy) = &self.bottom_proxy {
                        render_bottom_proxy_cursor(
                            out,
                            self.region_for_pane(PaneId::Secondary),
                            proxy,
                        )?;
                        out.write_all(&proxy.input_mode_formatted())?;
                    }
                } else {
                    render_focused_cursor(
                        out,
                        self.layout,
                        pane,
                        pane_top(self.layout, id, self.both_panes_active()),
                    )?;
                    render_input_modes(out, pane)?;
                }
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

fn encode_sgr_mouse(event: SgrMouseEvent) -> Vec<u8> {
    format!(
        "\x1b[<{};{};{}{}",
        event.button,
        event.col,
        event.row,
        if event.pressed { 'M' } else { 'm' }
    )
    .into_bytes()
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

fn parse_u16_saturating_ascii(bytes: &[u8]) -> Option<u16> {
    if bytes.is_empty() {
        return None;
    }
    let mut value = 0_u32;
    for byte in bytes {
        if !byte.is_ascii_digit() {
            return None;
        }
        value = value
            .saturating_mul(10)
            .saturating_add(u32::from(byte - b'0'));
    }
    Some(value.min(u32::from(u16::MAX)) as u16)
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

fn compose_top_region_rows(layout: Layout, main: Option<&Pane>, focus: PaneId) -> Vec<Vec<u8>> {
    let mut rows = Vec::with_capacity(layout.border_row as usize);
    if let Some(main) = main {
        append_pane_rows(&mut rows, layout.main_rows, layout.cols, main);
        if layout.rows >= 2 {
            rows.push(border_row_body(layout, focus));
        }
    }
    rows.truncate(layout.border_row as usize);
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

fn render_bottom_proxy_cursor<W: Write>(
    out: &mut W,
    region: TerminalRegion,
    proxy: &BottomRegionProxy,
) -> Result<()> {
    let (row, col) = proxy.state.cursor();
    write!(out, "\x1b[{};{}H", region.map_row(row), region.map_col(col))?;
    Ok(())
}

fn render_model_region(region: TerminalRegion, parser: &vt100::Parser, output: &mut Vec<u8>) {
    for (idx, row) in parser
        .screen()
        .rows_formatted(0, region.cols)
        .take(region.rows as usize)
        .enumerate()
    {
        write!(output, "\x1b[{};1H", region.map_row(idx as u16)).expect("write to vec");
        output.extend(row);
        output.extend_from_slice(b"\x1b[m\x1b[K");
    }
    let (row, col) = parser.screen().cursor_position();
    write!(
        output,
        "\x1b[{};{}H",
        region.map_row(row),
        region.map_col(col)
    )
    .expect("write to vec");
}

fn process_terminal_output(
    parser: &mut vt100::Parser,
    graphics_scanner: &mut KittyGraphicsScanner,
    graphics_cursor: &mut KittyGraphicsCursorTracker,
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
        let cursor_position = parser.screen().cursor_position();
        let placement = graphics_cursor.complete_command(&sequence);
        graphics.push(PlacedKittyGraphic {
            sequence,
            cursor_position,
        });
        if let Some(movement) = placement.and_then(|placement| placement.cursor_movement) {
            move_parser_after_kitty_graphics(parser, movement);
        }
        segment_start = idx + 1;
    }
    if segment_start < bytes.len() {
        parser.process(&bytes[segment_start..]);
    }
    graphics
}

fn move_model_cursor(parser: &mut vt100::Parser, cursor: (u16, u16)) {
    let mut bytes = Vec::new();
    write!(bytes, "\x1b[{};{}H", cursor.0 + 1, cursor.1 + 1).expect("write to vec");
    parser.process(&bytes);
}

fn move_parser_after_kitty_graphics(
    parser: &mut vt100::Parser,
    movement: KittyGraphicsCursorMovement,
) {
    let (screen_rows, screen_cols) = parser.screen().size();
    let cursor = parser.screen().cursor_position();
    move_model_cursor(
        parser,
        kitty_graphics_cursor_after(cursor, screen_rows, screen_cols, movement),
    );
}

fn kitty_graphics_cursor_after(
    cursor: (u16, u16),
    screen_rows: u16,
    screen_cols: u16,
    movement: KittyGraphicsCursorMovement,
) -> (u16, u16) {
    (
        cursor
            .0
            .saturating_add(movement.rows.saturating_sub(1))
            .min(screen_rows.saturating_sub(1)),
        cursor
            .1
            .saturating_add(movement.cols)
            .min(screen_cols.saturating_sub(1)),
    )
}

fn parse_kitty_graphics_command(sequence: &[u8]) -> Option<KittyGraphicsCommand> {
    let mut body = if sequence.starts_with(b"\x1b_G") {
        &sequence[3..]
    } else if sequence.starts_with(&[0x9f, b'G']) {
        &sequence[2..]
    } else {
        return None;
    };

    body = if body.ends_with(b"\x1b\\") {
        &body[..body.len().saturating_sub(2)]
    } else if body.ends_with(&[0x9c]) {
        &body[..body.len().saturating_sub(1)]
    } else {
        body
    };

    let control = body
        .iter()
        .position(|byte| *byte == b';')
        .map(|idx| &body[..idx])
        .unwrap_or(body);
    let mut action = b't';
    let mut cols = 0;
    let mut rows = 0;
    let mut no_cursor_movement = false;
    let mut virtual_placement = false;
    let mut relative_placement = false;
    let mut more_chunks = false;

    for part in control.split(|byte| *byte == b',') {
        let Some((key, value)) = split_kitty_graphics_key_value(part) else {
            continue;
        };
        match key {
            b'a' => {
                if let Some(value) = value.first() {
                    action = *value;
                }
            }
            b'c' => cols = parse_u16_saturating_ascii(value).unwrap_or(0),
            b'r' => rows = parse_u16_saturating_ascii(value).unwrap_or(0),
            b'C' => no_cursor_movement = parse_u16_saturating_ascii(value).unwrap_or(0) == 1,
            b'U' => virtual_placement = parse_u16_saturating_ascii(value).unwrap_or(0) == 1,
            b'P' | b'Q' => {
                relative_placement |= parse_u16_saturating_ascii(value).unwrap_or(0) != 0;
            }
            b'm' => more_chunks = parse_u16_saturating_ascii(value).unwrap_or(0) != 0,
            _ => {}
        }
    }

    let places_image = matches!(action, b'T' | b'p') && !virtual_placement && !relative_placement;
    let placement = places_image.then(|| KittyGraphicsPlacement {
        cursor_movement: (!no_cursor_movement && rows > 0 && cols > 0)
            .then_some(KittyGraphicsCursorMovement { rows, cols }),
    });

    Some(KittyGraphicsCommand {
        placement,
        more_chunks,
    })
}

fn split_kitty_graphics_key_value(part: &[u8]) -> Option<(u8, &[u8])> {
    let idx = part.iter().position(|byte| *byte == b'=')?;
    let (key, value_with_separator) = part.split_at(idx);
    let value = &value_with_separator[1..];
    if key.len() == 1 {
        Some((key[0], value))
    } else {
        None
    }
}

fn first_param(params: &Params) -> u16 {
    params
        .iter()
        .next()
        .and_then(|param| param.first())
        .copied()
        .unwrap_or(0)
}

fn param_or(params: &Params, index: usize, default: u16) -> u16 {
    params
        .iter()
        .nth(index)
        .and_then(|param| param.first())
        .copied()
        .filter(|value| *value != 0)
        .unwrap_or(default)
}

fn param_values(params: &Params) -> Vec<u16> {
    params
        .iter()
        .filter_map(|param| param.first().copied())
        .collect()
}

fn first_param_is(params: &Params, expected: u16) -> bool {
    first_param(params) == expected
}

fn append_csi_sequence(output: &mut Vec<u8>, params: &Params, intermediates: &[u8], action: char) {
    output.extend_from_slice(b"\x1b[");
    for (param_index, param) in params.iter().enumerate() {
        if param_index > 0 {
            output.push(b';');
        }
        for (sub_index, value) in param.iter().enumerate() {
            if sub_index > 0 {
                output.push(b':');
            }
            write!(output, "{value}").expect("write to vec");
        }
    }
    output.extend_from_slice(intermediates);
    let mut buf = [0_u8; 4];
    output.extend_from_slice(action.encode_utf8(&mut buf).as_bytes());
}

fn wrap_region_output(
    region: TerminalRegion,
    scroll_region: (u16, u16),
    cursor: (u16, u16),
    final_cursor: (u16, u16),
    body: Vec<u8>,
) -> Vec<u8> {
    if body.is_empty() {
        return body;
    }
    let mut output = Vec::with_capacity(body.len() + 64);
    let (scroll_top, scroll_bottom) = scroll_region;
    let (cursor_row, cursor_col) = cursor;
    write!(
        output,
        "\x1b[{};{}r\x1b[{};{}H",
        region.map_row(scroll_top),
        region.map_row(scroll_bottom),
        region.map_row(cursor_row),
        region.map_col(cursor_col)
    )
    .expect("write to vec");
    output.extend(body);
    let (final_row, final_col) = final_cursor;
    write!(
        output,
        "\x1b[r\x1b[{};{}H",
        region.map_row(final_row),
        region.map_col(final_col)
    )
    .expect("write to vec");
    output
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

    fn selected_term(requested: &str, host: &str) -> &'static str {
        TerminalConfig::select(requested, host)
            .unwrap()
            .advertised_profile
            .term
    }

    fn test_bottom_region() -> TerminalRegion {
        TerminalRegion {
            top: 24,
            rows: 9,
            cols: 80,
        }
    }

    fn screen_rows(parser: &vt100::Parser, start: u16, rows: u16, cols: u16) -> Vec<String> {
        parser
            .screen()
            .rows(0, cols)
            .skip(start as usize)
            .take(rows as usize)
            .collect()
    }

    fn seed_host_top_region(host: &mut vt100::Parser, region: TerminalRegion) -> Vec<String> {
        let mut bytes = Vec::new();
        for row in 1..region.top {
            write!(bytes, "\x1b[{row};1HTOP-SENTINEL-{row:02}").expect("write to vec");
        }
        host.process(&bytes);
        screen_rows(host, 0, region.top.saturating_sub(1), region.cols)
    }

    fn assert_bottom_proxy_matches_direct_terminal(name: &str, chunks: &[&[u8]]) {
        let region = test_bottom_region();
        let mut proxy = BottomRegionProxy::new(profile_ghostty(), region);
        let mut direct = vt100::Parser::new(region.rows, region.cols, SCROLLBACK_LINES);
        let mut direct_graphics = KittyGraphicsScanner::default();
        let mut direct_graphics_cursor = KittyGraphicsCursorTracker::default();
        let mut host = vt100::Parser::new(region.bottom(), region.cols, SCROLLBACK_LINES);
        let mut host_graphics = KittyGraphicsScanner::default();
        let mut host_graphics_cursor = KittyGraphicsCursorTracker::default();
        let top_before = seed_host_top_region(&mut host, region);

        for (idx, chunk) in chunks.iter().enumerate() {
            let expected_graphics = process_terminal_output(
                &mut direct,
                &mut direct_graphics,
                &mut direct_graphics_cursor,
                true,
                chunk,
            );
            let output = proxy.process(region, chunk);
            let actual_graphics = process_terminal_output(
                &mut host,
                &mut host_graphics,
                &mut host_graphics_cursor,
                true,
                &output.host_bytes,
            );

            let expected = screen_rows(&direct, 0, region.rows, region.cols);
            let actual = screen_rows(&host, region.top - 1, region.rows, region.cols);
            assert_eq!(
                actual,
                expected,
                "{name}: bottom-region mismatch after chunk {idx}; host bytes: {:?}",
                String::from_utf8_lossy(&output.host_bytes)
            );

            let top_after = screen_rows(&host, 0, region.top - 1, region.cols);
            assert_eq!(
                top_after,
                top_before,
                "{name}: top region changed after chunk {idx}; host bytes: {:?}",
                String::from_utf8_lossy(&output.host_bytes)
            );

            let expected_graphics = expected_graphics
                .into_iter()
                .map(|graphic| PlacedKittyGraphic {
                    sequence: graphic.sequence,
                    cursor_position: (
                        region.top - 1 + graphic.cursor_position.0,
                        graphic.cursor_position.1,
                    ),
                })
                .collect::<Vec<_>>();
            assert_eq!(
                actual_graphics,
                expected_graphics,
                "{name}: kitty graphics mismatch after chunk {idx}; host bytes: {:?}",
                String::from_utf8_lossy(&output.host_bytes)
            );

            if !output.host_bytes.is_empty() {
                let (direct_row, direct_col) = direct.screen().cursor_position();
                let (host_row, host_col) = host.screen().cursor_position();
                assert_eq!(
                    (host_row, host_col),
                    (region.top - 1 + direct_row, direct_col),
                    "{name}: cursor mismatch after chunk {idx}"
                );
            }
        }
    }

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
    fn layout_clamps_zero_columns() {
        assert_eq!(Layout::new(32, 0).cols, 1);
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
        let mut cursor = KittyGraphicsCursorTracker::default();
        let sequence = b"\x1b_Ga=T,f=24,c=4,r=2;AAAA\x1b\\";
        let mut input = b"\x1b[3;5H".to_vec();
        input.extend_from_slice(sequence);
        input.extend_from_slice(b"\x1b[1;1H");
        let graphics =
            process_terminal_output(&mut parser, &mut scanner, &mut cursor, true, &input);

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
        let mut cursor = KittyGraphicsCursorTracker::default();

        let first = process_terminal_output(
            &mut parser,
            &mut scanner,
            &mut cursor,
            true,
            b"\x1b[2;4H\x1b_Ga=T,c=4,r=2;",
        );
        assert!(first.is_empty());

        let second = process_terminal_output(
            &mut parser,
            &mut scanner,
            &mut cursor,
            true,
            b"AAAA\x1b\\\x1b[1;1H",
        );
        assert_eq!(
            second,
            vec![PlacedKittyGraphic {
                sequence: b"\x1b_Ga=T,c=4,r=2;AAAA\x1b\\".to_vec(),
                cursor_position: (1, 3),
            }]
        );
        assert_eq!(parser.screen().cursor_position(), (0, 0));
    }

    #[test]
    fn kitty_graphics_default_cursor_movement_matches_placement_rectangle() {
        let mut parser = vt100::Parser::new(8, 20, SCROLLBACK_LINES);
        let mut scanner = KittyGraphicsScanner::default();
        let mut cursor = KittyGraphicsCursorTracker::default();
        let graphics = process_terminal_output(
            &mut parser,
            &mut scanner,
            &mut cursor,
            true,
            b"\x1b[2;3H\x1b_Ga=T,c=4,r=3;AAAA\x1b\\",
        );

        assert_eq!(graphics[0].cursor_position, (1, 2));
        assert_eq!(parser.screen().cursor_position(), (3, 6));
    }

    #[test]
    fn kitty_graphics_c1_suppresses_cursor_movement() {
        let mut parser = vt100::Parser::new(8, 20, SCROLLBACK_LINES);
        let mut scanner = KittyGraphicsScanner::default();
        let mut cursor = KittyGraphicsCursorTracker::default();
        process_terminal_output(
            &mut parser,
            &mut scanner,
            &mut cursor,
            true,
            b"\x1b[2;3H\x1b_Ga=T,c=4,r=3,C=1;AAAA\x1b\\",
        );

        assert_eq!(parser.screen().cursor_position(), (1, 2));
    }

    #[test]
    fn kitty_graphics_chunked_transfer_moves_cursor_on_final_chunk() {
        let mut cursor = KittyGraphicsCursorTracker::default();

        assert_eq!(
            cursor.complete_command(b"\x1b_Ga=T,c=4,r=3,m=1;AAAA\x1b\\"),
            None
        );
        assert_eq!(
            cursor.complete_command(b"\x1b_Gm=0;BBBB\x1b\\"),
            Some(KittyGraphicsPlacement {
                cursor_movement: Some(KittyGraphicsCursorMovement { rows: 3, cols: 4 }),
            })
        );
    }

    #[test]
    fn bottom_primary_downgrades_top_profile_only() {
        let host = profile_ghostty();
        let top = non_graphics_profile_for(host);

        assert_eq!(top.term, "xterm-direct");
        assert!(!top.features.kitty_graphics);
        assert!(!top.features.kitty_keyboard);
        assert!(host.features.kitty_graphics);
        assert!(host.features.kitty_keyboard);
    }

    #[test]
    fn non_graphics_pane_profile_strips_rich_terminal_identity_env() {
        let mut cmd = CommandBuilder::new("sh");
        cmd.env("TERM_PROGRAM", "ghostty");
        cmd.env("TERM_PROGRAM_VERSION", "1.3.2");
        cmd.env("KITTY_WINDOW_ID", "7");

        configure_pane_command_environment(&mut cmd, profile_xterm_direct(), "/bin/sh");

        assert_eq!(
            cmd.get_env("TERM").and_then(|value| value.to_str()),
            Some("xterm-direct")
        );
        assert!(cmd.get_env("TERM_PROGRAM").is_none());
        assert!(cmd.get_env("TERM_PROGRAM_VERSION").is_none());
        assert!(cmd.get_env("KITTY_WINDOW_ID").is_none());
    }

    #[test]
    fn graphics_pane_profile_preserves_rich_terminal_identity_env() {
        let mut cmd = CommandBuilder::new("sh");
        cmd.env("TERM_PROGRAM", "ghostty");
        cmd.env("TERM_PROGRAM_VERSION", "1.3.2");

        configure_pane_command_environment(&mut cmd, profile_ghostty(), "/bin/sh");

        assert_eq!(
            cmd.get_env("TERM").and_then(|value| value.to_str()),
            Some("xterm-ghostty")
        );
        assert_eq!(
            cmd.get_env("TERM_PROGRAM").and_then(|value| value.to_str()),
            Some("ghostty")
        );
        assert_eq!(
            cmd.get_env("TERM_PROGRAM_VERSION")
                .and_then(|value| value.to_str()),
            Some("1.3.2")
        );
    }

    #[test]
    fn bottom_region_proxy_localizes_clear_and_reset() {
        let region = test_bottom_region();
        let mut proxy = BottomRegionProxy::new(profile_ghostty(), region);
        let output = proxy.process(region, b"abc\x1b[2J\x1bc");

        assert!(!output
            .host_bytes
            .windows(b"\x1b[2J".len())
            .any(|w| w == b"\x1b[2J"));
        assert!(!output
            .host_bytes
            .windows(b"\x1bc".len())
            .any(|w| w == b"\x1bc"));
        assert!(output
            .host_bytes
            .windows(b"\x1b[24;1H\x1b[K".len())
            .any(|w| w == b"\x1b[24;1H\x1b[K"));
        assert!(output
            .host_bytes
            .windows(b"\x1b[32;1H\x1b[K".len())
            .any(|w| w == b"\x1b[32;1H\x1b[K"));
    }

    #[test]
    fn bottom_region_proxy_maps_cursor_and_scroll_region() {
        let region = test_bottom_region();
        let mut proxy = BottomRegionProxy::new(profile_ghostty(), region);
        let output = proxy.process(region, b"\x1b[2;3H!\x1b[3;7rX");

        assert!(output
            .host_bytes
            .windows(b"\x1b[25;3H!".len())
            .any(|w| w == b"\x1b[25;3H!"));
        assert!(output
            .host_bytes
            .windows(b"\x1b[26;30r".len())
            .any(|w| w == b"\x1b[26;30r"));
    }

    #[test]
    fn bottom_region_proxy_answers_queries_and_passes_rich_bottom_protocols() {
        let region = test_bottom_region();
        let mut proxy = BottomRegionProxy::new(profile_ghostty(), region);
        let output = proxy.process(
            region,
            b"\x1b[6n\x1b]52;c;SGVsbG8=\x1b\\\x1b_Ga=t,f=24;AAAA\x1b\\",
        );

        assert_eq!(output.child_responses, b"\x1b[1;1R");
        assert!(output
            .host_bytes
            .windows(b"\x1b]52;c;SGVsbG8=\x1b\\".len())
            .any(|w| w == b"\x1b]52;c;SGVsbG8=\x1b\\"));
        assert!(output
            .host_bytes
            .windows(b"\x1b_Ga=t,f=24;AAAA\x1b\\".len())
            .any(|w| w == b"\x1b_Ga=t,f=24;AAAA\x1b\\"));
    }

    #[test]
    fn bottom_region_proxy_handles_split_kitty_graphics() {
        let region = test_bottom_region();
        let mut proxy = BottomRegionProxy::new(profile_ghostty(), region);

        let first = proxy.process(region, b"\x1b_Ga=t;");
        assert!(first.host_bytes.is_empty());

        let second = proxy.process(region, b"AAAA\x1b\\");
        assert!(second
            .host_bytes
            .windows(b"\x1b_Ga=t;AAAA\x1b\\".len())
            .any(|w| w == b"\x1b_Ga=t;AAAA\x1b\\"));

        let third = proxy.process(region, b"Z");
        assert!(third
            .host_bytes
            .windows(b"Z\x1b[r".len())
            .any(|w| w == b"Z\x1b[r"));
    }

    #[test]
    fn bottom_region_proxy_matches_direct_terminal_for_scrolling_text() {
        assert_bottom_proxy_matches_direct_terminal(
            "scrolling-text",
            &[
                b"line 00\r\nline 01\r\nline 02\r\nline 03\r\n",
                b"line 04\r\nline 05\r\nline 06\r\n",
                b"line 07\r\nline 08\r\nline 09\r\nline 10\r\nline 11\r\n",
            ],
        );
    }

    #[test]
    fn bottom_region_proxy_matches_direct_terminal_for_cursor_and_erases() {
        assert_bottom_proxy_matches_direct_terminal(
            "cursor-and-erases",
            &[
                b"\x1b[2J\x1b[Halpha\r\nbeta\r\ngamma",
                b"\x1b[2;10Hright\x1b[1;1Htop",
                b"\x1b[3;1H\x1b[Kcleared",
                b"\x1b[1;1H\x1b[Jtail",
                b"\x1b[2J\x1b[Hagain",
            ],
        );
    }

    #[test]
    fn bottom_region_proxy_matches_direct_terminal_for_scroll_margins() {
        assert_bottom_proxy_matches_direct_terminal(
            "scroll-margins",
            &[
                b"\x1b[2J\x1b[Hheader\r\none\r\ntwo\r\nthree\r\nfour",
                b"\x1b[2;8r\x1b[8;1Hmargin-0\r\nmargin-1\r\nmargin-2",
                b"\x1b[r\x1b[9;1Hfooter",
            ],
        );
    }

    #[test]
    fn bottom_region_proxy_matches_direct_terminal_for_wrapping_and_wide_text() {
        let ascii = "ascii ".repeat(15);
        let wrap = "wrap ".repeat(30);
        assert_bottom_proxy_matches_direct_terminal(
            "wrapping-and-wide-text",
            &[
                b"\x1b[2J\x1b[H",
                ascii.as_bytes(),
                b"\r\nwide: \xe7\x95\x8c\xe7\x95\x8c emoji: \xf0\x9f\x9a\x80\r\n",
                wrap.as_bytes(),
                b"\x1b[2;12Hafter-wide",
            ],
        );
    }

    #[test]
    fn bottom_region_proxy_matches_direct_terminal_for_alternate_screen() {
        assert_bottom_proxy_matches_direct_terminal(
            "alternate-screen",
            &[
                b"normal\r\ncontent",
                b"\x1b[?1049h\x1b[Halt-one\r\nalt-two",
                b"\x1b[2;5Hinside",
                b"\x1b[?1049l\x1b[Hnormal-again",
            ],
        );
    }

    #[test]
    fn bottom_region_proxy_matches_direct_terminal_for_fastfetch_shaped_output() {
        let fastfetch_like = b"\x1b[m\r\n\
            \x1b[2C\x1b_Ga=T,f=100,t=f,c=10,r=5;L25peC9mYXN0ZmV0Y2gtbG9nby5wbmc=\x1b\\\r\n\
            \x1b[6A\x1b[13C\r\n\
            \x1b[13C\x1b[m\x1b[1m\x1b[31mOS  \x1b[m\x1b[m \xe2\x80\xba  \x1b[mNixOS 26.11 x86_64\r\n\
            \x1b[13C\x1b[m\x1b[1m\x1b[32mKER \x1b[m\x1b[m \xe2\x80\xba  \x1b[mLinux 7.0.10\r\n\
            \x1b[13C\x1b[m\x1b[1m\x1b[34mSH  \x1b[m\x1b[m \xe2\x80\xba  \x1b[mfish 4.7.1\r\n\
            \x1b[13C\x1b[m\x1b[1m\x1b[35mTER \x1b[m\x1b[m \xe2\x80\xba  \x1b[mtinymux\r\n\
            \x1b[13C\x1b[m\x1b[1m\x1b[36mWM  \x1b[m\x1b[m \xe2\x80\xba  \x1b[mHyprland\r\n";
        assert_bottom_proxy_matches_direct_terminal(
            "fastfetch-shaped-repeat",
            &[fastfetch_like, fastfetch_like, fastfetch_like],
        );
    }

    #[test]
    fn bottom_region_proxy_tracks_mouse_and_keyboard_modes() {
        let region = test_bottom_region();
        let mut proxy = BottomRegionProxy::new(profile_ghostty(), region);
        let output = proxy.process(region, b"\x1b[?1000h\x1b[?1006h\x1b[>1u\x1b[?u");

        assert!(proxy.mouse_mode_enabled());
        assert_eq!(output.keyboard_flags, Some(1));
        assert_eq!(output.child_responses, b"\x1b[?1u");
        assert_eq!(proxy.keyboard_flags(), 1);
    }

    #[test]
    fn auto_keeps_implemented_common_profiles() {
        assert_eq!(selected_term("auto", "xterm-256color"), "xterm-256color");
        assert_eq!(selected_term("auto", "foot-direct"), "foot-direct");
        assert_eq!(selected_term("auto", "tmux-256color"), "tmux-256color");
    }

    #[test]
    fn auto_keeps_implemented_fancy_profiles() {
        assert_eq!(selected_term("auto", "xterm-ghostty"), "xterm-ghostty");
        assert_eq!(selected_term("auto", "xterm-kitty"), "xterm-kitty");
    }

    #[test]
    fn forced_profiles_require_outer_support() {
        assert_eq!(
            selected_term("xterm-ghostty", "xterm-ghostty"),
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
