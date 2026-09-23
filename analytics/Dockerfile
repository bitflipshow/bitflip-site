FROM python:3.12-slim
WORKDIR /app
COPY . /app
RUN pip install --no-cache-dir -r requirements.txt && useradd -r -u 10001 analytics && mkdir -p /data && chown analytics:analytics /data
USER analytics
EXPOSE 8787
CMD ["python", "-m", "app", "serve"]
