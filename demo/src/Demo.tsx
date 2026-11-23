/**
 * voiceflow demo: one dictation into a Claude Code session on GNOME (Wayland).
 *
 * Faithful to the product where it matters:
 * - the overlay card copies scripts/voiceflow-overlay.py (matte near-black card,
 *   1px border, inset top highlight, a breathing white dot that dims while the
 *   final pass runs, bottom-centre placement, height locked to five lines);
 * - the live preview refreshes once a second and shows exactly the words that
 *   faster-whisper (demo/words.py) places before each tick;
 * - the paste lands only after the hotkey is pressed again.
 * The card is drawn larger than on a real 1080p screen so it stays readable
 * in a 720p GIF.
 */
import { Mic, Power, Volume2, Wifi } from "lucide-react";
import type { CSSProperties, ReactNode } from "react";
import {
  AbsoluteFill,
  Audio,
  Easing,
  interpolate,
  Sequence,
  staticFile,
  useCurrentFrame,
} from "remotion";
import words from "./words.json";

export const FPS = 30;

// Timeline, in frames.
const KEY_START = 30; // Super+G pressed
const REC = 36; // recording (and the voice track) starts
const SPEECH_END = words[words.length - 1].end;
const KEY_STOP = REC + Math.round((SPEECH_END + 0.45) * FPS); // Super+G again
const PASTE = KEY_STOP + 20; // final pass done, text pasted
const ENTER = PASTE + 26;
const REPLY = ENTER + 8;
const END_CARD = REPLY + 78;
export const DURATION = END_CARD + 66;

const UI = '"Ubuntu Sans", "Ubuntu", "Cantarell", sans-serif';
const MONO = '"Ubuntu Sans Mono", "Ubuntu Mono", "DejaVu Sans Mono", monospace';
const GOLD = "#C9A45C";
const CLAUDE = "#D97757";

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

const ease = Easing.bezier(0.2, 0.8, 0.2, 1);
const fade = (frame: number, from: number, length = 8) =>
  interpolate(frame, [from, from + length], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: ease,
  });

// ───────────────────────────── desktop ─────────────────────────────

const Wallpaper = () => (
  <AbsoluteFill
    style={{
      background:
        "radial-gradient(1200px 700px at 78% 18%, #5a2346 0%, rgba(90,35,70,0) 60%)," +
        "radial-gradient(900px 600px at 12% 95%, #8a3b1c 0%, rgba(138,59,28,0) 55%)," +
        "linear-gradient(160deg, #1b0f1d 0%, #120b14 55%, #0c0a0d 100%)",
    }}
  />
);

const TopBar = ({ micOn }: { micOn: boolean }) => (
  <div
    style={{
      position: "absolute",
      inset: "0 0 auto 0",
      height: 30,
      background: "#000",
      color: "#f2f2f2",
      fontFamily: UI,
      fontSize: 14,
      fontWeight: 600,
      display: "flex",
      alignItems: "center",
      padding: "0 14px",
    }}
  >
    {/* workspace indicator, GNOME 4x style */}
    <div style={{ display: "flex", gap: 5, alignItems: "center" }}>
      <div style={{ width: 26, height: 8, borderRadius: 4, background: "#f2f2f2" }} />
      <div style={{ width: 8, height: 8, borderRadius: 4, background: "#777" }} />
      <div style={{ width: 8, height: 8, borderRadius: 4, background: "#777" }} />
    </div>
    <div style={{ flex: 1, textAlign: "center" }}>Mon 23 Nov 12:04</div>
    <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
      {micOn && (
        <div
          style={{
            background: "#e66100",
            borderRadius: 10,
            height: 20,
            padding: "0 7px",
            display: "flex",
            alignItems: "center",
          }}
        >
          <Mic size={13} color="#fff" strokeWidth={2.4} />
        </div>
      )}
      <Wifi size={15} strokeWidth={2.2} />
      <Volume2 size={15} strokeWidth={2.2} />
      <Power size={15} strokeWidth={2.2} />
    </div>
  </div>
);

