# Landing page for voiceflow.pbdevs.com — static files behind nginx.
# Build context: the site/ directory (Coolify: Base Directory = /site).
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/
COPY en/ /usr/share/nginx/html/en/
COPY pl/ /usr/share/nginx/html/pl/
COPY assets/ /usr/share/nginx/html/assets/
