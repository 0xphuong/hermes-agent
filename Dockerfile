FROM nousresearch/hermes-agent:latest

USER root

# The base image already ships Node.js 26 + npm
RUN npm install -g @anthropic-ai/claude-code

USER hermes
