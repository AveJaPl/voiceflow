import { desktopImage } from './desktopImage.js';
import {
  completeInjected,
  completeStarted,
  decodePhoneFrame,
  handleBinaryFrame,
  handlePhoneFrame,
  previewTick,
  terminalTick,
} from './handlers.js';
import { createMacState, windowsFrame } from './state.js';

/**
 * Cienka, stanowa otoczka dla czystych handlerów. Tylko tu są timery i I/O;
 * dzięki temu reguły protokołu pozostają jednostkowo testowalne bez WebSocketów.
 */
export class MacSimSession {
  constructor({ scenario = 'happy', sendText, sendBinary, close, log = () => {}, delays = {} } = {}) {
    this.state = createMacState({ scenario });
    this.sendText = sendText;
    this.sendBinary = sendBinary;
    this.closeSocket = close;
    this.log = log;
    this.delays = {
      started: delays.started ?? 150,
      preview: delays.preview ?? 700,
      injected: delays.injected ?? 400,
      terminal: delays.terminal ?? 1500,
      drop: delays.drop ?? 1500,
    };
    this.previewTimer = null;
    this.terminalTimer = null;
    this.timeouts = new Set();
  }

  receiveText(text) {
    const frame = decodePhoneFrame(text);
    if (!frame) {
      this.log('←', 'invalid-json', text.slice(0, 80));
      return;
    }
    this.log('←', frame.type, summary(frame));
    this.apply(handlePhoneFrame(this.state, frame));
  }

  receiveBinary(data) {
    const bytes = data.byteLength;
    this.log('←', 'pcm', `${bytes} B`);
    this.apply(handleBinaryFrame(this.state, bytes));
  }

  apply(result) {
    this.state = result.state;
    for (const action of result.actions) this.run(action);
  }

  run(action) {
    switch (action.kind) {
      case 'send':
        this.send(action.frame);
        break;
      case 'screenshot':
        // Te dwa wywołania muszą pozostać sąsiadujące na WebSockecie.
        this.send({ type: 'screenshot', generation: this.state.generation, format: desktopImage.format, w: desktopImage.w, h: desktopImage.h, bytes: desktopImage.bytes });
        this.log('→', 'screenshot-bytes', `${desktopImage.bytes} B`);
        this.sendBinary(desktopImage.data);
        break;
      case 'scheduleStarted':
        this.after(this.delays.started, () => this.apply(completeStarted(this.state, action.target)));
        break;
      case 'startPreview':
        this.startPreview();
        break;
      case 'stopPreview':
        this.stopPreview();
        break;
      case 'scheduleInjected':
        this.after(this.delays.injected, () => this.apply(completeInjected(this.state, action.target)));
        break;
      case 'startTerminal':
        this.startTerminal();
        break;
      case 'stopAutonomous':
        this.stopPreview();
        this.stopTerminal();
        break;
      case 'dropLater':
        this.after(this.delays.drop, () => this.closeSocket?.(1012, 'macsim-drop-mid-utterance'));
        break;
      case 'logKey':
        this.log('↔', 'key', action.chord ?? '(brak chord)');
        break;
      default:
        throw new Error(`Nieznany efekt macsim: ${action.kind}`);
    }
  }

  send(frame) {
    this.log('→', frame.type, summary(frame));
    this.sendText(JSON.stringify(frame));
  }

  startPreview() {
    this.stopPreview();
    this.previewTimer = setInterval(() => this.apply(previewTick(this.state)), this.delays.preview);
  }

  stopPreview() {
    if (this.previewTimer) clearInterval(this.previewTimer);
    this.previewTimer = null;
  }

  startTerminal() {
    this.stopTerminal();
    this.terminalTimer = setInterval(() => this.apply(terminalTick(this.state)), this.delays.terminal);
  }

  stopTerminal() {
    if (this.terminalTimer) clearInterval(this.terminalTimer);
    this.terminalTimer = null;
  }

  after(ms, callback) {
    const timer = setTimeout(() => {
      this.timeouts.delete(timer);
      callback();
    }, ms);
    this.timeouts.add(timer);
  }

  dispose() {
    this.stopPreview();
    this.stopTerminal();
    for (const timeout of this.timeouts) clearTimeout(timeout);
    this.timeouts.clear();
  }
}

function summary(frame) {
  const { type, ...payload } = frame;
  const json = JSON.stringify(payload);
  return json.length > 160 ? `${json.slice(0, 157)}…` : json;
}

export function makeWindowsFrame(session) {
  return windowsFrame(session.state);
}
