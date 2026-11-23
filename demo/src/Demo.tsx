/**
 * voiceflow demo: one dictation into a Claude Code session on Ubuntu (GNOME, Wayland).
 *
 * Everything is drawn at true 1:1 pixel scale on a 1920x1080 screen; readability in
 * the README GIF comes from a camera zoom, not from enlarging the product.
 *
 * Faithful to the product:
 * - the overlay card copies scripts/voiceflow-overlay.py: CARD_WIDTH 828, padding 18,
 *   five 24px lines, 8px dot, BOTTOM_MARGIN 90, rgba(15,15,17,.94) with a 1px border
 *   and an inset top highlight, a dot that breathes every 1.8s and dims to 34% while
 *   the final pass runs. Its CSS asks for "SF Pro Text", "Inter", …; on Ubuntu the
 *   first installed one is Inter, so Inter 17px is what the card really uses;
 * - the live preview refreshes once a second and shows exactly the words that
 *   faster-whisper (demo/words.py) places before each tick;
 * - the paste lands only after the hotkey is pressed a second time.
 * Faithful to a stock Ubuntu 26.04 desktop: Raccoon "Very Dark" wallpaper, Ubuntu dock
 * on the left at full height with 48px Yaru icons, the GNOME top bar, Ptyxis with its
 * "GNOME" dark palette (background #1c1c1f, title bar #2e2e32).
 * Illustrative: the agent's reply in the terminal and the key hints.
 */
import type { CSSProperties, ReactNode } from "react";
import {
  AbsoluteFill,
  Audio,
  Easing,
  Img,
  interpolate,
  Sequence,
  staticFile,
  useCurrentFrame,
} from "remotion";
import words from "./words.json";

export const FPS = 30;
export const WIDTH = 1920;
export const HEIGHT = 1080;

// Timeline, in frames.
const KEY_START = 34; // Super+G pressed
const REC = 40; // recording (and the voice track) starts
const SPEECH_END = words[words.length - 1].end;
const KEY_STOP = REC + Math.round((SPEECH_END + 0.45) * FPS); // Super+G again
const PASTE = KEY_STOP + 20; // final pass done, text pasted
const ENTER = PASTE + 30;
const REPLY = ENTER + 8;
const END_CARD = REPLY + 78;
export const DURATION = END_CARD + 66;

const UI = '"Ubuntu Sans", "Ubuntu", sans-serif';
const CARD_FONT = '"Inter", "Ubuntu", sans-serif';
const TERM = '"FiraCode Nerd Font Mono", "Fira Code", "Ubuntu Sans Mono", monospace';
const ACCENT_TEXT = "#ffffff"; // monochrome, like the overlay and the app icon
const CLAUDE = "#D97757";
const ACCENT = "#3584e4"; // GNOME "blue" accent

// Ptyxis "GNOME" palette, dark variant.
const P = {
  bg: "#1c1c1f",
  title: "#2e2e32",
  fg: "#ffffff",
  green: "#2ec27e",
  blue: "#1e78e4",
  dim: "#9a9996",
};

const FULL_TEXT = words.map((w) => w.w).join("").trim();

/** What the live preview shows `seconds` into the recording. */
function previewAt(seconds: number): string {
  const tick = Math.floor(seconds); // refreshed once a second
  if (tick < 1) return "";
  return words
    .filter((w) => w.end <= tick)
    .map((w) => w.w)
    .join("")
    .trim();
}

const ease = Easing.bezier(0.25, 0.1, 0.25, 1);
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const fade = (frame: number, from: number, length = 8) =>
  interpolate(frame, [from, from + length], [0, 1], { ...clamp, easing: ease });

// ───────────────────────────── camera ─────────────────────────────

// [frame, zoom, centreX, centreY] — the point of the screen kept in the middle.
const SHOTS: [number, number, number, number][] = [
  [0, 1, 960, 540],
  [REC - 12, 1, 960, 540],
  // onto the prompt and the card below it; the paste lands in the same shot
  [REC + 14, 1.6, 960, 760],
  [ENTER, 1.6, 960, 760],
];

