# Ticket 9 (reworked) — built from this directory on every deploy.
# opencv/insightface need a few system libs beyond python:slim's base image.
FROM python:3.11-slim

# libgl1 + libglib2.0-0 alone are NOT enough: cv2 also dynamically links
# libxcb.so.1 (and the X11 client libs below), and without them the import
# fails at *runtime*, not build time — the container builds fine, then
# crash-loops with `ImportError: libxcb.so.1: cannot open shared object
# file`. Found the hard way on the Azure deploy (2026-08-06); libxcb1 was
# the specific package that fixed it.
# tesseract-ocr + poppler-utils back the OCR fallback in
# deterministic/pdf_extraction.py — a scanned/image-only resume gets a real
# read instead of a hard "cannot read this" refusal.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libxcb1 \
    tesseract-ocr poppler-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install from the LOCK, not requirements.txt.
#
# requirements.txt is 16 `>=` floors with no upper bound and no hashes, and
# deploy.yml rebuilds this image on every push to the deploy branch. That
# meant every deploy re-resolved the whole tree to whatever was newest on
# PyPI that minute — a compromised release of insightface, onnxruntime,
# pytesseract, or any of the 40-odd transitives underneath them would land
# in a container holding the Supabase service-role key, with no diff for
# anyone to review and no way to tell afterwards which versions had actually
# shipped.
#
# requirements.txt stays as the statement of intent (the floors a human
# chose); requirements.lock is the resolved, hash-pinned answer, and is what
# the build consumes. --require-hashes makes pip refuse the install outright
# if any package resolves to a file whose digest isn't in the lock, so a
# tampered or substituted artifact fails the build instead of shipping.
#
# Regenerate after editing requirements.txt (from the repo root, targeting
# THIS image's platform rather than the developer's laptop — the wheels for
# opencv/onnxruntime are platform-specific, so resolving on macOS or Windows
# produces hashes this build can never match):
#
#   uv pip compile service/requirements.txt --generate-hashes \
#     --python-version 3.11 --python-platform x86_64-unknown-linux-gnu \
#     --output-file service/requirements.lock
COPY requirements.txt requirements.lock ./
RUN pip install --no-cache-dir --require-hashes -r requirements.lock

COPY . .

# Runs as an unprivileged user rather than root (the image's default) — a
# code-execution bug in this service (or a compromised dependency) then
# can't write outside what this user owns, can't install packages, and
# can't touch anything else on a shared host. `/app` is chown'd since pip's
# install above already ran as root and left root-owned files; nothing else
# under it needs to be writable at runtime (uploads/temp files go through
# Python's tempfile module, which uses /tmp — world-writable regardless of
# UID).
RUN useradd --create-home --uid 1000 cognihire && chown -R cognihire:cognihire /app
USER cognihire

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
