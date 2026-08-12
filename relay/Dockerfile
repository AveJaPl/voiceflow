FROM node:22-alpine
WORKDIR /app

COPY package.json package-lock.json* ./
# --ignore-scripts: better-sqlite3 ma binding.gyp, więc npm domyślnie odpala
# node-gyp rebuild (alpine nie ma pythona/kompilatora i build pada). Paczka wozi
# gotowe prebuildy, w tym linuxmusl — wystarczy nie kompilować od nowa.
RUN npm ci --omit=dev --no-audit --no-fund --ignore-scripts

COPY server.js ./
COPY src ./src

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