function camera(frame: number) {
  const f = SHOTS.map((s) => s[0]);
  const pick = (i: number) =>
    interpolate(frame, f, SHOTS.map((s) => s[i]), { ...clamp, easing: Easing.inOut(Easing.cubic) });
  const zoom = pick(1);
  // keep the visible window inside the screen
  const halfW = WIDTH / zoom / 2;
  const halfH = HEIGHT / zoom / 2;
  const cx = Math.min(WIDTH - halfW, Math.max(halfW, pick(2)));
  const cy = Math.min(HEIGHT - halfH, Math.max(halfH, pick(3)));
  return { zoom, cx, cy };
}

// ───────────────────────────── desktop ─────────────────────────────

const white: CSSProperties = { filter: "brightness(0) invert(1)" };

const TopBar = ({ micOn }: { micOn: boolean }) => (
  <div
    style={{
      position: "absolute",
      inset: "0 0 auto 0",
      height: 32,
      background: "#000",
      color: "#fff",
      fontFamily: UI,
      fontSize: 15,
      fontWeight: 700,
      display: "flex",
      alignItems: "center",
      padding: "0 12px",
    }}
  >
    <div style={{ display: "flex", gap: 6, alignItems: "center", padding: "0 6px" }}>
      <div style={{ width: 30, height: 9, borderRadius: 5, background: "#fff" }} />
      <div style={{ width: 9, height: 9, borderRadius: 5, background: "rgba(255,255,255,0.45)" }} />
    </div>
    <div style={{ flex: 1, textAlign: "center" }}>Nov 23&nbsp;&nbsp;12:04</div>
    <div style={{ display: "flex", gap: 12, alignItems: "center", padding: "0 6px" }}>
      {micOn && <Img src={staticFile("icons/audio-input-microphone-high-symbolic.svg")} style={{ width: 16, ...white }} />}
      <Img src={staticFile("icons/network-wireless-signal-excellent-symbolic.svg")} style={{ width: 16, ...white }} />
      <Img src={staticFile("icons/audio-volume-high-symbolic.svg")} style={{ width: 16, ...white }} />
      <Img src={staticFile("icons/system-shutdown-symbolic.svg")} style={{ width: 16, ...white }} />
    </div>
  </div>
);

const DOCK_APPS = [
  { icon: "org.gnome.Nautilus.svg" },
  { icon: "org.gnome.Ptyxis.svg", running: true },
  { icon: "voiceflow.svg", running: true },
  { icon: "org.gnome.TextEditor.svg" },
  { icon: "org.gnome.Settings.svg" },
  { icon: "org.gnome.Yelp.svg" },
];

const Dock = () => (
  <div
    style={{
      position: "absolute",
      left: 0,
      top: 32,
      bottom: 0,
      width: 64,
      background: "rgba(23, 23, 23, 0.8)",
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      padding: "6px 0",
      gap: 6,
    }}
  >
    {DOCK_APPS.map((app) => (
      <div key={app.icon} style={{ position: "relative", width: 56, height: 56, display: "flex", alignItems: "center", justifyContent: "center" }}>
        <Img src={staticFile(`icons/${app.icon}`)} style={{ width: 48, height: 48 }} />
        {app.running && (
          <div style={{ position: "absolute", left: 1, top: 25, width: 5, height: 5, borderRadius: 3, background: ACCENT }} />
        )}
      </div>
    ))}
    <div style={{ flex: 1 }} />
    <Img src={staticFile("icons/view-app-grid-symbolic.svg")} style={{ width: 28, marginBottom: 14, ...white }} />
  </div>
);

// ───────────────────────────── Ptyxis + Claude Code ─────────────────────────────

const Line = ({ children, style }: { children?: ReactNode; style?: CSSProperties }) => (
  <div style={{ minHeight: 22, whiteSpace: "pre-wrap", ...style }}>{children}</div>
);

const REPLY_LINES: { text: ReactNode; at: number }[] = [
  {
    text: (
      <>
        <span style={{ color: P.fg }}>●</span> I'll add a language dropdown to Settings, default it to{" "}
        <span style={{ color: "#4fd2fd" }}>en</span> and cover it with a test.
      </>
    ),
    at: 0,
  },
  {
    text: (
      <>
        <span style={{ color: P.green }}>●</span> <b>Read</b>(src/voiceflow/gui/pages/settings.py)
      </>
    ),
    at: 18,
  },
  {
    text: (
      <>
        <span style={{ color: P.green }}>●</span> <b>Update</b>(src/voiceflow/config.py)
      </>
    ),
    at: 34,
  },
];

