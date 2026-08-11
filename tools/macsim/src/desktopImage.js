import { mkdirSync, existsSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Poprawny 1 × 1 JPEG JFIF. Jest celowo w kodzie, aby macsim nie potrzebował
// biblioteki graficznej; przy pierwszym uruchomieniu materializuje się jako asset.
const JPEG_BASE64 = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAqf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/Aaf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/Aaf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/Ap//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/Iaf/2gAMAwEAAgADAAAAEP/EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8QH//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8QH//EABQQAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8QH//Z';

export const desktopJpeg = Buffer.from(JPEG_BASE64, 'base64');
export const desktopImage = { format: 'jpeg', w: 1, h: 1, bytes: desktopJpeg.length, data: desktopJpeg };

export function ensureDesktopAsset() {
  const directory = dirname(fileURLToPath(import.meta.url));
  const assetPath = join(directory, '..', 'assets', 'desktop.jpg');
  if (!existsSync(assetPath)) {
    mkdirSync(dirname(assetPath), { recursive: true });
    writeFileSync(assetPath, desktopJpeg);
  }
  return assetPath;
}
