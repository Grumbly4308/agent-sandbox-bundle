# The agent's world. Everything the agent can ever run is installed here, at
# build time, because the root filesystem is mounted read-only at runtime.
#
# Base is the official Node image, not ubuntu:24.04, because the CLI needs a
# current Node and distro packages lag badly — Ubuntu 24.04 ships Node 18.19,
# and installing @anthropic-ai/claude-code on it produces:
#
#   npm WARN EBADENGINE required: { node: '>=22.0.0' }
#   npm WARN EBADENGINE current:  { node: 'v18.19.1', npm: '9.2.0' }
#
# ...which is a warning, not an error, so npm "succeeds" and the CLI then
# misbehaves at runtime. The alternative — piping NodeSource's installer into a
# root shell — is exactly the thing this guide tells you not to do, so we take
# a pinned upstream image instead.
FROM node:22-bookworm-slim

ARG HOST_UID=1000
ARG HOST_GID=1000
# Swap this for `aider-chat` (pip), `opencode`, etc. — see README.
ARG AGENT_CLI="@anthropic-ai/claude-code"

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# Every extra binary is attack surface. Add what your project genuinely needs
# and nothing else — `netcat-openbsd` is here because SSH-over-443 through the
# proxy needs it, `tini` because PID 1 must reap zombies. Node and npm come
# from the base image.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      jq \
      less \
      netcat-openbsd \
      openssh-client \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      tini \
 && rm -rf /var/lib/apt/lists/*

# The node image ships a stock `node` account on uid 1000. Remove it so the
# agent user can take *your* uid — otherwise every file the agent writes into
# the bind-mounted workspace comes back owned by the wrong user.
RUN userdel -r node 2>/dev/null || true; \
    groupadd -g "${HOST_GID}" agent 2>/dev/null || true; \
    useradd -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash agent

# Installed as root into /usr/local so the agent cannot modify its own CLI.
RUN npm install -g ${AGENT_CLI}

# Fail the build rather than shipping an image whose CLI quietly misbehaves.
RUN node --version && npm ls -g --depth=0 >/dev/null

COPY entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/agent-entrypoint

WORKDIR /workspace/repo
USER agent

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agent-entrypoint"]
CMD ["claude"]
