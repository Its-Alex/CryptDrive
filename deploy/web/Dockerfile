# Static host for the CryptDrive web app: it only serves files, it never sees keys or file contents.
# Build: docker build -f deploy/web/Dockerfile --build-context site=app/build/web deploy/web
FROM nginxinc/nginx-unprivileged:1.30.6-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=site --chown=nginx:nginx . /usr/share/nginx/html

USER root
RUN find /usr/share/nginx/html -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' -o -name '*.json' -o -name '*.html' -o -name '*.otf' -o -name '*.ttf' \) \
      -exec gzip -9 -k {} \;
USER nginx

EXPOSE 8080