const Dock = () => {
  const apps = ["#e66100", "#3584e4", "#2b2b2b", "#26a269", "#c64600"];
  return (
    <div
      style={{
        position: "absolute",
        left: 8,
        top: 150,
        width: 58,
        padding: "10px 0",
        borderRadius: 16,
        background: "rgba(28,28,30,0.82)",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: 10,
      }}
    >
      {apps.map((color, i) => (
        <div key={i} style={{ position: "relative" }}>
          <div
            style={{
              width: 40,
              height: 40,
              borderRadius: 10,
              background: color,
              border: i === 2 ? "1px solid #555" : "none",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              color: "#ddd",
              fontFamily: MONO,
              fontSize: 15,
              fontWeight: 700,
            }}
          >
            {i === 2 ? ">_" : ""}
          </div>
          {i === 2 && (
            <div
              style={{ position: "absolute", left: -6, top: 17, width: 4, height: 6, borderRadius: 2, background: "#f2f2f2" }}
            />
          )}
        </div>
      ))}
    </div>
  );
};

// ───────────────────────────── terminal ─────────────────────────────

const Line = ({ children, style }: { children?: ReactNode; style?: CSSProperties }) => (
  <div style={{ minHeight: 26, whiteSpace: "pre-wrap", ...style }}>{children}</div>
);

const REPLY_LINES: { text: ReactNode; at: number }[] = [
  {
    text: (
      <>
        <span style={{ color: "#f2f2f2" }}>●</span> I'll add a language dropdown to Settings, default it to{" "}
        <span style={{ color: "#9ccfd8" }}>en</span> and cover it with a test.
      </>
    ),
    at: 0,
  },
  {
    text: (
      <>
        <span style={{ color: "#26a269" }}>●</span> <b>Read</b>(src/voiceflow/gui/pages/settings.py)
      </>
    ),
    at: 18,
  },
  {
    text: (
      <>
        <span style={{ color: "#26a269" }}>●</span> <b>Update</b>(src/voiceflow/config.py)
      </>
    ),
    at: 34,
  },
];

