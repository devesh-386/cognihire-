#!/usr/bin/env bash
# Build the ACM-format paper to PDF.
#
# MiKTeX installs missing packages (acmart, pifont, ...) on first use when
# autoinstall is enabled; the flags below make that non-interactive so the
# build does not stall waiting on a dialog.
set -u
cd "$(dirname "$0")"

PDFLATEX=${PDFLATEX:-pdflatex}
BIBTEX=${BIBTEX:-bibtex}
FLAGS="-interaction=nonstopmode -halt-on-error -file-line-error"

echo "== pass 1 =="
$PDFLATEX $FLAGS paper.tex || { echo "PASS 1 FAILED"; tail -40 paper.log; exit 1; }
echo "== bibtex =="
$BIBTEX paper || echo "(bibtex reported problems; continuing)"
echo "== pass 2 =="
$PDFLATEX $FLAGS paper.tex >/dev/null || { echo "PASS 2 FAILED"; tail -40 paper.log; exit 1; }
echo "== pass 3 =="
$PDFLATEX $FLAGS paper.tex >/dev/null || { echo "PASS 3 FAILED"; tail -40 paper.log; exit 1; }

echo
if [ -f paper.pdf ]; then
  echo "OK: $(ls -lh paper.pdf | awk '{print $5}') paper.pdf"
else
  echo "NO PDF PRODUCED"; exit 1
fi
grep -c "Warning" paper.log 2>/dev/null | sed 's/^/latex warnings: /'
grep -n "Citation.*undefined\|Reference.*undefined" paper.log | head -10
