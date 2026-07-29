# Lambda container image for the slack adapter. Built by `sst deploy` --
# sst picks up a Dockerfile at the uv workspace root and passes PYTHON_VERSION.
#
# The AWS lambda python base image has no _tkinter (verified: "No module named
# _tkinter" on public.ecr.aws/lambda/python:3.13), and the engine is built on
# tcl safe interps via tkinter. Debian's python image links against the system
# libtcl, so it ships _tkinter and just needs the runtime libs -- cheaper and
# far less brittle than compiling _tkinter against the base image's cpython.
#
# Since this isn't the AWS base image, the runtime interface client is
# installed explicitly. sst sets imageConfig.commands to the handler, which
# lands as CMD -- so ENTRYPOINT has to be the RIC.

ARG PYTHON_VERSION=3.13
FROM python:${PYTHON_VERSION}-slim

# tcl/tk shared libraries that _tkinter dlopens at import time
RUN apt-get update \
    && apt-get install -y --no-install-recommends libtcl8.6 libtk8.6 \
    && rm -rf /var/lib/apt/lists/* \
    && python -c "import tkinter; print(tkinter.Tcl().eval('info patchlevel'))"

COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv

ENV LAMBDA_TASK_ROOT=/var/task
ENV PYTHONPATH=/var/task
WORKDIR ${LAMBDA_TASK_ROOT}

COPY . ${LAMBDA_TASK_ROOT}

# Read deps straight out of pyproject and select the lambda extra. sst's
# generated requirements.txt is just "." -- it exports without extras, and
# slack-bolt/boto3 live in one, so it would install neither. Pointing uv at
# pyproject also avoids building the project itself, which would fail: sst
# stages only pyproject/smeggdrop into the build context, so the README that
# the package metadata references isn't there.
RUN uv pip install --system --target ${LAMBDA_TASK_ROOT} \
        -r pyproject.toml --extra lambda awslambdaric

ENTRYPOINT ["python", "-m", "awslambdaric"]