const Terminal = ({ frame }: { frame: number }) => {
  const pasted = frame >= PASTE;
  const sent = frame >= ENTER;
  const cursorOn = Math.floor(frame / 16) % 2 === 0 || (frame >= PASTE && frame < PASTE + 10);
  const pasteFlash = pasted
    ? interpolate(frame, [PASTE, PASTE + 14], [1, 0], { extrapolateRight: "clamp" })
    : 0;
  const working = frame >= REPLY && frame < END_CARD;
  const spinner = "·✢✳✶✻✽"[Math.floor(frame / 4) % 6];

  return (
    <div
      style={{
        position: "absolute",
        left: 112,
        top: 54,
        width: 1110,
        height: 520,
        borderRadius: 14,
        overflow: "hidden",
        background: "#1e1e20",
        boxShadow: "0 24px 60px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.08)",
      }}
    >
      {/* libadwaita header bar */}
      <div
        style={{
          height: 44,
          background: "#2a2a2d",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          position: "relative",
          fontFamily: UI,
          fontSize: 15,
          fontWeight: 700,
          color: "#eee",
        }}
      >
        ~/projects/voiceflow — claude
        <div style={{ position: "absolute", right: 14, display: "flex", gap: 10 }}>
          {["–", "×"].map((g) => (
            <div
              key={g}
              style={{
                width: 22,
                height: 22,
                borderRadius: 11,
                background: "#3a3a3e",
                color: "#ddd",
                fontSize: 14,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
              }}
            >
              {g}
            </div>
          ))}
        </div>
      </div>

      <div style={{ padding: "16px 22px", fontFamily: MONO, fontSize: 17, color: "#d6d6d6", lineHeight: "26px" }}>
        <Line>
          <span style={{ color: "#8ae234", fontWeight: 700 }}>filip@ubuntu</span>
          <span style={{ color: "#729fcf", fontWeight: 700 }}>:~/projects/voiceflow</span>$ claude
        </Line>
        <Line />
        <Line>
          <span style={{ color: CLAUDE }}>✻</span> <b style={{ color: "#f2f2f2" }}>Claude Code</b>
          <span style={{ color: "#888" }}>  ·  ~/projects/voiceflow</span>
        </Line>
        <Line />

        {sent && (
          <>
            <Line style={{ color: "#9a9a9a" }}>
              <span style={{ color: "#bbb" }}>&gt;</span> {FULL_TEXT}
            </Line>
            <Line />
            {REPLY_LINES.map((l, i) =>
              frame >= REPLY + l.at ? (
                <Line key={i} style={{ opacity: fade(frame, REPLY + l.at, 6) }}>
                  {l.text}
                </Line>
              ) : null,
            )}
            {working && (
              <Line style={{ color: CLAUDE, marginTop: 8 }}>
                {spinner} Working… <span style={{ color: "#777" }}>(esc to interrupt)</span>
              </Line>
            )}
          </>
        )}

        {!sent && (
          <div
            style={{
              marginTop: 4,
              border: "1px solid rgba(255,255,255,0.22)",
              borderRadius: 8,
              padding: "8px 12px",
              background: `rgba(201,164,92,${0.16 * pasteFlash})`,
            }}
          >
            <span style={{ color: "#bbb" }}>&gt; </span>
            {pasted && <span style={{ color: "#f2f2f2" }}>{FULL_TEXT}</span>}
            <span
              style={{
                display: "inline-block",
                width: 10,
                height: 20,
                marginLeft: 2,
                verticalAlign: "-3px",
                background: cursorOn ? "#e6e6e6" : "transparent",
              }}
            />
          </div>
        )}
        {!sent && <Line style={{ color: "#6f6f6f", fontSize: 14, marginTop: 6 }}>  ? for shortcuts</Line>}
      </div>
    </div>
  );
};

// ───────────────────────────── voiceflow overlay ─────────────────────────────

