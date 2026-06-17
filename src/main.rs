use std::env;
use std::io::{self, Read, Write};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use crossbeam_channel::{select, tick, unbounded, Receiver, Sender};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, size as terminal_size};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use signal_hook::consts::signal::SIGWINCH;
use signal_hook::iterator::Signals;

const SECONDARY_ROWS: u16 = 9;
const DEFAULT_TOTAL_ROWS: u16 = 32;
const DEFAULT_MAIN_ROWS: u16 = DEFAULT_TOTAL_ROWS - SECONDARY_ROWS - 1;
const FLOOD_BATCH: usize = 1024 * 1024;
const BACKGROUND_FLUSH: Duration = Duration::from_millis(16);
const FLOOD_FLUSH: Duration = Duration::from_millis(8);

#[derive(Debug, Parser)]
#[command(author, version, about)]
struct Args {
    #[arg(long)]
    main: String,
    #[arg(long)]
    secondary: String,

    #[arg(long, hide = true)]
    throughput_bench_bytes: Option<usize>,
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
    PaneExit(PaneId, String),
    Input(Vec<u8>),
    Resize,
    Shutdown,
}

struct Pane {
    parser: vt100::Parser,
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
    exit_status: Option<String>,
}

impl Pane {
    fn spawn(id: PaneId, command: &str, layout: Layout, tx: Sender<Event>) -> Result<Self> {
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
        cmd.env("TERM", "xterm-256color");
        cmd.env("SHELL", &shell);
        if let Ok(home) = env::var("HOME") {
            cmd.env("HOME", home);
        }
        if let Ok(path) = env::var("PATH") {
            cmd.env("PATH", path);
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
            parser: vt100::Parser::new(rows, layout.cols, 0),
            writer,
            master: pair.master,
            exit_status: None,
        })
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
    panes: [Pane; 2],
    focus: PaneId,
    prefix: PrefixState,
    rendered_once: bool,
    dirty: bool,
    pending_bytes: usize,
    last_rows: Vec<Vec<u8>>,
}

impl App {
    fn new(args: &Args, tx: Sender<Event>) -> Result<Self> {
        let (cols, rows) = terminal_size().unwrap_or((100, 32));
        let layout = Layout::new(rows, cols);
        let main = Pane::spawn(PaneId::Main, &args.main, layout, tx.clone())?;
        let secondary = Pane::spawn(PaneId::Secondary, &args.secondary, layout, tx)?;
        Ok(Self {
            layout,
            panes: [main, secondary],
            focus: PaneId::Main,
            prefix: PrefixState::Idle,
            rendered_once: false,
            dirty: true,
            pending_bytes: 0,
            last_rows: Vec::new(),
        })
    }

    fn pane(&self, id: PaneId) -> &Pane {
        &self.panes[id.index()]
    }

    fn pane_mut(&mut self, id: PaneId) -> &mut Pane {
        &mut self.panes[id.index()]
    }

