# 무의존성 — 베이스 이미지만으로 구동
FROM node:24-alpine
WORKDIR /app
COPY package.json server.js ./
EXPOSE 3010
ENV PORT=3010
CMD ["node", "server.js"]
