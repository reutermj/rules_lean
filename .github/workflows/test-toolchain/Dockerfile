FROM ubuntu:latest
COPY . /workspace
WORKDIR /workspace
RUN .github/workflows/test-toolchain/step-1.1-test-registration.sh
RUN .github/workflows/test-toolchain/step-2.1-test-expected-targets.sh
RUN .github/workflows/test-toolchain/step-3.1-test-binaries-runnable.sh
