FROM swift:6.2-jammy AS builder
WORKDIR /app
COPY . .
RUN swift build -c release

FROM swift:6.2-jammy-slim AS runtime
COPY --from=builder /app/.build/release/AgentSwift /usr/local/bin/server
ENV PORT=8080
EXPOSE 8080
CMD ["server"]
