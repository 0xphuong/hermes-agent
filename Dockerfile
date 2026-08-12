FROM nousresearch/hermes-agent:latest

USER root

# Base image da co san Node.js 26 + npm
RUN npm install -g @anthropic-ai/claude-code

USER hermes
