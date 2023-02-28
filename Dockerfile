FROM golang
WORKDIR /app
COPY * ./
RUN go build -o processorService
EXPOSE 18080
CMD ["./processorService"]
