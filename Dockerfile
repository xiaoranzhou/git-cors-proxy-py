FROM python:3.11-slim
LABEL maintainer="CORS Proxy Python Port"
WORKDIR /srv
COPY . .
RUN pip install --no-cache-dir -e . \
 && useradd -r -s /sbin/nologin corsproxy
USER corsproxy
EXPOSE 9999
ENV PORT=9999
CMD ["python3", "-m", "cors_proxy.server"]