# Build
FROM golang:1.23-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN GOTOOLCHAIN=local go mod download
COPY . .
RUN GOTOOLCHAIN=local CGO_ENABLED=0 go build -o /out/browser-orchestrator .

# Runtime (distroless nonroot)
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/browser-orchestrator /browser-orchestrator
EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/browser-orchestrator"]
