FROM ubuntu:22.04
COPY . /workspace
WORKDIR /workspace
RUN .github/workflows/test-lean-binary/step-2.1-build-hello-world.sh
RUN .github/workflows/test-lean-binary/step-2.2-test-exit-code.sh
RUN .github/workflows/test-lean-binary/step-2.3-test-module-naming.sh
