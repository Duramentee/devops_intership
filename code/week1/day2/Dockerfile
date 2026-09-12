FROM golang:1.25.1-alpine

WORKDIR /home/test

COPY ./go.mod /home/test/

COPY ./main.go /home/test/

RUN go mod tidy

RUN go build -o webapp ./main.go

CMD [ "./webapp" ]