const HeaderButton = ({ children }: { children: ReactNode }) => (
  <div
    style={{
      width: 24,
      height: 24,
      borderRadius: 12,
      background: "rgba(255,255,255,0.1)",
      color: "#fff",
      fontSize: 13,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
    }}
  >
    {children}
  </div>
);

const Terminal = ({ frame }: { frame: number }) => {
  const pasted = frame >= PASTE;
  const sent = frame >= ENTER;
  const cursorOn = Math.floor(frame / 16) % 2 === 0 || (pasted && frame < PASTE + 10);
  const pasteFlash = pasted ? interpolate(frame, [PASTE, PASTE + 16], [1, 0], { extrapolateRight: "clamp" }) : 0;
  const working = frame >= REPLY && frame < END_CARD;
  const spinner = "·✢✳✶✻✽"[Math.floor(frame / 4) % 6];

  return (
    <div
      style={{
        position: "absolute",
        left: (WIDTH - 1140) / 2,
        top: 80,
        width: 1140,
        height: 772,
        borderRadius: 12,
        overflow: "hidden",
        background: P.bg,
        boxShadow: "0 20px 50px rgba(0,0,0,0.5), 0 0 0 1px rgba(255,255,255,0.07)",
      }}
    >
      {/* Ptyxis header bar: new tab, title, menu, window controls */}
      <div
        style={{
          height: 46,
          background: P.title,
          display: "flex",
          alignItems: "center",
          padding: "0 10px",
          fontFamily: UI,
          color: P.fg,
        }}
      >
        <div style={{ display: "flex", gap: 2, alignItems: "center", fontSize: 20, fontWeight: 400, width: 140 }}>
          <span style={{ padding: "0 10px" }}>+</span>
          <span style={{ fontSize: 12, opacity: 0.8 }}>▾</span>
        </div>
        <div style={{ flex: 1, textAlign: "center", fontSize: 15, fontWeight: 700 }}>~/projects/voiceflow</div>
        <div style={{ display: "flex", gap: 10, alignItems: "center", width: 140, justifyContent: "flex-end" }}>
          <span style={{ fontSize: 18, marginRight: 8 }}>≡</span>
          <HeaderButton>–</HeaderButton>
          <HeaderButton>□</HeaderButton>
          <HeaderButton>×</HeaderButton>
        </div>
      </div>

      {/* a session already in progress, so the prompt sits at the bottom of the window */}
      <div
        style={{
          position: "absolute",
          top: 46,
          left: 0,
          right: 0,
          bottom: 0,
          display: "flex",
          flexDirection: "column",
          justifyContent: "flex-end",
          padding: "10px 12px 16px",
          fontFamily: TERM,
          fontSize: 16,
          color: P.fg,
          lineHeight: "22px",
        }}
      >
        <Line>
          <b style={{ color: P.green }}>filip@ubuntu</b>:<b style={{ color: P.blue }}>~/projects/voiceflow</b>$ claude
        </Line>
        <Line />
        <Line>
          <span style={{ color: CLAUDE }}>✻</span> <b>Claude Code</b>
          <span style={{ color: P.dim }}>  ·  ~/projects/voiceflow</span>
        </Line>
        <Line />
        <Line style={{ color: P.dim }}>&gt; run the test suite</Line>
        <Line />
        <Line>
          <span style={{ color: P.green }}>●</span> <b>Bash</b>(uv run pytest -q)
        </Line>
        <Line style={{ color: P.dim }}>  ⎿  524 passed, 4 skipped in 10.43s</Line>
        <Line />
        <Line>
          <span style={{ color: P.fg }}>●</span> All 524 tests pass; the 4 skips are Windows-only.
        </Line>
        <Line />

        {sent ? (
          <>
            <Line style={{ color: P.dim }}>&gt; {FULL_TEXT}</Line>
            <Line />
            {REPLY_LINES.map((l, i) =>
              frame >= REPLY + l.at ? (
                <Line key={i} style={{ opacity: fade(frame, REPLY + l.at, 6) }}>
                  {l.text}
                </Line>
              ) : null,
            )}
            {working && (
              <Line style={{ color: CLAUDE, marginTop: 6 }}>
                {spinner} Working… <span style={{ color: P.dim }}>(esc to interrupt)</span>
              </Line>
            )}
          </>
        ) : (
          <>
            <div
              style={{
                border: "1px solid rgba(255,255,255,0.25)",
                borderRadius: 6,
                padding: "6px 10px",
                background: `rgba(255,255,255,${0.12 * pasteFlash})`,
              }}
            >
              <span style={{ color: P.dim }}>&gt; </span>
              {pasted && <span>{FULL_TEXT}</span>}
              <span
                style={{
                  display: "inline-block",
                  width: 9,
                  height: 18,
                  marginLeft: 1,
                  verticalAlign: "-3px",
                  background: cursorOn ? P.fg : "transparent",
                }}
              />
            </div>
            <Line style={{ color: "#6f6e73", fontSize: 13, marginTop: 4 }}>  ? for shortcuts</Line>
          </>
        )}
      </div>
    </div>
  );
};

