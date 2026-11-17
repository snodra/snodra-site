# The site is built by the pipeline (mkdocs build --strict) and served as static files.
FROM nginx:1.29-alpine
COPY site /usr/share/nginx/html
