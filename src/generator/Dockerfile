FROM grafana/k6:0.51.0

WORKDIR /scripts

COPY generator.js /scripts/generator.js

ENTRYPOINT ["k6", "run", "/scripts/generator.js"]