// ───────────────────────────── voiceflow overlay (1:1) ─────────────────────────────

const CARD_WIDTH = 828;
const BOTTOM_MARGIN = 90;
const LINE_HEIGHT = 24;
const MAX_LINES = 5;
const CARD_PADDING_Y = 18;
const DOT_SIZE = 8;

const Overlay = ({ frame }: { frame: number }) => {
  if (frame < REC || frame >= PASTE) return null;
  const t = (frame - REC) / FPS;
  const transcribing = frame >= KEY_STOP;
  const appear = fade(frame, REC, 4);
  const leave = interpolate(frame, [PASTE - 3, PASTE], [1, 0], clamp);
  const breathe = 0.22 + 0.78 * ((Math.cos((2 * Math.PI * t) / 1.8) + 1) / 2);
  const text = previewAt(Math.min(t, SPEECH_END + 0.45));

  return (
    <div
      style={{
        position: "absolute",
        left: (WIDTH - CARD_WIDTH) / 2,
        bottom: BOTTOM_MARGIN,
        width: CARD_WIDTH,
        opacity: appear * leave,
        background: "rgba(15, 15, 17, 0.94)",
        border: "1px solid rgba(255, 255, 255, 0.12)",
        borderRadius: 10,
        boxShadow: "inset 0 1px 0 rgba(255, 255, 255, 0.08)",
        padding: `${CARD_PADDING_Y}px 20px`,
        display: "flex",
        gap: 12,
        fontFamily: CARD_FONT,
        fontSize: 17,
        lineHeight: `${LINE_HEIGHT}px`,
        color: "rgba(255, 255, 255, 0.95)",
      }}
    >
      <div
        style={{
          flex: "none",
          width: DOT_SIZE,
          height: DOT_SIZE,
          marginTop: (LINE_HEIGHT - DOT_SIZE) / 2,
          borderRadius: "50%",
          background: transcribing ? "rgba(255,255,255,0.34)" : "rgba(255,255,255,0.95)",
          opacity: transcribing ? 1 : breathe,
        }}
      />
      <div style={{ height: MAX_LINES * LINE_HEIGHT, overflow: "hidden" }}>{text}</div>
    </div>
  );
};

// ───────────────────────────── annotations (screen space) ─────────────────────────────

const Key = ({ children }: { children: ReactNode }) => (
  <span
    style={{
      display: "inline-block",
      minWidth: 40,
      padding: "6px 14px",
      borderRadius: 9,
      background: "#f5f5f7",
      color: "#151515",
      fontFamily: UI,
      fontWeight: 700,
      fontSize: 24,
      boxShadow: "0 4px 0 #9a9aa0",
      textAlign: "center",
    }}
  >
    {children}
  </span>
);

