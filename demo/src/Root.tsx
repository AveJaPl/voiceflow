import { Composition } from "remotion";
import { Demo, DURATION, FPS, HEIGHT, WIDTH } from "./Demo";

export const RemotionRoot = () => (
  <Composition id="Demo" component={Demo} durationInFrames={DURATION} fps={FPS} width={WIDTH} height={HEIGHT} />
);
