FROM node:20-bookworm-slim

# Driver dependencies: git (state + checkouts), jq/curl (API helpers),
# gh (PR/issue writes on GitHub-hosted repos), perl (transcript timestamps),
# python3/pip (aider brain).
RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq curl ca-certificates perl python3 python3-pip openssh-client \
    && (type -p wget >/dev/null || apt-get install -y wget) \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
COPY receiver.mjs entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENV REPO_DIR=/repo PORT=8787
EXPOSE 8787
ENTRYPOINT ["./entrypoint.sh"]
