FROM --platform=$BUILDPLATFORM golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea AS build

ARG VITESS_REV=93926dba3020bedc0817b18933b5132fa59d3f1d

RUN git clone --filter=blob:none --no-checkout https://github.com/vitessio/vitess.git /src/vitess \
	&& git -C /src/vitess checkout --detach "$VITESS_REV"

COPY launcher/main.go /src/vitess/tests/e2e/vitess-launcher/main.go

WORKDIR /src/vitess

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=false \
	-o /vtcombo-thysql ./tests/e2e/vitess-launcher

FROM vitess/vttestserver@sha256:82e96c43027f338593ad09447cb4433228a8cd69ced3d8d5583a2fe79892a34d

COPY --from=build /vtcombo-thysql /vt/bin/vtcombo