const KeyHint = ({ frame, at, keys, label }: { frame: number; at: number; keys: string[]; label: string }) => {
  const life = 36;
  if (frame < at || frame > at + life) return null;
  const o = Math.min(fade(frame, at, 5), interpolate(frame, [at + life - 8, at + life], [1, 0], clamp));
  const press = interpolate(frame, [at + 2, at + 5, at + 9], [0, 4, 0], clamp);
  return (
    <div
      style={{
        position: "absolute",
        left: "50%",
        top: 70,
        translate: "-50% 0",
        opacity: o,
        display: "flex",
        alignItems: "center",
        gap: 10,
        padding: "14px 20px",
        borderRadius: 16,
        background: "rgba(10,10,12,0.82)",
        border: "1px solid rgba(255,255,255,0.18)",
        fontFamily: UI,
        color: "#eee",
        fontSize: 22,
      }}
    >
      {keys.map((k, i) => (
        <span key={k} style={{ display: "flex", alignItems: "center", gap: 10, transform: `translateY(${press}px)` }}>
          {i > 0 && <span style={{ color: "#aaa" }}>+</span>}
          <Key>{k}</Key>
        </span>
      ))}
      <span style={{ marginLeft: 8, color: ACCENT_TEXT, fontWeight: 700 }}>{label}</span>
    </div>
  );
};

// ───────────────────────────── end card ─────────────────────────────

const EndCard = ({ frame }: { frame: number }) => {
  if (frame < END_CARD) return null;
  const rise = (k: number) => {
    const v = fade(frame, END_CARD + 6 + k * 5, 12);
    return { opacity: v, transform: `translateY(${(1 - v) * 16}px)` };
  };
  const bars = [36, 66, 96, 66, 36];
  return (
    <AbsoluteFill
      style={{
        opacity: fade(frame, END_CARD, 14),
        background: "radial-gradient(1300px 750px at 50% 40%, #1c1c20 0%, #0a0a0b 70%)",
        alignItems: "center",
        justifyContent: "center",
        flexDirection: "column",
        fontFamily: UI,
      }}
    >
      <div style={{ display: "flex", gap: 11, alignItems: "center", height: 104, ...rise(0) }}>
        {bars.map((h, i) => (
          <div key={i} style={{ width: 13, height: h, borderRadius: 7, background: "#f5f5f7" }} />
        ))}
      </div>
      <div style={{ fontSize: 114, fontWeight: 700, color: "#f5f5f7", letterSpacing: "-0.03em", marginTop: 14, ...rise(1) }}>
        voiceflow
      </div>
      <div style={{ fontSize: 42, color: "#e4e4e8", marginTop: 8, ...rise(2) }}>
        Press a hotkey. Speak. Text appears in any window.
      </div>
      <div style={{ fontSize: 28, color: "#c9c9cf", marginTop: 32, fontWeight: 700, ...rise(3) }}>
        Local Whisper on your GPU · No cloud · Free & open source
      </div>
      <div style={{ fontSize: 25, color: "#8a8a90", marginTop: 14, ...rise(4) }}>github.com/AveJaPl/voiceflow</div>
    </AbsoluteFill>
  );
};

// ───────────────────────────── scene ─────────────────────────────

export const Demo = () => {
  const frame = useCurrentFrame();
  const { zoom, cx, cy } = camera(frame);
  const recording = frame >= REC && frame < KEY_STOP;
  return (
    <AbsoluteFill style={{ background: "#000", overflow: "hidden" }}>
      <AbsoluteFill
        style={{
          transformOrigin: "0 0",
          transform: `translate(${WIDTH / 2}px, ${HEIGHT / 2}px) scale(${zoom}) translate(${-cx}px, ${-cy}px)`,
        }}
      >
        <Img src={staticFile("wallpaper.jpg")} style={{ position: "absolute", inset: 0, width: WIDTH, height: HEIGHT }} />
        <TopBar micOn={recording} />
        <Dock />
        <Terminal frame={frame} />
        <Overlay frame={frame} />
      </AbsoluteFill>
      <KeyHint frame={frame} at={KEY_START} keys={["Super", "G"]} label="start dictation" />
      <KeyHint frame={frame} at={KEY_STOP} keys={["Super", "G"]} label="stop & paste" />
      <KeyHint frame={frame} at={ENTER - 6} keys={["Enter"]} label="send" />
      <EndCard frame={frame} />
      <Sequence from={REC}>
        <Audio src={staticFile("voice.mp3")} />
      </Sequence>
    </AbsoluteFill>
  );
};