    fn handle_event(&mut self, event: Event) -> Result<bool> {
        match event {
            Event::PaneOutput(id, bytes) => {
                self.pending_bytes += bytes.len();
                self.pane_mut(id).parser.process(&bytes);
                let responses = pane_terminal_responses(self.pane(id), &bytes);
                if !responses.is_empty() {
                    let pane = self.pane_mut(id);
                    pane.writer.write_all(&responses)?;
                    pane.writer.flush()?;
                }
                self.dirty = true;
            }
            Event::PaneExit(id, status) => {
                let marker = format!("\r\n[exited: {status}]\r\n");
                let pane = self.pane_mut(id);
                pane.exit_status = Some(status);
                pane.parser.process(marker.as_bytes());
                self.dirty = true;
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
        for byte in bytes {
            match self.prefix.feed(*byte) {
                PrefixAction::None => {}
                PrefixAction::Forward(data) => self.pane_mut(self.focus).writer.write_all(&data)?,
                PrefixAction::Focus(id) => {
                    self.focus = id;
                    self.dirty = true;
                }
            }
        }
        self.pane_mut(self.focus).writer.flush()?;
        Ok(())
    }

    fn resize(&mut self) -> Result<()> {
        let (cols, rows) = terminal_size().unwrap_or((self.layout.cols, self.layout.rows));
        let layout = Layout::new(rows, cols);
        self.layout = layout;
        self.pane_mut(PaneId::Main)
            .resize(layout.main_rows.max(1), layout.cols)?;
        self.pane_mut(PaneId::Secondary)
            .resize(layout.secondary_rows.max(1), layout.cols)?;
        self.rendered_once = false;
        self.dirty = true;
        Ok(())
    }

    fn should_flush_immediately(&self, event: &Event) -> bool {
        matches!(event, Event::PaneOutput(id, _) if *id == self.focus)
            && self.pending_bytes < FLOOD_BATCH
            || matches!(
                event,
                Event::Input(_) | Event::Resize | Event::PaneExit(_, _)
            )
    }

    fn render<W: Write>(&mut self, out: &mut W) -> Result<()> {
        if !self.dirty {
            return Ok(());
        }
        if !self.rendered_once {
            out.write_all(b"\x1b[H\x1b[2J")?;
            self.rendered_once = true;
            self.last_rows.clear();
        }
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
        render_focused_cursor(out, self.layout, self.pane(self.focus), self.focus)?;
        render_input_modes(out, self.pane(self.focus))?;
        out.flush()?;
        self.dirty = false;
        self.pending_bytes = 0;
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

fn compose_rows(layout: Layout, main: &Pane, secondary: &Pane, focus: PaneId) -> Vec<Vec<u8>> {
    let mut rows = Vec::with_capacity(layout.rows as usize);
    append_pane_rows(&mut rows, layout, main, PaneId::Main);
    if layout.rows >= 2 {
        rows.push(border_row_body(layout, focus));
    }
    if layout.secondary_rows > 0 {
        append_pane_rows(&mut rows, layout, secondary, PaneId::Secondary);
    }
    rows.truncate(layout.rows as usize);
    rows
}

fn append_pane_rows(rows: &mut Vec<Vec<u8>>, layout: Layout, pane: &Pane, id: PaneId) {
    let height = match id {
        PaneId::Main => layout.main_rows,
        PaneId::Secondary => layout.secondary_rows,
    };
    if height == 0 {
        return;
    }
    for bytes in pane
        .parser
        .screen()
        .rows_formatted(0, layout.cols)
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

fn render_focused_cursor<W: Write>(
    out: &mut W,
    layout: Layout,
    pane: &Pane,
    id: PaneId,
) -> Result<()> {
    let screen = pane.parser.screen();
    let (row, col) = screen.cursor_position();
    let global_row = layout
        .pane_top(id)
        .saturating_add(row)
        .min(layout.rows.max(1));
    let global_col = col.saturating_add(1).min(layout.cols.max(1));
    if screen.hide_cursor() {
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

fn pane_terminal_responses(pane: &Pane, bytes: &[u8]) -> Vec<u8> {
    terminal_responses(bytes, pane.parser.screen().cursor_position())
}

fn terminal_responses(bytes: &[u8], cursor_position: (u16, u16)) -> Vec<u8> {
    let mut responses = Vec::new();

    if contains_any(bytes, &[b"\x1b[0c", b"\x1b[c"]) {
        responses.extend_from_slice(b"\x1b[?1;2c");
    }
    if contains_any(bytes, &[b"\x1b[>0c", b"\x1b[>c"]) {
        responses.extend_from_slice(b"\x1b[>0;95;0c");
    }
    if contains_any(bytes, &[b"\x1b[6n"]) {
        let (row, col) = cursor_position;
        responses.extend_from_slice(format!("\x1b[{};{}R", row + 1, col + 1).as_bytes());
    }
    if contains_any(bytes, &[b"\x1b[?6n"]) {
        let (row, col) = cursor_position;
        responses.extend_from_slice(format!("\x1b[?{};{}R", row + 1, col + 1).as_bytes());
    }

    if contains_any(bytes, &[b"\x1b[?u"]) {
        responses.extend_from_slice(b"\x1b[?0u");
    }
    if contains_any(bytes, &[b"\x1b[>0q", b"\x1b[>q"]) {
        responses.extend_from_slice(b"\x1bP>|tinymux 0.1.0\x1b\\");
    }

    append_osc_color_response(bytes, b"10", b"rgb:cd/d6/f4", &mut responses);
    append_osc_color_response(bytes, b"11", b"rgb:11/11/1b", &mut responses);
    append_osc_color_response(bytes, b"12", b"7", &mut responses);
    append_xtgettcap_responses(bytes, &mut responses);

    responses
}

fn contains_any(bytes: &[u8], needles: &[&[u8]]) -> bool {
    needles.iter().any(|needle| {
        !needle.is_empty() && bytes.windows(needle.len()).any(|window| window == *needle)
    })
}

fn append_osc_color_response(bytes: &[u8], index: &[u8], value: &[u8], responses: &mut Vec<u8>) {
    let mut query = Vec::with_capacity(index.len() + 5);
    query.extend_from_slice(b"\x1b]");
    query.extend_from_slice(index);
    query.extend_from_slice(b";?");
    if contains_any(bytes, &[query.as_slice()]) {
        responses.extend_from_slice(b"\x1b]");
        responses.extend_from_slice(index);
        responses.extend_from_slice(b";");
        responses.extend_from_slice(value);
        responses.extend_from_slice(b"\x1b\\");
    }
}

fn append_xtgettcap_responses(bytes: &[u8], responses: &mut Vec<u8>) {
    let mut offset = 0;
    while let Some(start) = find_subslice(&bytes[offset..], b"\x1bP+q") {
        let start = offset + start;
        let payload_start = start + 4;
        let Some(end) = find_subslice(&bytes[payload_start..], b"\x1b\\") else {
            break;
        };
        let payload_end = payload_start + end;
        responses.extend_from_slice(b"\x1bP0+r");
        responses.extend_from_slice(&bytes[payload_start..payload_end]);
        responses.extend_from_slice(b"\x1b\\");
        offset = payload_end + 2;
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
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
                    last_flush = Instant::now();
                }
            }
            recv(bg_tick) -> _ => {
                if app.dirty && last_flush.elapsed() >= BACKGROUND_FLUSH {
                    app.render(&mut stdout)?;
                    last_flush = Instant::now();
                }
            }
            recv(flood_tick) -> _ => {
                if app.dirty && app.pending_bytes >= FLOOD_BATCH {
                    app.render(&mut stdout)?;
                    last_flush = Instant::now();
                }
            }
            recv(resize_tick) -> _ => {
                if let Ok((cols, rows)) = terminal_size() {
                    if cols != app.layout.cols || rows != app.layout.rows {
                        app.resize()?;
                        app.render(&mut stdout)?;
                        last_flush = Instant::now();
                    }
                }
            }
        }
    }
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
    fn terminal_responder_answers_fish_startup_queries() {
        let output = b"\x1b[?u\x1b[>0q\x1b]11;?\x1b\\\x1b[0c\x1bP+q696e646e\x1b\\";
        let responses = terminal_responses(output, (4, 7));
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
    }

    #[test]
    fn terminal_responder_reports_pane_local_cursor_position() {
        let responses = terminal_responses(b"\x1b[6n\x1b[?6n", (2, 3));
        assert!(responses
            .windows(b"\x1b[3;4R".len())
            .any(|w| w == b"\x1b[3;4R"));
        assert!(responses
            .windows(b"\x1b[?3;4R".len())
            .any(|w| w == b"\x1b[?3;4R"));
    }
}
