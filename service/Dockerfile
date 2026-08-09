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
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
