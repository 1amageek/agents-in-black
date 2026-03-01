FROM swift:6.2-jammy AS builder
WORKDIR /app
COPY . .
RUN swift build -c release

FROM ubuntu:jammy
RUN apt-get update && apt-get install -y libcurl4 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/.build/release/AgentSwift /usr/local/bin/server
ENV PORT=8080
EXPOSE 8080
CMD ["server"]