const Overlay = ({ frame }: { frame: number }) => {
  const shown = frame >= REC && frame < PASTE;
  if (!shown) return null;
  const t = (frame - REC) / FPS;
  const transcribing = frame >= KEY_STOP;
  const enter = fade(frame, REC, 7);
  const leave = interpolate(frame, [PASTE - 5, PASTE], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const breathe = 0.22 + 0.78 * ((Math.cos((2 * Math.PI * t) / 1.8) + 1) / 2);
  const text = previewAt(Math.min(t, SPEECH_END + 0.45));

  return (
    <div
      style={{
        position: "absolute",
        left: (1280 - 760) / 2,
        bottom: 46,
        width: 760,
        opacity: enter * leave,
        transform: `translateY(${(1 - enter) * 10}px)`,
        background: "rgba(15, 15, 17, 0.94)",
        border: "1px solid rgba(255, 255, 255, 0.12)",
        borderRadius: 10,
        boxShadow: "inset 0 1px 0 rgba(255, 255, 255, 0.08)",
        padding: "20px 26px",
        display: "flex",
        gap: 14,
        fontFamily: '"Ubuntu", "Inter", "Cantarell", sans-serif',
        fontSize: 21,
        lineHeight: "29px",
        color: "rgba(255, 255, 255, 0.95)",
      }}
    >
      <div
        style={{
          flex: "none",
          width: 9,
          height: 9,
          marginTop: 10,
          borderRadius: "50%",
          background: transcribing ? "rgba(255,255,255,0.34)" : "rgba(255,255,255,0.95)",
          opacity: transcribing ? 1 : breathe,
        }}
      />
      {/* locked to five lines, like the real card */}
      <div style={{ height: 5 * 29, overflow: "hidden" }}>{text}</div>
    </div>
  );
};

// ───────────────────────────── annotations ─────────────────────────────

const Key = ({ children }: { children: ReactNode }) => (
  <span
    style={{
      display: "inline-block",
      minWidth: 30,
      padding: "4px 10px",
      borderRadius: 7,
      background: "#f4f1ea",
      color: "#151515",
      fontFamily: UI,
      fontWeight: 700,
      fontSize: 17,
      boxShadow: "0 3px 0 #a9a39a",
      textAlign: "center",
    }}
  >
    {children}
  </span>
);

const KeyHint = ({ frame, at, keys, label }: { frame: number; at: number; keys: string[]; label: string }) => {
  const life = 34;
  if (frame < at || frame > at + life) return null;
  const o = Math.min(fade(frame, at, 5), interpolate(frame, [at + life - 8, at + life], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }));
  const press = interpolate(frame, [at + 2, at + 5, at + 9], [0, 3, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <div
      style={{
        position: "absolute",
        left: "50%",
        top: 400,
        translate: "-50% 0",
        opacity: o,
        display: "flex",
        alignItems: "center",
        gap: 8,
        padding: "10px 14px",
        borderRadius: 12,
        background: "rgba(10,10,12,0.78)",
        border: `1px solid ${GOLD}55`,
        fontFamily: UI,
        color: "#eee",
        fontSize: 16,
      }}
    >
      {keys.map((k, i) => (
        <span key={k} style={{ display: "flex", alignItems: "center", gap: 8, transform: `translateY(${press}px)` }}>
          {i > 0 && <span style={{ color: "#aaa" }}>+</span>}
          <Key>{k}</Key>
        </span>
      ))}
      <span style={{ marginLeft: 6, color: GOLD, fontWeight: 600 }}>{label}</span>
    </div>
  );
};

// ───────────────────────────── end card ─────────────────────────────

const EndCard = ({ frame }: { frame: number }) => {
  if (frame < END_CARD) return null;
  const o = fade(frame, END_CARD, 14);
  const rise = (k: number) => ({
    opacity: fade(frame, END_CARD + 6 + k * 5, 12),
    transform: `translateY(${(1 - fade(frame, END_CARD + 6 + k * 5, 12)) * 12}px)`,
  });
  const bars = [24, 44, 64, 44, 24];
  return (
    <AbsoluteFill
      style={{
        opacity: o,
        background: "radial-gradient(900px 500px at 50% 40%, #1c1813 0%, #0b0a09 70%)",
        alignItems: "center",
        justifyContent: "center",
        flexDirection: "column",
        fontFamily: UI,
      }}
    >
      <div style={{ display: "flex", gap: 7, alignItems: "center", height: 70, ...rise(0) }}>
        {bars.map((h, i) => (
          <div key={i} style={{ width: 9, height: h, borderRadius: 5, background: GOLD }} />
        ))}
      </div>
      <div style={{ fontSize: 76, fontWeight: 700, color: "#f4f1ea", letterSpacing: "-0.03em", marginTop: 10, ...rise(1) }}>
        voiceflow
      </div>
      <div style={{ fontSize: 28, color: "#e8e2d6", marginTop: 6, ...rise(2) }}>
        Press a hotkey. Speak. Text appears in any window.
      </div>
      <div style={{ fontSize: 19, color: GOLD, marginTop: 22, fontWeight: 600, ...rise(3) }}>
        Local Whisper on your GPU · No cloud · Free & open source
      </div>
      <div style={{ fontSize: 17, color: "#8d877d", marginTop: 10, ...rise(4) }}>
        github.com/AveJaPl/voiceflow
      </div>
    </AbsoluteFill>
  );
};

// ───────────────────────────── scene ─────────────────────────────

export const Demo = () => {
  const frame = useCurrentFrame();
  const recording = frame >= REC && frame < KEY_STOP;
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <Wallpaper />
      <TopBar micOn={recording} />
      <Dock />
      <Terminal frame={frame} />
      <Overlay frame={frame} />
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
